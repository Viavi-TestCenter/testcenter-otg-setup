#!/usr/bin/env bash
# test_license_gate.sh - run_snappi_test.sh::check_license_server (proposal §4 item 5).
#
# deployment.stc.license_server must be a real value (not empty, not the placeholder) when this run
#   - sends traffic through a VIRTUAL chassis: full, --test-only, --smoke-test, or
#   - deploys a Labserver (it is written into the Labserver): full, --deploy-only  (the proposal's
#     extension of the old rule).
# Every other combination needs no license server, so a config without one still works there. The
# loader does not enforce this (it is a run-mode rule), so this is where it is pinned.
#
#   bash container/tests/test_license_gate.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../run_snappi_test.sh"
fails=0

if ! grep -q 'SNAPPI_SOURCE_ONLY' "$SCRIPT"; then
    echo "FAIL: run_snappi_test.sh has no SNAPPI_SOURCE_ONLY seam"; exit 1
fi

PLACEHOLDER="@license-server.example.com"

# gate <mode> <target> <labserver_mode> <license value>  -> "needs" (die) or "ok"
gate() {
    local mode="$1" target="$2" lab="$3" license="$4"
    (
        export SNAPPI_SOURCE_ONLY=1
        set --
        # shellcheck disable=SC1090
        source "$SCRIPT"
        MODE="$mode"; CFG_TC_MODE="$target"; CFG_LABSERVER_MODE="$lab"; CFG_TC_LICENSE_SERVER="$license"
        check_license_server
    ) >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then echo ok; else echo needs; fi
}

check() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then echo "ok   - $name"; else echo "FAIL - $name (want $want, got $got)"; fails=$((fails + 1)); fi
}

# --- virtual target: the traffic modes need a real value
for mode in full test-only smoke-test; do
    check "virtual, $mode, placeholder: rejected" "$(gate $mode virtual docker-compose "$PLACEHOLDER")" needs
    check "virtual, $mode, empty: rejected" "$(gate $mode virtual docker-compose "")" needs
    check "virtual, $mode, real value: accepted" "$(gate $mode virtual docker-compose "@lic.example.net")" ok
done
check "virtual + provisioned Labserver, full, placeholder: still rejected (virtual rule)" \
    "$(gate full virtual provisioned "$PLACEHOLDER")" needs
check "virtual, host:port form is a real value" "$(gate full virtual standalone "lic.example.net:7443")" ok

# --- virtual target: modes that never reach the traffic need nothing
for mode in pretest access-check gen-config deploy-mg destroy show-config validate list-versions; do
    check "virtual (compose), $mode, placeholder: not checked" "$(gate $mode virtual docker-compose "$PLACEHOLDER")" ok
done

# --- --deploy-only: only when this tool deploys a Labserver (the proposal's extension)
check "deploy-only, virtual + Labserver deployed (compose), placeholder: rejected" \
    "$(gate deploy-only virtual docker-compose "$PLACEHOLDER")" needs
check "deploy-only, virtual + Labserver standalone, empty: rejected" \
    "$(gate deploy-only virtual standalone "")" needs
check "deploy-only, virtual + Labserver provisioned, placeholder: not checked (nothing deployed uses it)" \
    "$(gate deploy-only virtual provisioned "$PLACEHOLDER")" ok

# --- physical target: only a deployed Labserver needs it
check "physical + Labserver deployed (compose), full, placeholder: rejected" \
    "$(gate full physical docker-compose "$PLACEHOLDER")" needs
check "physical + Labserver deployed (compose), deploy-only, placeholder: rejected" \
    "$(gate deploy-only physical docker-compose "$PLACEHOLDER")" needs
check "physical + Labserver deployed, test-only: not checked (it was deployed earlier)" \
    "$(gate test-only physical docker-compose "$PLACEHOLDER")" ok
for mode in full deploy-only test-only smoke-test pretest; do
    check "physical + Labserver provisioned, $mode, no license: accepted" "$(gate $mode physical provisioned "")" ok
done

echo
if [[ "$fails" -eq 0 ]]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
