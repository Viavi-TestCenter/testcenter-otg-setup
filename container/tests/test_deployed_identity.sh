#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2312  # subshells are deliberate: they isolate sourcing run_snappi_test.sh; variables are consumed by the sourced code or other lib files; pipelines in tests are best-effort
# test_deployed_identity.sh - the test stages must refuse to run against an environment that was
# deployed from a different deployment configuration than the current config.yaml.
#
#   bash container/tests/test_deployed_identity.sh
#
# --deploy-only records the deployed identity (target, STC version, host IP, Labserver/OTG mode) in
# the state file; --pretest/--smoke-test/--test-only and the test stage of a full run compare the
# current config with it before touching anything. Every phase is stubbed; nothing is deployed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../run_snappi_test.sh"
fails=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/sonic-mgmt/.git"
STATE="${TMP}/state.env"

check() {
    if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: $3"; echo "       got : $2"; fails=$((fails + 1)); fi
}
contains() {  # contains <name> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       missing: $3"; echo "       in     : $2"; fails=$((fails + 1)); fi
}
lacks() {  # lacks <name> <haystack> <needle>
    if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       unexpected: $3"; echo "       in        : $2"; fails=$((fails + 1)); fi
}

# run_stage <mode> [VAR=value ...] -> output, then a final "rc=<n>" line. State is ${STATE}.
# The config baseline is a virtual lab on docker-compose; overrides after the mode replace CFG_*/globals.
run_stage() {
    local mode="$1"; shift
    local overrides=("$@")
    (
        export SNAPPI_SOURCE_ONLY=1
        set --
        # shellcheck disable=SC1090
        source "${SCRIPT}"
        MODE="${mode}"
        CFG_TARGET=virtual; CFG_TC_MODE=virtual; CFG_DUT_MODE=virtual
        CFG_TC_VERSION=5.62.0766
        CFG_LABSERVER_MODE=docker-compose; CFG_OTG_MODE=docker-compose
        CFG_LABSERVER_IP=10.0.0.5; CFG_OTG_SERVICE_IP=10.0.0.5
        CFG_DEPLOY_MINIGRAPH_EFFECTIVE=0; CFG_DEPLOY_MINIGRAPH=auto
        CFG_CLEANUP_ENV_ON_FAILURE=0
        STATE_FILE="${STATE}"; SONIC_MGMT_DIR="${TMP}/sonic-mgmt"
        NO_CLEANUP=0; SKIP_ENV_CHECK=1
        RESULT_DEPLOY_MG=PASSED; RESULT_PRETEST=PASSED; RESULT_SMOKE=PASSED
        SUMMARY_PRETEST=""; SUMMARY_SMOKE=""
        DEPLOY_RC=0
        for f in phase_check_version_change phase_check_artifacts phase_sonic_mgmt_source \
                 phase_sonic_mgmt_container phase_access_check phase_gen_config phase_deploy_mg \
                 phase_pretest phase_smoke_test phase_cleanup_cache phase_report \
                 cleanup_env_on_failure require_deployed_environment print_run_config \
                 warn_labserver_unlicensed; do
            eval "${f}() { echo \"CALL ${f}\"; return 0; }"
        done
        phase_deploy_services() { echo "CALL phase_deploy_services"; return "${DEPLOY_RC}"; }
        record_phase() { :; }
        log_info() { :; }
        for assignment in "${overrides[@]}"; do eval "${assignment}"; done
        run_stages
    ) 2>&1
    echo "rc=$?"
}

reset_state() { rm -f "${STATE}"; touch "${STATE}"; }
deployed() { reset_state; run_stage deploy-only "$@" >/dev/null; }   # a successful --deploy-only with this config

TEST_MODES=(pretest smoke-test test-only full)

# --- unchanged configuration ---------------------------------------------------------------
for m in pretest smoke-test test-only; do
    deployed
    out="$(run_stage "${m}")"
    contains "unchanged config, --${m}: tests run" "${out}" "CALL phase_access_check"
    contains "unchanged config, --${m}: exit 0" "${out}" "rc=0"
    lacks "unchanged config, --${m}: no mismatch message" "${out}" "Configuration has changed"
done
reset_state
out="$(run_stage full)"
contains "full run (deploys, records, then tests): tests run" "${out}" "CALL phase_smoke_test"
lacks "full run: its own deployment is not a mismatch" "${out}" "Configuration has changed"

