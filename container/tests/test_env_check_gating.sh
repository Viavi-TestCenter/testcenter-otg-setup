#!/usr/bin/env bash
# test_env_check_gating.sh - phase 1 (host dependency check) installs only what the target needs.
#
# Review M6: `_ensure_containerlab` ran `curl | bash` even for deployment.target: physical, where the
# proposal says containerlab never runs. On an air-gapped physical lab --deploy-only then failed in the
# env check. Every installer is stubbed; nothing is installed.
#
#   bash container/tests/test_env_check_gating.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/../lib/env_check.sh"
fails=0

check() {
    if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: $3"; echo "       got : $2"; fails=$((fails + 1)); fi
}

run_env_check() {
    local target="$1"
    (
        CFG_TC_MODE="$target"
        calls=()
        _ensure_apt_pkgs()       { calls+=(apt); }
        _ensure_docker()         { calls+=(docker); }
        _ensure_docker_compose() { calls+=(compose); }
        _ensure_containerlab()   { calls+=(containerlab); }
        _ensure_python_deps()    { calls+=(python); }
        phase_export() { :; }
        log_warn() { :; }
        _phase_env_check_impl
        echo "rc=$? ${calls[*]}"
    )
}

check "virtual target: containerlab is ensured" \
    "$(run_env_check virtual)" "rc=0 apt docker compose containerlab python"
check "physical target: containerlab is NOT installed (it never runs), the rest still is" \
    "$(run_env_check physical)" "rc=0 apt docker compose python"

echo
if [[ "$fails" -eq 0 ]]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
