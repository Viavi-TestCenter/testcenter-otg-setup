#!/usr/bin/env bash
# common.sh — logging, locking, secret redaction, and small helpers shared by
# every phase script. Sourced by run_snappi_test.sh; do not execute directly.

if [[ -t 1 ]]; then
    C_RST=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_BLD=$'\033[1m'
    IS_TTY=1
else
    C_RST=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''
    IS_TTY=0
fi

_log() {
    printf '%s\n' "$*"
    [[ -n "${RUN_LOG:-}" ]] && printf '%s\n' "$*" >> "$RUN_LOG"
    return 0
}

log_info() { _log "${C_BLU}[INFO ]${C_RST} $*"; }
log_ok()   { _log "${C_GRN}[ OK  ]${C_RST} $*"; }
log_warn() { _log "${C_YLW}[WARN ]${C_RST} $*" >&2; }
log_err()  { _log "${C_RED}[ERROR]${C_RST} $*" >&2; }
log_step() { _log ""; _log "${C_BLD}${C_BLU}==> $*${C_RST}"; }

die() { log_err "$*"; exit 1; }

# Redact known secret values out of a string before it is logged anywhere.
redact() {
    local s="$1"
    for v in "${CFG_DUT_PASSWORD:-}" "${CFG_OTG_PASSWORD:-}"; do
        [[ -n "$v" ]] && s="${s//$v/********}"
    done
    printf '%s' "$s"
}

log_cmd() { log_info "\$ $(redact "$*")"; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- docker wrapper: transparently falls back to 'sudo docker' -------------
# If this shell's docker group membership isn't active yet (e.g. the user
# was just added to the docker group and hasn't started a fresh login
# session), talking to /var/run/docker.sock fails with "permission denied"
# even though `id`/`groups` show the docker group. Every docker call in this
# tool goes through this function so the fallback applies everywhere without
# editing every call site.
DOCKER_SUDO=""
docker() {
    if [[ -n "$DOCKER_SUDO" ]]; then
        sudo docker "$@"
    else
        command docker "$@"
    fi
}

# Detects the permission-denied case above and, if found, primes 'sudo
# docker' for the rest of this run. Must be called in the foreground, before
# any phase that backgrounds docker calls via run_phase_with_spinner - a
# sudo password prompt there would be hidden behind the spinner and look
# like a hang.
docker_bootstrap_sudo() {
    require_cmd docker || return 0
    docker info >/dev/null 2>&1 && return 0
    log_warn "docker is installed but this shell can't reach the daemon without sudo (docker group membership not active in this login session?) - falling back to 'sudo docker' for the rest of this run"
    sudo docker info >/dev/null 2>&1 \
        || die "docker is unreachable even with sudo. Check that the docker service is running (systemctl status docker) and that sudo works for this user."
    DOCKER_SUDO="sudo"

    # Keep sudo's cached credential alive for the rest of this (possibly
    # long-running) script. Without this, sudo's timestamp (~15 min by
    # default) can expire during a docker-quiet phase (ansible/pytest), and
    # the next docker call - often one backgrounded under
    # run_phase_with_spinner, where a password prompt is invisible - would
    # re-prompt and look like a hang. Killed on exit in run_snappi_test.sh.
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 60; done ) &
    SUDO_KEEPALIVE_PID=$!
    disown "$SUDO_KEEPALIVE_PID" 2>/dev/null
}

# Resolves which Compose invocation to use - prefers the "docker compose"
# plugin (what env_check.sh installs by default), falls back to legacy
# standalone docker-compose. Dies with a clear message if neither exists,
# rather than letting a compose call fail with a bare "command not found"
# deep inside a deploy phase.
# docker-compose mode only: true iff BOTH labserver+otg containers are
# running under THIS tool's own Compose project (COMPOSE_PROJECT, set in
# config.sh) - not merely "something is listening on the configured
# host/port" - and both are reachable. Shared between env_check.sh's
# artifact-resolution short-circuit and deploy.sh's reuse check so the two
# can never disagree about whether the stack still needs (re)deploying -
# they disagreeing was exactly the bug where phase_check_artifacts skipped
# resolving the OTG installer because *something* answered on the configured
# port, while deploy.sh's stricter label-scoped check then decided a fresh
# deploy was still needed and had no installer file to use.
docker_compose_stack_up() {
    docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format '{{.Names}}' | grep -qx labserver || return 1
    docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format '{{.Names}}' | grep -qx otg || return 1
    local code; code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions")
    [[ "$code" != "000" ]] || return 1
    wait_for_tcp "$CFG_OTG_SERVICE_IP" "$CFG_OTG_SERVICE_PORT" 5 || return 1
    return 0
}

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif require_cmd docker-compose; then
        echo "docker-compose"
    else
        die "Neither 'docker compose' (plugin) nor legacy 'docker-compose' is available - run without --skip-env-check so env_check.sh can install it, or install Docker Compose manually."
    fi
}

