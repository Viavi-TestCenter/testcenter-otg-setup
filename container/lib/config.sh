#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # variables are consumed by the sourced code or other lib files; variables are defined in the sourcing script / other lib files
# config.sh — loads and validates config.yaml into CFG_* shell variables.
# Sourced by run_snappi_test.sh after common.sh. Requires CONFIG_FILE, LIB_DIR.

# Which part of config.yaml this run reads (see config_loader.py --scope and container/README.md §6, "What each command reads"):
#   deploy  deployment: only                      --deploy-only, --destroy, --list-versions
#   access  + testbed.endpoints.* / DUT login     --access-check
#   show    like full, testbed: problems are warnings   --show-config
#   full    everything                            every test stage, --gen-config, --validate
config_scope_for_mode() {
    case "${MODE:-full}" in
        deploy-only|destroy|list-versions) echo deploy ;;
        access-check) echo access ;;
        show-config) echo show ;;
        *) echo full ;;
    esac
}

load_config() {
    [[ -f "${CONFIG_FILE}" ]] || die "Config file not found: ${CONFIG_FILE}"
    CONFIG_DIR="$(cd "$(dirname "${CONFIG_FILE}")" && pwd)"

    require_cmd python3 || die "python3 is required to parse config.yaml (run env-check first, or install python3)."

    # The loader prints CFG_* assignments on stdout and, on stderr, either an error
    # list (non-zero exit) or "WARN: ..." / "INFO: ..." notes (ignored keys,
    # loopback host_ip, ...) that must reach the console.
    local out_file err_file scope
    scope="$(config_scope_for_mode)"
    out_file="$(mktemp)"; err_file="$(mktemp)"
    if ! python3 "${LIB_DIR}/config_loader.py" "${CONFIG_FILE}" --scope "${scope}" >"${out_file}" 2>"${err_file}"; then
        log_err "config.yaml failed validation (scope: ${scope}):"
        cat "${err_file}" >&2
        rm -f "${out_file}" "${err_file}"
        die "Fix config.yaml (see ${CONFIG_FILE}) and re-run."
    fi
    local note
    while IFS= read -r note; do
        case "${note}" in
            "INFO: "*) log_info "${note#INFO: }" ;;
            "WARN: "*) log_warn "${note#WARN: }" ;;
            "") ;;
            *) log_warn "${note}" ;;
        esac
    done < "${err_file}"
    # shellcheck disable=SC1090
    source "${out_file}"
    rm -f "${out_file}" "${err_file}"

    # Derived / resolved paths (kept out of the python schema since they are
    # purely a function of CONFIG_DIR, not user-facing config). Everything
    # this tool creates on disk lives under one hidden work dir next to
    # config.yaml - easy to find, easy to wipe, no ambiguity with the
    # project's own "workspace/" directory naming.
    WORK_DIR="${CONFIG_DIR}/.run_snappi_test"
    STATE_FILE="${WORK_DIR}/state.env"
    LOCK_FILE="${WORK_DIR}/run.lock"
    # NEVER name this file with a "clab-" prefix: when `containerlab destroy
    # --cleanup` finds no running containers for the lab (e.g. a fresh
    # topology, or between a failed deploy and a retry), it falls back to
    # guessing the lab directory to remove from the topology file's own
    # name/path - and a file literally named "clab-topology.yml" gets
    # mistaken for that directory and DELETED. Verified empirically: renaming
    # it (no "clab-" prefix) makes destroy leave the file alone in every case.
    CLAB_TOPO_FILE="${WORK_DIR}/snappi-topology.yml"
    OTGSERVICE_DIR="${WORK_DIR}/otgservice"
    # deployment.otg_labserver.docker_compose.enabled only. Fixed project name:
    # this tool only ever manages one labserver+OTG stack per host, same
    # singleton assumption the standalone path makes with its hardcoded
    # "labserver" container name.
    COMPOSE_DIR="${WORK_DIR}/testcenter-otg-setup"
    COMPOSE_PROJECT="snappi-otg-compose"
    # This container solution ships inside a checkout of the testcenter-otg-setup
    # repo itself (this "container/" directory is one level under its root) -
    # docker_compose.enabled: true uses that checkout directly instead of
    # cloning a separate copy.
    OTG_SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

    IMAGES_DIR="$(resolve_path "${CFG_IMAGES_DIR}")"
    # deployment.logging.dir empty => default to "logs" under the current working directory
    # (not CONFIG_DIR - the config file may live somewhere read-only/shared).
    LOG_BASE_DIR="${CFG_LOG_DIR:+$(resolve_path "${CFG_LOG_DIR}")}"
    LOG_BASE_DIR="${LOG_BASE_DIR:-$(pwd)/logs}"
    PATCH_FILE="$(resolve_path "${CFG_SONIC_MGMT_PATCH_FILE}")"
    CUSTOM_TESTS_DIR="${CFG_SONIC_MGMT_CUSTOM_TESTS_DIR:+$(resolve_path "${CFG_SONIC_MGMT_CUSTOM_TESTS_DIR}")}"
    SONIC_MGMT_DIR="${CFG_SONIC_MGMT_SOURCE_DIR:+$(resolve_path "${CFG_SONIC_MGMT_SOURCE_DIR}")}"
    SONIC_MGMT_DIR="${SONIC_MGMT_DIR:-${WORK_DIR}/sonic-mgmt}"
    SONIC_MGMT_USER_PROVIDED=0
    [[ -n "${CFG_SONIC_MGMT_SOURCE_DIR}" ]] && SONIC_MGMT_USER_PROVIDED=1

    # A loopback address means "this host" only to a caller running directly on
    # this host's network; the sonic-mgmt container's gRPC client and otgctl
    # dialing the Labserver REST API need this host's real address instead. The
    # loader therefore resolves deployment.otg_labserver.host_ip (empty, 127.0.0.1
    # or localhost -> first address of `hostname -I`) once, so CFG_LABSERVER_IP and
    # CFG_OTG_SERVICE_IP already hold one real, reachable address for every later
    # consumer (host-side checks, the generated inventory, otgctl --restserver).

    log_ok "config.yaml loaded and validated (${CONFIG_FILE}, scope: ${scope})"
}