# --- STC version changed ---------------------------------------------------------------------
for m in "${TEST_MODES[@]}"; do
    if [[ "${m}" == "full" ]]; then continue; fi   # a full run redeploys first, see below
    deployed
    out="$(run_stage "${m}" "CFG_TC_VERSION=5.65.2556")"
    contains "STC version changed, --${m}: blocked, names the key" "${out}" "deployment.stc.version:"
    contains "STC version changed, --${m}: shows deployed value" "${out}" "deployed: 5.62.0766"
    contains "STC version changed, --${m}: shows current value" "${out}" "current:  5.65.2556"
    contains "STC version changed, --${m}: tells the user what to run" "${out}" "Run --deploy-only before running tests."
    contains "STC version changed, --${m}: non-zero exit" "${out}" "rc=1"
    lacks "STC version changed, --${m}: no access check, no tests" "${out}" "CALL phase_access_check"
    lacks "STC version changed, --${m}: no tests started" "${out}" "CALL phase_pretest"
done

# --- deployment target changed -------------------------------------------------------------
deployed
out="$(run_stage test-only "CFG_TARGET=physical" "CFG_TC_MODE=physical" "CFG_DUT_MODE=physical")"
contains "deployment.target changed: blocked" "${out}" "deployment.target:"
contains "deployment.target changed: deployed value" "${out}" "deployed: virtual"
contains "deployment.target changed: current value" "${out}" "current:  physical"
lacks "deployment.target changed: no tests" "${out}" "CALL phase_access_check"

# --- Labserver / OTG mode changed ----------------------------------------------------------
deployed
out="$(run_stage pretest "CFG_LABSERVER_MODE=provisioned")"
contains "Labserver mode changed: blocked" "${out}" "Labserver mode:"
contains "Labserver mode changed: deployed value" "${out}" "deployed: docker-compose"
contains "Labserver mode changed: current value" "${out}" "current:  provisioned"
lacks "Labserver mode changed: no tests" "${out}" "CALL phase_access_check"
lacks "Labserver mode changed: OTG mode not reported" "${out}" "OTG service mode:"

deployed
out="$(run_stage smoke-test "CFG_OTG_MODE=standalone")"
contains "OTG mode changed: blocked" "${out}" "OTG service mode:"
contains "OTG mode changed: current value" "${out}" "current:  standalone"
lacks "OTG mode changed: no tests" "${out}" "CALL phase_access_check"

# docker-compose deployment switched off flips both modes at once: both are reported.
deployed
out="$(run_stage test-only "CFG_LABSERVER_MODE=standalone" "CFG_OTG_MODE=standalone")"
contains "docker-compose switched off: Labserver mode reported" "${out}" "Labserver mode:"
contains "docker-compose switched off: OTG mode reported" "${out}" "OTG service mode:"

# --- deployment host IP changed ------------------------------------------------------------
deployed
out="$(run_stage test-only "CFG_LABSERVER_IP=10.0.0.9" "CFG_OTG_SERVICE_IP=10.0.0.9")"
contains "deployment host IP changed: blocked" "${out}" "deployment.otg_labserver.host_ip:"
contains "deployment host IP changed: deployed value" "${out}" "deployed: 10.0.0.5"
contains "deployment host IP changed: current value" "${out}" "current:  10.0.0.9"

# A provisioned Labserver + OTG service are not deployed by this tool: their testbed.endpoints
# addresses are not a deployed identity, so changing them must not block the tests.
deployed "CFG_LABSERVER_MODE=provisioned" "CFG_OTG_MODE=provisioned" "CFG_LABSERVER_IP=192.0.2.1" "CFG_OTG_SERVICE_IP=192.0.2.1"
out="$(run_stage test-only "CFG_LABSERVER_MODE=provisioned" "CFG_OTG_MODE=provisioned" "CFG_LABSERVER_IP=192.0.2.77" "CFG_OTG_SERVICE_IP=192.0.2.77")"
contains "provisioned services, endpoint address changed: tests still run" "${out}" "CALL phase_access_check"

# --- several differences are listed together ------------------------------------------------
deployed
out="$(run_stage test-only "CFG_TC_VERSION=5.65.2556" "CFG_OTG_MODE=standalone")"
contains "two changes: STC version listed" "${out}" "deployment.stc.version:"
contains "two changes: OTG mode listed" "${out}" "OTG service mode:"
check "two changes: one headline" "$(grep -c 'Configuration has changed since the environment was deployed' <<<"${out}")" "1"

# --- unrelated settings do not block --------------------------------------------------------
deployed
out="$(run_stage test-only \
    "CFG_DEPLOY_MINIGRAPH_EFFECTIVE=1" "CFG_DEPLOY_MINIGRAPH=true" "CFG_ALLURE_ENABLED=1" \
    "CFG_TESTBED_CONF_NAME=other-testbed" "CFG_TC_LICENSE_SERVER=@other" "CFG_DUT_PASSWORD=changed" \
    "CFG_LOG_DIR=/elsewhere" "CFG_CLEANUP_ENV_ON_FAILURE=1" "NO_CLEANUP=1")"
