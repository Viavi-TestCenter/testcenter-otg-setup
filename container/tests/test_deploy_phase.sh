#!/usr/bin/env bash
# test_deploy_phase.sh - _phase_deploy_services_impl (stage 1) with every step stubbed.
#
# Regression test for a defect the live test found: the function ended with
#   [[ -n "${ALLURE_URL:-}" ]] && phase_export ALLURE_URL "$ALLURE_URL"
# which evaluates to 1 whenever Allure is off, so the whole phase "FAILED" after everything had been
# deployed. allure.enabled used to default to true, which hid it; it now defaults to false.
# Also pins the stage-1 wiring of proposal §3a/§3b: which step runs for which mode and target.
#
#   bash container/tests/test_deploy_phase.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/../lib/deploy.sh"
fails=0

check() {
    if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: $3"; echo "       got : $2"; fails=$((fails + 1)); fi
}

# run_phase <labserver_mode> <otg_mode> <target> [allure_url]  -> "rc=<n> <calls...>"
run_phase() {
    local lab="$1" otg="$2" target="$3" allure_url="${4:-}"
    (
        CFG_LABSERVER_MODE="$lab"; CFG_OTG_MODE="$otg"; CFG_TC_MODE="$target"; CFG_TARGET="$target"
        calls=()
        _deploy_docker_compose_stack() { calls+=(compose); }
        _deploy_labserver()            { calls+=(labserver); }
        _deploy_otg_service()          { calls+=(otg); }
        _gen_clab_topology()           { calls+=(clab_topology); }
        _deploy_containerlab()         { calls+=(clab); }
        _install_dut_ssh_key()         { calls+=(key_install); }
        _deploy_allure()               { [[ -n "$allure_url" ]] && ALLURE_URL="$allure_url"; calls+=(allure); }
        phase_export()                 { calls+=("export:$1"); }
        log_info() { :; }
        _phase_deploy_services_impl
        rc=$?
        echo "rc=$rc ${calls[*]}"
    )
}

check "virtual, compose, Allure OFF: phase succeeds (the defect: it returned 1)" \
    "$(run_phase docker-compose docker-compose virtual)" \
    "rc=0 compose clab_topology clab key_install allure"
check "virtual, compose, Allure ON: the URL is exported to the caller" \
    "$(run_phase docker-compose docker-compose virtual http://x/report)" \
    "rc=0 compose clab_topology clab key_install allure export:ALLURE_URL"
check "virtual, standalone pair: Labserver then OTG service, one by one" \
    "$(run_phase standalone standalone virtual)" \
    "rc=0 labserver otg clab_topology clab key_install allure"
check "physical, compose: no containerlab and NO key install (the DUT is not contacted by deploy)" \
    "$(run_phase docker-compose docker-compose physical)" \
    "rc=0 compose allure"
check "physical, Labserver provisioned + OTG standalone: the per-component steps run" \
    "$(run_phase provisioned standalone physical)" \
    "rc=0 labserver otg allure"
check "physical, both provisioned: the per-component steps run (they only log)" \
    "$(run_phase provisioned provisioned physical)" \
    "rc=0 labserver otg allure"
check "mixed compose/standalone is never treated as the combined stack" \
    "$(run_phase docker-compose standalone physical)" \
    "rc=0 labserver otg allure"

# --- phase_check_version_change (review M8): with no version configured (physical, nothing deployed is
# chosen by version) a leftover tool-owned virtual chassis must not be compared against "" and torn
# down with the message "replaced by .".
version_change() {
    local configured="$1"
    (
        CFG_TC_VERSION="$configured"; CFG_REPLACE_ENV_ON_VERSION_CHANGE=1; STATE_FILE=/dev/null
        state_owns() { return 0; }
        docker() { case "$1" in ps) echo "clab-lab-snappi-sonic-stc" ;; inspect) echo "stc:5.65.2556" ;; esac; }
        phase_destroy() { echo destroyed; }
        record_phase() { :; }; log_info() { :; }; log_warn() { :; }
        phase_check_version_change
        echo end
    ) | tr '\n' ' '
}
check "version change: same version keeps the environment" "$(version_change 5.65.2556)" "end "
check "version change: a different version replaces it" "$(version_change 5.62.0766)" "destroyed end "
check "no version configured: the leftover virtual environment is NOT torn down" "$(version_change '')" "end "

echo
if [[ "$fails" -eq 0 ]]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
