#!/usr/bin/env bash
# test_license_gate.sh - the deployment.stc.license_server advisories in run_snappi_test.sh.
#
# A missing license server (empty or the shipped placeholder) is only ever a WARNING: the license may
# come from elsewhere (an Aion license, or a license server configured in the Labserver by hand).
#   - check_license_server: warns before the test cases of full / --test-only / --smoke-test (virtual
#     chassis, or a Labserver this tool deploys in a full run); never stops the run.
#   - check_labserver_licensed: warns before --smoke-test / --test-only when a virtual Labserver was
#     deployed without a license server although the config value is set now.
#   - warn_labserver_unlicensed: warns after --deploy-only on a virtual lab.
# A physical chassis has its own licensing path and is not warned about a license server.
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

# run_fn <function> <mode> <target> <labserver_mode> <license value> <flag 0|1>
#   -> "warn" (printed a WARN, exit 0), "quiet" (nothing, exit 0), "stop" (non-zero exit)
run_fn() {
    local fn="$1" mode="$2" target="$3" lab="$4" license="$5" flag="${6:-0}" sf out rc
    sf="$(mktemp)"
    out="$(
        export SNAPPI_SOURCE_ONLY=1
        set --
        # shellcheck disable=SC1090
        source "$SCRIPT"
        STATE_FILE="$sf"; MODE="$mode"; CFG_TC_MODE="$target"; CFG_LABSERVER_MODE="$lab"; CFG_TC_LICENSE_SERVER="$license"
        state_set "$STATE_FILE" LABSERVER_UNLICENSED "$flag"
        "$fn" 2>&1
    )"
    rc=$?
    rm -f "$sf"
    if [[ $rc -ne 0 ]]; then echo stop
    elif grep -q 'WARN' <<<"$out"; then echo warn
    else echo quiet; fi
}

check() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then echo "ok   - $name"; else echo "FAIL - $name (want $want, got $got)"; fails=$((fails + 1)); fi
}

# --- check_license_server, virtual: the traffic modes warn, never stop
for mode in full test-only smoke-test; do
    check "virtual, $mode, placeholder: warns" "$(run_fn check_license_server $mode virtual docker-compose "$PLACEHOLDER")" warn
    check "virtual, $mode, empty: warns" "$(run_fn check_license_server $mode virtual docker-compose "")" warn
    check "virtual, $mode, blanks only: warns" "$(run_fn check_license_server $mode virtual docker-compose "   ")" warn
    check "virtual, $mode, real value: quiet" "$(run_fn check_license_server $mode virtual docker-compose "@lic.example.net")" quiet
done
check "virtual, host:port form is a real value" "$(run_fn check_license_server full virtual standalone "lic.example.net:7443")" quiet
check "virtual + provisioned Labserver, smoke-test, placeholder: warns (virtual chassis still needs one)" \
    "$(run_fn check_license_server smoke-test virtual provisioned "$PLACEHOLDER")" warn

# the provisioned-Labserver warning must not tell the user to redeploy (this tool deploys nothing there)
prov_msg() ( m="$1"; l="$2"; export SNAPPI_SOURCE_ONLY=1; set --; source "$SCRIPT"; MODE="$m"; CFG_TC_MODE=virtual; CFG_LABSERVER_MODE="$l"; CFG_TC_LICENSE_SERVER=""; check_license_server 2>&1 )
check "provisioned Labserver: warning says it is provisioned, no --deploy-only advice" \
    "$(m="$(prov_msg smoke-test provisioned)"; grep -q 'is provisioned' <<<"$m" && ! grep -q -- '--deploy-only' <<<"$m" && echo yes || echo no)" yes
check "deployed Labserver: warning still advises --deploy-only" \
    "$(grep -q -- '--deploy-only' <<<"$(prov_msg smoke-test docker-compose)" && echo yes || echo no)" yes

# --- modes that never reach the traffic are not checked
for mode in pretest access-check gen-config deploy-mg destroy show-config validate list-versions deploy-only; do
    check "virtual (compose), $mode, placeholder: not checked" "$(run_fn check_license_server $mode virtual docker-compose "$PLACEHOLDER")" quiet
done

# --- physical: only a full run that deploys a Labserver is warned
check "physical + Labserver deployed (compose), full, placeholder: warns" \
    "$(run_fn check_license_server full physical docker-compose "$PLACEHOLDER")" warn
check "physical + Labserver deployed, test-only: not checked (it was deployed earlier)" \
    "$(run_fn check_license_server test-only physical docker-compose "$PLACEHOLDER")" quiet
for mode in full deploy-only test-only smoke-test pretest; do
    check "physical + Labserver provisioned, $mode, no license: quiet" "$(run_fn check_license_server $mode physical provisioned "")" quiet
done

# --- check_labserver_licensed: Labserver deployed unlicensed, config value set now (virtual only)
for mode in smoke-test test-only; do
    check "virtual, $mode, deployed unlicensed, config set: warns (redeploy)" "$(run_fn check_labserver_licensed $mode virtual docker-compose "@lic.example.net" 1)" warn
    check "virtual, $mode, Labserver licensed: quiet" "$(run_fn check_labserver_licensed $mode virtual docker-compose "@lic.example.net" 0)" quiet
    check "virtual, $mode, config still missing: quiet (check_license_server already warned)" "$(run_fn check_labserver_licensed $mode virtual docker-compose "" 1)" quiet
    check "physical, $mode, flag set: quiet" "$(run_fn check_labserver_licensed $mode physical docker-compose "@lic.example.net" 1)" quiet
