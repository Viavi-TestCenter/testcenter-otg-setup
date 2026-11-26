#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2312  # pipelines/command substitutions in tests and log helpers are best-effort; failures are handled by callers; single quotes are deliberate: the text runs in a nested shell
# test_docker_bootstrap.sh - regression test for the docker bootstrap defects the live test found.
#
#  1. require_cmd used `command -v`, which also matches the docker() wrapper *function* defined in
#     common.sh, so a host with no docker installed passed the "is docker installed?" guard and
#     died in docker_bootstrap_sudo before phase 1 (env check) could install it.
#  2. docker_bootstrap_sudo --soft (used while phase 1 is still pending) must not be fatal; the
#     strict call (after phase 1, or with --skip-env-check) must be, with a clear message.
#  3. The `sudo docker` fallback only covered this shell; child processes (vrnetlab's make ->
#     docker build) hit "permission denied". A docker shim on PATH must make `sh -c 'docker ..'` work.
#
# Uses fake docker/sudo executables; touches no real docker.   bash container/tests/test_docker_bootstrap.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${HERE}/.."
fails=0
check() {
    if [[ "$2" == "1" ]]; then echo "ok   - $1"; else echo "FAIL - $1 ${3:+($3)}"; fails=$((fails + 1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BASH_BIN="$(command -v bash)"

# Minimal PATH: only the tools common.sh needs, never a real docker or sudo.
mkdir -p "${TMP}/base"
for t in mktemp chmod rm id sleep cat dirname date tr grep sh; do
    p="$(type -P "${t}")" && ln -s "${p}" "${TMP}/base/${t}"
done

# 1. A shell function named like a command must not satisfy require_cmd.
out="$("${BASH_BIN}" -c 'source "$1/lib/common.sh" 2>/dev/null; fakecmd(){ :; }; require_cmd fakecmd && echo FOUND || echo MISSING' _ "${CONTAINER}")"
check "require_cmd ignores shell functions" "$([[ "${out}" == MISSING ]] && echo 1 || echo 0)" "${out}"

# 2. No docker installed.
run() { # run <mode-arg> : prints rc and output
    PATH="${TMP}/base" "${BASH_BIN}" -c 'source "$1/lib/common.sh" 2>/dev/null; docker_bootstrap_sudo $2; echo "rc=$?"' _ "${CONTAINER}" "$1" 2>&1
}
out="$(run --soft)"
check "no docker: --soft bootstrap is not fatal" "$([[ "${out}" == *rc=0* ]] && echo 1 || echo 0)" "${out}"
out="$(run "")"
check "no docker: strict bootstrap dies with 'not installed'" "$([[ "${out}" == *"docker is not installed"* && "${out}" != *rc=0* ]] && echo 1 || echo 0)" "${out}"

# 3. docker installed, reachable only through sudo -> fallback + shim for child processes.
mkdir -p "${TMP}/fake"
cat > "${TMP}/fake/docker" <<'EOS'
#!/bin/sh
[ "${FAKE_VIA_SUDO:-}" = 1 ] && { echo "docker-ran-via-sudo: $*"; exit 0; }
echo "permission denied while trying to connect to the docker API" >&2; exit 1
EOS
cat > "${TMP}/fake/sudo" <<'EOS'
#!/bin/sh
[ "$1" = "-n" ] && shift
FAKE_VIA_SUDO=1 exec "$@"
EOS
chmod +x "${TMP}/fake/docker" "${TMP}/fake/sudo"
LOG="${TMP}/shim.log"
PATH="${TMP}/fake:${TMP}/base" "${BASH_BIN}" -c '
    source "$1/lib/common.sh" 2>/dev/null
    docker_bootstrap_sudo
    echo "DOCKER_SUDO=[$DOCKER_SUDO]"
    echo "CHILD: $(sh -c "docker ps")"      # a child process, as make would be
    rm -rf "$DOCKER_SHIM_DIR"
' _ "${CONTAINER}" >"${LOG}" 2>&1
out="$(cat "${LOG}")"
check "fallback engaged when docker works only via sudo" "$([[ "${out}" == *"DOCKER_SUDO=[sudo]"* ]] && echo 1 || echo 0)" "${out}"
check "child process 'docker ps' goes through sudo (PATH shim)" "$([[ "${out}" == *"CHILD: docker-ran-via-sudo: ps"* ]] && echo 1 || echo 0)" "${out}"

echo
if [[ "${fails}" -eq 0 ]]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
