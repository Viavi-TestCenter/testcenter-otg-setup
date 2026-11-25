#!/usr/bin/env bash
# test_show_config.sh - black-box test of `run_snappi_test.sh --show-config` (read-only: no lock, no log dir).
#
# Proposal §4.6: for a legacy flat config.yaml, --show-config prints the migrated layout so users can copy it.
# Also: it works on a deploy-only file with no testbed: section, and prints each address with its owner.
#
#   bash container/tests/test_show_config.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/../run_snappi_test.sh"
FIX="$HERE/fixtures"
export SNAPPI_HOST_IP_OVERRIDE=10.9.8.7
fails=0

check() {
    if [[ "$2" == "1" ]]; then echo "ok   - $1"; else echo "FAIL - $1 ${3:+($3)}"; fails=$((fails + 1)); fi
}
has() { grep -qF -- "$2" <<<"$1" && echo 1 || echo 0; }

out="$("$RUN" -c "$FIX/legacy_main.yaml" --show-config 2>&1)"; rc=$?
check "legacy file: exits 0" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)" "rc=$rc"
check "legacy file: deprecation warning" "$(has "$out" 'legacy flat layout')"
check "legacy file: the migrated layout is printed" "$(has "$out" 'MIGRATED LAYOUT')"
check "legacy file: migrated layout is the new two-section YAML" \
    "$([[ "$(sed -n '/MIGRATED LAYOUT/,$p' <<<"$out" | grep -cE '^(deployment|testbed):')" == "2" ]] && echo 1 || echo 0)"
check "legacy file: migrated layout carries the target" "$(has "$out" '  target: virtual')"
check "legacy file: the warning's promise is true (it says --show-config prints the migrated layout)" \
    "$([[ "$(has "$out" 'Run --show-config to print the migrated layout')" == 1 && "$(has "$out" 'MIGRATED LAYOUT')" == 1 ]] && echo 1 || echo 0)"

out="$("$RUN" -c "$FIX/virtual_full.yaml" --show-config 2>&1)"; rc=$?
check "new-layout file: exits 0, prints no migrated layout" "$([[ $rc -eq 0 && "$(has "$out" 'MIGRATED LAYOUT')" == 0 ]] && echo 1 || echo 0)"
check "new-layout file: each address is shown with its owning section" \
    "$([[ "$(has "$out" 'owner: deployment:')" == 1 ]] && echo 1 || echo 0)"

out="$("$RUN" -c "$FIX/virtual_deploy_only.yaml" --show-config 2>&1)"; rc=$?
check "deploy-only file without a testbed: section: exits 0" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)" "rc=$rc"
check "deploy-only file: missing testbed keys are reported as one warning" \
    "$([[ "$(grep -c 'not valid for the test stages' <<<"$out")" == "1" ]] && echo 1 || echo 0)"

out="$("$RUN" -c "$FIX/physical_ex3.yaml" --show-config 2>&1)"; rc=$?
check "example 3 (everything external): provisioned owners shown as testbed:" \
    "$([[ $rc -eq 0 && "$(has "$out" 'owner: testbed:')" == 1 ]] && echo 1 || echo 0)"

echo
if [[ "$fails" -eq 0 ]]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
