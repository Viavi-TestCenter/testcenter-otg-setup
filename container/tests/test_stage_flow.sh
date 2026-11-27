#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2312  # pipelines/command substitutions in tests and log helpers are best-effort; failures are handled by callers; subshells are deliberate: they isolate sourcing run_snappi_test.sh; variables are consumed by the sourced code or other lib files
# test_stage_flow.sh - asserts the order in which run_snappi_test.sh calls its phases for every
# mode (proposal §3b stage table), with every phase stubbed. Nothing is deployed.
#
#   bash container/tests/test_stage_flow.sh
#
# run_snappi_test.sh exposes a seam for this: with SNAPPI_SOURCE_ONLY=1 it only defines its
# functions (run_stages, ...) and sources the libs, then returns before parsing arguments.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../run_snappi_test.sh"
fails=0

# Safety: sourcing a script without the seam would run a real deployment.
if ! grep -q 'SNAPPI_SOURCE_ONLY' "${SCRIPT}"; then
    echo "FAIL: run_snappi_test.sh has no SNAPPI_SOURCE_ONLY seam (run_stages) - nothing to test yet"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/sonic-mgmt/.git"

# run_mode <mode> <target> <deploy_minigraph_effective 0|1> <mg_done 0|1> [license-state]
# Prints the phases called, in order, space separated, without the "phase_" prefix.
run_mode() {
    local mode="$1" target="$2" mg="$3" done="$4"
    (
        export SNAPPI_SOURCE_ONLY=1
        set --
        # shellcheck disable=SC1090
        source "${SCRIPT}"
        MODE="${mode}"
        CFG_TARGET="${target}"; CFG_TC_MODE="${target}"; CFG_DUT_MODE="${target}"
        CFG_DEPLOY_MINIGRAPH_EFFECTIVE="${mg}"; CFG_DEPLOY_MINIGRAPH=auto
        CFG_LABSERVER_MODE=docker-compose; CFG_OTG_MODE=docker-compose   # always set by config_loader.py
        CFG_CLEANUP_ENV_ON_FAILURE=0
        STATE_FILE="${TMP}/state.env"; SONIC_MGMT_DIR="${TMP}/sonic-mgmt"
        NO_CLEANUP=0; SKIP_ENV_CHECK=0
        RESULT_DEPLOY_MG=PASSED; RESULT_PRETEST=PASSED; RESULT_SMOKE=PASSED
        SUMMARY_PRETEST=""; SUMMARY_SMOKE=""
        for f in phase_check_version_change phase_env_check phase_check_artifacts phase_sonic_mgmt_source \
                 phase_sonic_mgmt_container phase_deploy_services phase_access_check phase_gen_config \
                 phase_deploy_mg phase_pretest phase_smoke_test phase_cleanup_cache phase_destroy \
                 phase_report cleanup_env_on_failure require_deployed_environment print_run_config; do
            eval "${f}() { echo \"CALL ${f}\"; return 0; }"
        done
        record_phase() { :; }
        # deployed-identity gate: covered by test_deployed_identity.sh
        clear_deployed_identity() { :; }; record_deployed_identity() { :; }; check_deployed_identity() { :; }
        state_set() { :; }
        state_owns() { [[ "${done}" == "1" ]]; }
        deploy_mg_done_valid() { [[ "${done}" == "1" ]]; }; clear_deploy_mg_state() { :; }; warn_deploy_mg_stale() { :; }
        run_stages
    ) 2>&1 | sed -n 's/^CALL phase_//p; s/^CALL \(cleanup_env_on_failure\|require_deployed_environment\)$/\1/p' | tr '\n' ' ' | sed 's/ $//'
}

check() {
    local name="$1" got="$2" want="$3"
    if [[ "${got}" == "${want}" ]]; then
        echo "ok   - ${name}"
    else
        echo "FAIL - ${name}"
        echo "       want: ${want}"
        echo "       got : ${got}"
        fails=$((fails + 1))
    fi
}

DEPLOY="check_version_change env_check check_artifacts sonic_mgmt_source sonic_mgmt_container deploy_services"

# --- stage 1 only
check "deploy-only (virtual): deploys, then stops - no access check, no gen-config" \
    "$(run_mode deploy-only virtual 1 0)" "${DEPLOY} report"
check "deploy-only (physical): same" \
    "$(run_mode deploy-only physical 0 0)" "${DEPLOY} report"