# Resolve a config-relative path against CONFIG_DIR unless it is absolute.
resolve_path() {
    local p="$1"
    [[ "$p" = /* ]] && { printf '%s' "$p"; return; }
    printf '%s' "$(cd "$CONFIG_DIR" 2>/dev/null && pwd)/$p"
}

# --- per-run lock, so two invocations never race on the same config/workdir --
LOCK_FD=200
acquire_lock() {
    local lock_file="$1"
    mkdir -p "$(dirname "$lock_file")"
    eval "exec ${LOCK_FD}>\"$lock_file\""
    if ! flock -n "$LOCK_FD"; then
        die "Another run_snappi_test.sh run is already holding the lock at $lock_file. Wait for it to finish, or remove the file if you are sure no run is active."
    fi
    echo "$$" >&${LOCK_FD}
}
release_lock() { flock -u "$LOCK_FD" 2>/dev/null || true; }

# --- ownership state: tracks which resources THIS tool created, so --destroy
#     only ever removes what it owns (never externally-provisioned services or
#     a user-supplied sonic-mgmt checkout). Flat KEY=VALUE file.
state_file_init() { local f="$1"; mkdir -p "$(dirname "$f")"; touch "$f"; }
state_set() {
    local f="$1" k="$2" v="$3"
    local tmp; tmp="$(mktemp)"
    grep -v -e "^${k}=" "$f" 2>/dev/null > "$tmp" || true
    echo "${k}=${v}" >> "$tmp"
    mv "$tmp" "$f"
}
state_get() {
    local f="$1" k="$2"
    grep -e "^${k}=" "$f" 2>/dev/null | tail -1 | cut -d= -f2-
}
state_owns() { [[ "$(state_get "$1" "$2")" == "1" ]]; }

wait_for_tcp() {
    local host="$1" port="$2" timeout="${3:-60}" waited=0
    while true; do
        if timeout 3 bash -c "exec 3<>\"/dev/tcp/${host}/${port}\"" 2>/dev/null; then
            return 0
        fi
        waited=$((waited + 2))
        (( waited >= timeout )) && return 1
        sleep 2
    done
}

http_code() {
    curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || echo "000"
}

confirm_or_die() {
    local prompt="$1"
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted by user."
}

# --- live progress indicator for long-running steps -------------------------
# When a step produces no console output for more than 10s, show a
# self-overwriting "<label> is still running... <spinner> MM:SS" line so a
# slow step never looks hung. Only active on an interactive terminal - a
# piped/redirected run just waits quietly, same as before.
SPINNER_FRAMES='|/-\'

# spinner_wait <label> <pid>
# Waits for background job <pid>, showing the indicator once it has run past
# 10s (updated every second). Returns the job's exit status.
spinner_wait() {
    local label="$1" pid="$2"
    local start=$SECONDS elapsed=0 frame_i=0 shown=0
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$(( SECONDS - start ))
        if [[ "$IS_TTY" -eq 1 && "$elapsed" -ge 10 ]]; then
            shown=1
            local frame="${SPINNER_FRAMES:frame_i%4:1}"
            printf '\r\033[K%s[INFO ]%s %s is still running... %s %02d:%02d' \
                "$C_BLU" "$C_RST" "$label" "$frame" $(( elapsed/60 )) $(( elapsed%60 ))
            frame_i=$((frame_i + 1))
        fi
        sleep 1
    done
    wait "$pid"
    local rc=$?
    [[ "$shown" -eq 1 ]] && printf '\r\033[K'
    return $rc
}

# phase_export <NAME> <value>
# A backgrounded phase function runs in a subshell, so a plain variable
# assignment inside it (e.g. $SUDO, $ALLURE_URL) never reaches the caller.
# Call this instead from inside a function run via run_phase_with_spinner;
# the assignment is replayed into the caller once that job finishes.
phase_export() {
    [[ -n "${PHASE_VARS_FILE:-}" ]] || return 0
    printf '%s=%q\n' "$1" "$2" >> "$PHASE_VARS_FILE"
}

# run_phase_with_spinner <label> <log_file> <function> [args...]
# Runs <function> [args...] in the background with its output captured to
# <log_file>, showing spinner_wait's progress line under <label>. Any
# phase_export calls made inside <function> are replayed into this shell
# once it finishes. On failure, tails <log_file> to stderr (same convention
# used for deploy-mg/pretest/smoke test) so the failure reason is visible
# without opening the log file.
run_phase_with_spinner() {
    local label="$1" log="$2"; shift 2
    mkdir -p "$(dirname "$log")"
    local vars_file; vars_file="$(mktemp)"
    PHASE_VARS_FILE="$vars_file" "$@" > "$log" 2>&1 &
    local pid=$!
    spinner_wait "$label" "$pid"
    local rc=$?
    [[ -s "$vars_file" ]] && source "$vars_file"
    rm -f "$vars_file"
    if [[ $rc -ne 0 ]]; then
        log_err "$label FAILED - see $log"
        tail -n 40 "$log" >&2
    fi
    return $rc
}
