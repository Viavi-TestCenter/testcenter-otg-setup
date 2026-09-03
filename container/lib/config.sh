#!/usr/bin/env bash
# config.sh — loads and validates config.yaml into CFG_* shell variables.
# Sourced by run_snappi_test.sh after common.sh. Requires CONFIG_FILE, LIB_DIR.

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"

    require_cmd python3 || die "python3 is required to parse config.yaml (run env-check first, or install python3)."

    local assignments
    if ! assignments="$(python3 "$LIB_DIR/config_loader.py" "$CONFIG_FILE" 2>&1 >/tmp/.cfg.$$)"; then
        rm -f /tmp/.cfg.$$
        log_err "config.yaml failed validation:"
        printf '%s\n' "$assignments" >&2
        die "Fix config.yaml (see $CONFIG_FILE) and re-run."
    fi
    # shellcheck disable=SC1090
    source /tmp/.cfg.$$
    rm -f /tmp/.cfg.$$

    # Derived / resolved paths (kept out of the python schema since they are
    # purely a function of CONFIG_DIR, not user-facing config). Everything
    # this tool creates on disk lives under one hidden work dir next to
    # config.yaml - easy to find, easy to wipe, no ambiguity with the
    # project's own "workspace/" directory naming.
    WORK_DIR="$CONFIG_DIR/.run_snappi_test"
    STATE_FILE="$WORK_DIR/state.env"
    LOCK_FILE="$WORK_DIR/run.lock"
    # NEVER name this file with a "clab-" prefix: when `containerlab destroy
    # --cleanup` finds no running containers for the lab (e.g. a fresh
    # topology, or between a failed deploy and a retry), it falls back to
    # guessing the lab directory to remove from the topology file's own
    # name/path - and a file literally named "clab-topology.yml" gets
    # mistaken for that directory and DELETED. Verified empirically: renaming
    # it (no "clab-" prefix) makes destroy leave the file alone in every case.
    CLAB_TOPO_FILE="$WORK_DIR/snappi-topology.yml"
    OTGSERVICE_DIR="$WORK_DIR/otgservice"
    # deployment.mode=docker-compose only. Fixed project name: this tool only
    # ever manages one labserver+OTG stack per host, same singleton
    # assumption the standalone path makes with its hardcoded "labserver"
    # container name.
    COMPOSE_DIR="$WORK_DIR/testcenter-otg-setup"
    COMPOSE_PROJECT="snappi-otg-compose"
    # This container solution ships inside a checkout of the testcenter-otg-setup
    # repo itself (this "container/" directory is one level under its root) -
    # deployment.mode=docker-compose uses that checkout directly instead of
    # cloning a separate copy.
    OTG_SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

    IMAGES_DIR="$(resolve_path "$CFG_IMAGES_DIR")"
    # logging.dir empty => default to "logs" under the current working directory
    # (not CONFIG_DIR - the config file may live somewhere read-only/shared).
    LOG_BASE_DIR="${CFG_LOG_DIR:+$(resolve_path "$CFG_LOG_DIR")}"
    LOG_BASE_DIR="${LOG_BASE_DIR:-$(pwd)/logs}"
    PATCH_FILE="$(resolve_path "$CFG_SONIC_MGMT_PATCH_FILE")"
    SONIC_MGMT_DIR="${CFG_SONIC_MGMT_SOURCE_DIR:+$(resolve_path "$CFG_SONIC_MGMT_SOURCE_DIR")}"
    SONIC_MGMT_DIR="${SONIC_MGMT_DIR:-$WORK_DIR/sonic-mgmt}"
    SONIC_MGMT_USER_PROVIDED=0
    [[ -n "$CFG_SONIC_MGMT_SOURCE_DIR" ]] && SONIC_MGMT_USER_PROVIDED=1

    # A loopback deployment.*.ip (127.0.0.1/localhost) means "this host" only
    # to a caller that is itself running directly on this host's network -
    # it does not mean that to a caller sitting in its own docker network
    # (e.g. the sonic-mgmt test container's gRPC client, or otgctl dialing
    # labserver's REST API), which needs this host's real address instead
    # (UNAVAILABLE: ipv4:127.0.0.1:50051 connection refused, or a labserver
    # REST call landing on the wrong host/container entirely) even though
    # host-side reachability checks in this same script pass fine using the
    # literal loopback value. Resolve any such loopback value once here so
    # every later consumer (host-side checks, gen_config.sh's container-
    # facing inventory, and deploy.sh's otgctl --restserver call) agrees on
    # one real, reachable IP (e.g. WSL2's eth0 IP).
    _resolve_loopback_ip() {
        local label="$1" ip="$2"
        if [[ "$ip" == "127.0.0.1" || "$ip" == "localhost" ]]; then
            local resolved
            resolved="$(hostname -I 2>/dev/null | awk '{print $1}')"
            if [[ -n "$resolved" ]]; then
                log_info "$label is loopback ($ip) - resolving to this host's address ($resolved)" >&2
                printf '%s' "$resolved"
                return
            fi
            log_warn "$label is loopback ($ip) but this host's address could not be auto-detected (hostname -I) - set it explicitly in config.yaml."
        fi
        printf '%s' "$ip"
    }

    CFG_OTG_SERVICE_IP="$(_resolve_loopback_ip "deployment.otg_service.ip" "$CFG_OTG_SERVICE_IP")"
    CFG_LABSERVER_IP="$(_resolve_loopback_ip "deployment.labserver.ip" "$CFG_LABSERVER_IP")"

    log_ok "config.yaml loaded and validated ($CONFIG_FILE)"
}
