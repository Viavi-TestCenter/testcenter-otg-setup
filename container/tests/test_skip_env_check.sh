#!/usr/bin/env bash
# test_skip_env_check.sh - regression test for a defect the live test found.
#
# $SUDO used to be assigned only inside phase_env_check. With --skip-env-check that phase never runs,
# so the first `$SUDO ...` (sonic_mgmt.sh: `mount --make-rshared /` on WSL) aborted the whole run under
# `set -u` with "SUDO: unbound variable". $SUDO must be defined whether or not the env check ran.
#
#   bash container/tests/test_skip_env_check.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="$HERE/.."
fails=0

check() {
    if [[ "$2" == "1" ]]; then echo "ok   - $1"; else echo "FAIL - $1 ${3:+($3)}"; fails=$((fails + 1)); fi
}

# 1. The libraries alone: sourcing common.sh defines SUDO.
out="$(bash -c 'set -u; source "$1/lib/common.sh"; printf "SUDO=[%s]" "$SUDO"' _ "$CONTAINER" 2>&1)"
check "common.sh defines SUDO (no env check involved)" "$([[ "$out" == SUDO=\[* ]] && echo 1 || echo 0)" "$out"

# 2. The real entry point (no phase has run): SUDO is defined and has the right value for this user.
out="$(SNAPPI_SOURCE_ONLY=1 bash -c 'set -u; dir="$1"; set --; source "$dir/run_snappi_test.sh"; printf "SUDO=[%s]" "$SUDO"' _ "$CONTAINER" 2>&1)"
check "run_snappi_test.sh leaves SUDO defined before any phase" "$([[ "$out" == SUDO=\[* ]] && echo 1 || echo 0)" "$out"

want=""; [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1 && want="sudo"
check "SUDO is '${want}' for this user (empty when root or without sudo)" "$([[ "$out" == "SUDO=[$want]" ]] && echo 1 || echo 0)" "$out"

echo
if [[ "$fails" -eq 0 ]]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