contains "unrelated test options changed: tests still run" "${out}" "CALL phase_smoke_test"
lacks "unrelated test options changed: no mismatch message" "${out}" "Configuration has changed"
contains "unrelated test options changed: exit 0" "${out}" "rc=0"

# --- fresh environment: no deployment state --------------------------------------------------
for m in "${TEST_MODES[@]}"; do
    [[ "${m}" == "full" ]] && continue
    reset_state
    out="$(run_stage "${m}")"
    contains "no deployment state, --${m}: says there is no record" "${out}" "No deployment record found"
    contains "no deployment state, --${m}: tells the user what to run" "${out}" "--deploy-only"
    lacks "no deployment state, --${m}: not reported as a mismatch" "${out}" "Configuration has changed"
    contains "no deployment state, --${m}: non-zero exit" "${out}" "rc=1"
    lacks "no deployment state, --${m}: no tests" "${out}" "CALL phase_access_check"
done
# State written before this check existed (ownership keys only) has no identity either.
reset_state; echo "OWN_CLAB=1" >> "${STATE}"
out="$(run_stage pretest)"
contains "state without identity (older deploy): same actionable error" "${out}" "No deployment record found"

# --- other modes are not gated -----------------------------------------------------------------
reset_state
out="$(run_stage access-check)"
contains "access-check is not gated" "${out}" "CALL phase_access_check"
out="$(run_stage deploy-mg)"
contains "deploy-mg is not gated" "${out}" "CALL phase_deploy_mg"

# --- repeated deployment updates the record ---------------------------------------------------
reset_state
run_stage deploy-only >/dev/null
check "deploy-only records the STC version" "$(grep '^DEPLOYED_STC_VERSION=' "${STATE}")" "DEPLOYED_STC_VERSION=5.62.0766"
check "deploy-only records the target" "$(grep '^DEPLOYED_TARGET=' "${STATE}")" "DEPLOYED_TARGET=virtual"
check "deploy-only records the host IP" "$(grep '^DEPLOYED_HOST_IP=' "${STATE}")" "DEPLOYED_HOST_IP=10.0.0.5"
check "deploy-only records the Labserver mode" "$(grep '^DEPLOYED_LABSERVER_MODE=' "${STATE}")" "DEPLOYED_LABSERVER_MODE=docker-compose"
check "deploy-only records the OTG mode" "$(grep '^DEPLOYED_OTG_MODE=' "${STATE}")" "DEPLOYED_OTG_MODE=docker-compose"
run_stage deploy-only "CFG_TC_VERSION=5.65.2556" "CFG_LABSERVER_IP=10.0.0.9" "CFG_OTG_SERVICE_IP=10.0.0.9" >/dev/null
check "second deploy replaces the STC version (one entry)" "$(grep -c '^DEPLOYED_STC_VERSION=' "${STATE}") $(grep '^DEPLOYED_STC_VERSION=' "${STATE}")" "1 DEPLOYED_STC_VERSION=5.65.2556"
check "second deploy replaces the host IP" "$(grep '^DEPLOYED_HOST_IP=' "${STATE}")" "DEPLOYED_HOST_IP=10.0.0.9"
out="$(run_stage test-only "CFG_TC_VERSION=5.65.2556" "CFG_LABSERVER_IP=10.0.0.9" "CFG_OTG_SERVICE_IP=10.0.0.9")"
contains "after the repeated deploy, the new config is accepted" "${out}" "CALL phase_access_check"
out="$(run_stage test-only)"
contains "after the repeated deploy, the old config is now the mismatch" "${out}" "current:  5.62.0766"

# --- a failed deploy leaves no record of the old environment ------------------------------------
deployed
run_stage deploy-only "DEPLOY_RC=1" >/dev/null
check "failed deploy: old record removed" "$(grep -c '^DEPLOYED_' "${STATE}")" "0"
out="$(run_stage test-only)"
contains "failed deploy: tests refuse to run on the half-deployed environment" "${out}" "No deployment record found"

# --- --destroy forgets the deployment -------------------------------------------------------------
deployed
(
    export SNAPPI_SOURCE_ONLY=1; set --
    # shellcheck disable=SC1090
    source "${SCRIPT}"
    STATE_FILE="${STATE}"; SONIC_MGMT_DIR="${TMP}/sonic-mgmt"; LOG_DIR="${TMP}"
    CFG_CLEANUP_ENV_ON_FAILURE=0; CFG_DOCKER_COMPOSE_KEEP_BUILD_IMAGE=1
    log_info() { :; }; log_ok() { :; }; log_warn() { :; }; log_step() { :; }; log_detail() { :; }
    phase_destroy >/dev/null 2>&1
)
check "--destroy: deployment record removed" "$(grep -c '^DEPLOYED_' "${STATE}")" "0"

echo
if [[ ${fails} -eq 0 ]]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