# --- stage 2 and 3 on their own
check "access-check: needs a running sonic-mgmt container, runs only the access step" \
    "$(run_mode access-check physical 0 0)" "require_deployed_environment access_check report"
check "gen-config: testbed files only (no access step, no deploy)" \
    "$(run_mode gen-config virtual 1 0)" "gen_config"
check "destroy: tear down only" \
    "$(run_mode destroy virtual 1 0)" "destroy"

# --- full run: stages 1, 2, 3, deploy-mg when effective, then the tests
check "full (virtual, auto=push): deploy, access, gen-config, deploy-mg, pretest, smoke test" \
    "$(run_mode full virtual 1 0)" "${DEPLOY} access_check gen_config deploy_mg pretest smoke_test cleanup_cache report"
check "full (physical, auto=never): same but NO deploy-mg" \
    "$(run_mode full physical 0 0)" "${DEPLOY} access_check gen_config pretest smoke_test cleanup_cache report"

# --- test-only
check "test-only (virtual): access, gen-config, deploy-mg (always on virtual), pretest, smoke" \
    "$(run_mode test-only virtual 1 1)" "require_deployed_environment access_check gen_config deploy_mg pretest smoke_test cleanup_cache report"
check "test-only (physical, auto): never pushes a minigraph" \
    "$(run_mode test-only physical 0 0)" "require_deployed_environment access_check gen_config pretest smoke_test cleanup_cache report"
check "test-only (physical, deploy_minigraph: true): pushes" \
    "$(run_mode test-only physical 1 0)" "require_deployed_environment access_check gen_config deploy_mg pretest smoke_test cleanup_cache report"

# --- explicit --deploy-mg always pushes, whatever deploy_minigraph says
check "deploy-mg (physical, auto=never): an explicit --deploy-mg still pushes" \
    "$(run_mode deploy-mg physical 0 0)" "require_deployed_environment access_check gen_config deploy_mg report"
check "deploy-mg (virtual): pushes" \
    "$(run_mode deploy-mg virtual 1 1)" "require_deployed_environment access_check gen_config deploy_mg report"

# --- pretest / smoke-test push only when effective AND not already done
check "pretest (physical, auto): no push" \
    "$(run_mode pretest physical 0 0)" "require_deployed_environment access_check gen_config pretest cleanup_cache report"
check "pretest (virtual, push not yet done): pushes first" \
    "$(run_mode pretest virtual 1 0)" "require_deployed_environment access_check gen_config deploy_mg pretest cleanup_cache report"
check "pretest (virtual, push already done): skips the push" \
    "$(run_mode pretest virtual 1 1)" "require_deployed_environment access_check gen_config pretest cleanup_cache report"
check "smoke-test (physical, auto): no push" \
    "$(run_mode smoke-test physical 0 0)" "require_deployed_environment access_check gen_config smoke_test cleanup_cache report"
check "smoke-test (virtual, push not yet done): pushes first" \
    "$(run_mode smoke-test virtual 1 0)" "require_deployed_environment access_check gen_config deploy_mg smoke_test cleanup_cache report"
check "smoke-test (physical, deploy_minigraph: true, not yet done): pushes" \
    "$(run_mode smoke-test physical 1 0)" "require_deployed_environment access_check gen_config deploy_mg smoke_test cleanup_cache report"

# --- docker bootstrap (review M3): --gen-config never needed a reachable docker daemon (it skips the
# inventory check with a warning), so it must not start prompting for sudo / dying without one.
needs_docker() {
    local m="$1"   # before `set --` below, which clears the positional parameters
    ( export SNAPPI_SOURCE_ONLY=1; set --
      # shellcheck disable=SC1090
      source "${SCRIPT}"
      declare -F mode_needs_docker >/dev/null || { echo undefined; exit 0; }
      MODE="${m}"; mode_needs_docker && echo yes || echo no ) 2>/dev/null
}
check "gen-config does not bootstrap docker" "$(needs_docker gen-config)" "no"
for m in full deploy-only access-check deploy-mg pretest smoke-test test-only destroy; do
    check "${m} bootstraps docker" "$(needs_docker "${m}")" "yes"
done

# --- syntax of everything that was touched
for f in "${SCRIPT}" "${HERE}"/../lib/*.sh; do
    if bash -n "${f}" 2>/dev/null; then echo "ok   - bash -n $(basename "${f}")"; else echo "FAIL - bash -n ${f}"; fails=$((fails + 1)); fi
done

echo
if [[ "${fails}" -eq 0 ]]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
