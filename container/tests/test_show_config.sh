#!/usr/bin/env bash
# shellcheck disable=SC2312  # pipelines/command substitutions in tests and log helpers are best-effort; failures are handled by callers
# test_show_config.sh - black-box test of `run_snappi_test.sh --show-config` (read-only: no lock, no log dir).
#
# It works on a deploy-only file with no testbed: section, and prints each address with its owner.
#
#   bash container/tests/test_show_config.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${HERE}/../run_snappi_test.sh"
FIX="${HERE}/fixtures"
export SNAPPI_HOST_IP_OVERRIDE=10.9.8.7
fails=0

check() {
    if [[ "$2" == "1" ]]; then echo "ok   - $1"; else echo "FAIL - $1 ${3:+($3)}"; fails=$((fails + 1)); fi
}
has() { grep -qF -- "$2" <<<"$1" && echo 1 || echo 0; }

out="$("${RUN}" -c "${FIX}/virtual_full.yaml" --show-config 2>&1)"; rc=$?
check "full file: exits 0" "$([[ ${rc} -eq 0 ]] && echo 1 || echo 0)" "rc=${rc}"
check "full file: each address is shown with its owning section" \
    "$([[ "$(has "${out}" 'owner: deployment:')" == 1 ]] && echo 1 || echo 0)"

out="$("${RUN}" -c "${FIX}/virtual_deploy_only.yaml" --show-config 2>&1)"; rc=$?
check "deploy-only file without a testbed: section: exits 0" "$([[ ${rc} -eq 0 ]] && echo 1 || echo 0)" "rc=${rc}"
check "deploy-only file: missing testbed keys are reported as one warning" \
    "$([[ "$(grep -c 'not valid for the test stages' <<<"${out}")" == "1" ]] && echo 1 || echo 0)"

out="$("${RUN}" -c "${FIX}/physical_ex3.yaml" --show-config 2>&1)"; rc=$?
check "example 3 (everything external): provisioned owners shown as testbed:" \
    "$([[ ${rc} -eq 0 && "$(has "${out}" 'owner: testbed:')" == 1 ]] && echo 1 || echo 0)"

echo
if [[ "${fails}" -eq 0 ]]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