done
for mode in pretest full deploy-only access-check; do
    check "virtual, $mode, flag set: not checked" "$(run_fn check_labserver_licensed $mode virtual docker-compose "@lic.example.net" 1)" quiet
done

# --- warn_labserver_unlicensed: after --deploy-only on a virtual lab
check "deploy-only, virtual, deployed unlicensed: warns" "$(run_fn warn_labserver_unlicensed deploy-only virtual docker-compose "" 1)" warn
check "deploy-only, virtual, licensed: quiet" "$(run_fn warn_labserver_unlicensed deploy-only virtual docker-compose "@lic.example.net" 0)" quiet
check "deploy-only, physical, flag set: quiet" "$(run_fn warn_labserver_unlicensed deploy-only physical docker-compose "" 1)" quiet
check "full, virtual, flag set: not this function's job" "$(run_fn warn_labserver_unlicensed full virtual docker-compose "" 1)" quiet

# --- deployment.stc.license_managed_externally: true silences every license-server warning
ack() {  # <function> <mode> <target> <labserver_mode> <license> <flag>
    local fn="$1" mode="$2" target="$3" lab="$4" license="$5" flag="$6" sf out
    sf="$(mktemp)"
    out="$( export SNAPPI_SOURCE_ONLY=1; set --; source "$SCRIPT"
        STATE_FILE="$sf"; MODE="$mode"; CFG_TC_MODE="$target"; CFG_LABSERVER_MODE="$lab"; CFG_TC_LICENSE_SERVER="$license"
        CFG_LICENSE_MANAGED_EXTERNALLY=1; state_set "$STATE_FILE" LABSERVER_UNLICENSED "$flag"; "$fn" 2>&1 )"
    rm -f "$sf"; if grep -q WARN <<<"$out"; then echo warn; else echo quiet; fi
}
for mode in full test-only smoke-test; do
    check "acknowledged, virtual, $mode, placeholder: quiet" "$(ack check_license_server $mode virtual docker-compose "$PLACEHOLDER" 0)" quiet
    check "acknowledged, virtual + provisioned Labserver, $mode: quiet" "$(ack check_license_server $mode virtual provisioned "" 0)" quiet
done
check "acknowledged, smoke-test, deployed unlicensed, config set: quiet" "$(ack check_labserver_licensed smoke-test virtual docker-compose "@lic.example.net" 1)" quiet
check "acknowledged, deploy-only, deployed unlicensed: quiet" "$(ack warn_labserver_unlicensed deploy-only virtual docker-compose "" 1)" quiet

# --- license_server_valid: what the Labserver deploy uses to decide whether to write the value
valid() ( v="$1"; export SNAPPI_SOURCE_ONLY=1; set --; source "$SCRIPT"; CFG_TC_LICENSE_SERVER="$v"; license_server_valid && echo yes || echo no ) 2>/dev/null
check "license_server_valid: real value" "$(valid "@lic.example.net")" yes
check "license_server_valid: host:port" "$(valid "lic.example.net:7443")" yes
check "license_server_valid: empty" "$(valid "")" no
check "license_server_valid: blanks only" "$(valid "   ")" no
check "license_server_valid: placeholder" "$(valid "$PLACEHOLDER")" no

# --- license_failure_hint: explains STC's "Failed to connect to a license server" after a failed smoke test
hint() {  # <labserver_mode> <log text>
    local lab="$1" text="$2" lg out; lg="$(mktemp)"; printf '%s\n' "$text" > "$lg"
    out="$( export SNAPPI_SOURCE_ONLY=1; set --; source "$SCRIPT"; CFG_LABSERVER_MODE="$lab"; CFG_LABSERVER_IP=10.1.1.1
            license_failure_hint "$lg" 2>&1; echo "rc=$?" )"
    rm -f "$lg"; echo "$out"
}
LICLOG="Catch: Failed to connect to a license server. Please check that a license server is available"
o="$(hint docker-compose "$LICLOG")"
check "hint: license failure in the log is explained (deployed Labserver)" "$(grep -q 'rc=0' <<<"$o" && grep -q -- '--deploy-only' <<<"$o" && echo yes || echo no)" yes
o="$(hint provisioned "$LICLOG")"
check "hint: provisioned Labserver gets provisioned wording, no --deploy-only" "$(grep -q 'rc=0' <<<"$o" && grep -q 'provisioned' <<<"$o" && ! grep -q -- '--deploy-only' <<<"$o" && echo yes || echo no)" yes
o="$(hint docker-compose "E  some other failure")"
check "hint: unrelated failure prints nothing" "$(grep -q 'rc=1' <<<"$o" && ! grep -q 'Cause' <<<"$o" && echo yes || echo no)" yes

echo
if [[ "$fails" -eq 0 ]]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
