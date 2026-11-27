#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2312  # subshells are deliberate: they isolate sourcing run_snappi_test.sh; variables are consumed by the sourced code or other lib files; pipelines in tests are best-effort
# test_deploy_mg_state.sh - DEPLOY_MG_DONE must never outlive the DUT or the minigraph settings it
# was recorded for.
#
#   bash container/tests/test_deploy_mg_state.sh
#
# Rules under test:
#   - a (re)deployed virtual DUT starts with no minigraph recorded, even if the deploy then fails
#   - phase_deploy_mg sets DEPLOY_MG_DONE=0 before it touches the DUT and 1 only after it succeeded
#     (with a fingerprint of the minigraph-relevant settings)
#   - --gen-config invalidates DEPLOY_MG_DONE when those settings differ from the recorded ones
#     (DUT identity/hwsku/ports/links, topology, whether a push is wanted) and says so; any other
#     setting is ignored
#   - a physical DUT is never pushed to automatically, and local state is not presented as proof
# Every external step is stubbed; nothing is deployed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../run_snappi_test.sh"
fails=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/sonic-mgmt/.git" "${TMP}/sonic-mgmt/ansible" "${TMP}/logs"
STATE="${TMP}/state.env"

check() {
    if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: $3"; echo "       got : $2"; fails=$((fails + 1)); fi
}
contains() {
    if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       missing: $3"; echo "       in     : $2"; fails=$((fails + 1)); fi
}
lacks() {
    if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       unexpected: $3"; echo "       in        : $2"; fails=$((fails + 1)); fi
}

# run_stage <mode> [assignment ...] -> output, then a final "rc=<n>" line. State is ${STATE}.
# Baseline: a virtual lab. Assignments (eval'd after the baseline) override CFG_*/switches:
#   STUB_MG=1      phase_deploy_mg is only recorded ("CALL phase_deploy_mg"); default is the real one
#   MG_EXEC_RC=n   exit status of the stubbed testbed-cli deploy-mg (default 0)
#   DEPLOY_RC=n    exit status of the stubbed phase_deploy_services (default 0)
# The state seen by the stubbed testbed-cli (i.e. while "the DUT is being modified") is appended to
# ${TMP}/during.
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
        CFG_DUT_HOSTNAME=dut1; CFG_DUT_MGMT_IP=192.168.1.3; CFG_DUT_HWSKU=Force10-S6000
        CFG_DUT_IFACE_SPEED=40000; CFG_DUT_TOTAL_PORTS=32
        CFG_DUT_LINKS_COUNT=2
        CFG_DUT_LINK_0_DUT_PORT=Ethernet0; CFG_DUT_LINK_0_STC_PORT=Card1/Port1; CFG_DUT_LINK_0_BANDWIDTH=40000; CFG_DUT_LINK_0_VLAN_ID=1000
        CFG_DUT_LINK_1_DUT_PORT=Ethernet4; CFG_DUT_LINK_1_STC_PORT=Card1/Port2; CFG_DUT_LINK_1_BANDWIDTH=40000; CFG_DUT_LINK_1_VLAN_ID=1000
        CFG_TOPO_NAME=tgen_ptf32; CFG_TOPO_DUT_TYPE=ToRRouter; CFG_TOPO_VLAN_ID=1000
        CFG_TOPO_VLAN_PREFIX=192.168.100.1/24; CFG_TOPO_VLAN_PREFIX_V6=fc02:1000::1/64
        CFG_TOPO_VLAN_TAG=1000; CFG_TOPO_VLAN_MAC=00:aa:bb:cc:dd:ee
        CFG_TESTBED_CONF_NAME=vms-snappi-sonic; CFG_TESTBED_INV_NAME=snappi-sonic
        CFG_DEPLOY_MINIGRAPH=auto; CFG_DEPLOY_MINIGRAPH_EFFECTIVE=1
        CFG_CLEANUP_ENV_ON_FAILURE=0
        STATE_FILE="${STATE}"; SONIC_MGMT_DIR="${TMP}/sonic-mgmt"; LOG_DIR="${TMP}/logs"
        NO_CLEANUP=0; SKIP_ENV_CHECK=1
        RESULT_PRETEST=PASSED; RESULT_SMOKE=PASSED; SUMMARY_PRETEST=""; SUMMARY_SMOKE=""
        STUB_MG=0; MG_EXEC_RC=0; DEPLOY_RC=0
        for assignment in "${overrides[@]}"; do eval "${assignment}"; done

        for f in phase_check_version_change phase_check_artifacts phase_sonic_mgmt_source \
                 phase_sonic_mgmt_container phase_access_check phase_pretest phase_smoke_test \
                 phase_cleanup_cache phase_report cleanup_env_on_failure require_deployed_environment \
                 print_run_config warn_labserver_unlicensed; do
            eval "${f}() { echo \"CALL ${f}\"; return 0; }"
        done
        phase_deploy_services() { echo "CALL phase_deploy_services"; return "${DEPLOY_RC}"; }
        # phase_gen_config is real; only what it generates/inspects is stubbed
        _gen_testbed_config() { :; }; _gen_password_file() { :; }; _verify_inventory() { :; }
        docker() { return 0; }
        if [[ "${STUB_MG}" == "1" ]]; then
            phase_deploy_mg() { echo "CALL phase_deploy_mg"; RESULT_DEPLOY_MG=PASSED; return 0; }
        else
            log_cmd() { :; }
            sonic_mgmt_exec() { echo "during=$(state_get "${STATE_FILE}" DEPLOY_MG_DONE)" >> "${TMP}/during"; return "${MG_EXEC_RC}"; }
            spinner_wait() { wait "$2"; }
        fi
        record_phase() { :; }
        log_info() { :; }; log_step() { :; }
        run_stages
    ) 2>&1
    echo "rc=$?"
}

reset_state() { rm -f "${STATE}" "${TMP}/during"; touch "${STATE}"; }
mg_state() { printf 'DONE=%s FP=%s' "$(state_get_f DEPLOY_MG_DONE)" "$([[ -n "$(state_get_f DEPLOY_MG_FINGERPRINT)" ]] && echo set || echo none)"; }
state_get_f() { grep -e "^$1=" "${STATE}" 2>/dev/null | tail -1 | cut -d= -f2-; }

# A virtual lab that is deployed and has had its minigraph pushed with the baseline settings.
mg_pushed() {
    reset_state
    run_stage deploy-only >/dev/null
    run_stage deploy-mg >/dev/null
}

# --- 1. virtual deployment clears the previous state ------------------------------------------
mg_pushed
check "setup: deploy-mg recorded" "$(mg_state)" "DONE=1 FP=set"
run_stage deploy-only >/dev/null
check "virtual --deploy-only: DEPLOY_MG_DONE cleared" "$(mg_state)" "DONE=0 FP=none"

mg_pushed
run_stage deploy-only DEPLOY_RC=1 >/dev/null
check "virtual deploy that FAILS still clears the previous DUT's state" "$(mg_state)" "DONE=0 FP=none"

mg_pushed
run_stage full STUB_MG=1 >/dev/null
check "virtual full run: redeploy clears, then the fresh push is recorded only by the real phase" "$(state_get_f DEPLOY_MG_DONE)" "0"

# An old state file (done flag + fingerprint of the same settings) must not validate a newly
# deployed virtual DUT: the next test run pushes the minigraph again.
mg_pushed
run_stage deploy-only >/dev/null
out="$(run_stage pretest STUB_MG=1)"
contains "old state + redeployed virtual DUT: --pretest pushes the minigraph again" "${out}" "CALL phase_deploy_mg"
# ... and a flag that survives with no fingerprint (written by an older version) is never valid
reset_state
run_stage deploy-only >/dev/null
printf 'DEPLOY_MG_DONE=1\n' >> "${STATE}"
out="$(run_stage smoke-test STUB_MG=1)"
contains "done flag without fingerprint (older state file): not valid, pushes" "${out}" "CALL phase_deploy_mg"

# Physical: --deploy-only does not touch the DUT, so it does not forget what was pushed to it.
reset_state
run_stage deploy-only "CFG_TARGET=physical" "CFG_TC_MODE=physical" "CFG_DUT_MODE=physical" "CFG_DEPLOY_MINIGRAPH=true" "CFG_DEPLOY_MINIGRAPH_EFFECTIVE=1" >/dev/null
run_stage deploy-mg "CFG_TARGET=physical" "CFG_TC_MODE=physical" "CFG_DUT_MODE=physical" "CFG_DEPLOY_MINIGRAPH=true" "CFG_DEPLOY_MINIGRAPH_EFFECTIVE=1" >/dev/null
run_stage deploy-only "CFG_TARGET=physical" "CFG_TC_MODE=physical" "CFG_DUT_MODE=physical" "CFG_DEPLOY_MINIGRAPH=true" "CFG_DEPLOY_MINIGRAPH_EFFECTIVE=1" >/dev/null
check "physical --deploy-only leaves the record of a push alone (the DUT is not redeployed)" "$(mg_state)" "DONE=1 FP=set"

# --- 2. the push itself ---------------------------------------------------------------------------
reset_state
run_stage deploy-only >/dev/null
out="$(run_stage deploy-mg)"
contains "successful --deploy-mg: exit 0" "${out}" "rc=0"
check "successful --deploy-mg sets DEPLOY_MG_DONE=1 with a fingerprint" "$(mg_state)" "DONE=1 FP=set"
check "DEPLOY_MG_DONE was already 0 while the DUT was being modified" "$(cat "${TMP}/during")" "during=0"

mg_pushed
rm -f "${TMP}/during"
out="$(run_stage deploy-mg MG_EXEC_RC=1)"
contains "failed --deploy-mg: exit 1" "${out}" "rc=1"
check "failed --deploy-mg leaves DEPLOY_MG_DONE at 0 (and no fingerprint)" "$(mg_state)" "DONE=0 FP=none"
check "failed --deploy-mg: the previous 1 was cleared before the DUT was touched" "$(cat "${TMP}/during")" "during=0"

# interrupted: the run dies inside the push; the state written before it is what survives
mg_pushed
( # shellcheck disable=SC2317
  export SNAPPI_SOURCE_ONLY=1; set --
  # shellcheck disable=SC1090
  source "${SCRIPT}"
  STATE_FILE="${STATE}"; LOG_DIR="${TMP}/logs"; CFG_TARGET=virtual; CFG_DUT_HWSKU=x
  log_step() { :; }; log_cmd() { :; }
  sonic_mgmt_exec() { kill -TERM $$ 2>/dev/null; sleep 1; }
  spinner_wait() { kill -KILL $$; }
  phase_deploy_mg ) >/dev/null 2>&1
check "interrupted --deploy-mg leaves DEPLOY_MG_DONE at 0" "$(mg_state)" "DONE=0 FP=none"

# --- 3. --gen-config invalidation ------------------------------------------------------------------
# Each of these changes what the DUT's minigraph is built from, so a recorded push no longer applies.
invalidating=(
    "CFG_DUT_HWSKU=Force10-S6100"
    "CFG_DUT_TOTAL_PORTS=64"
    "CFG_DUT_IFACE_SPEED=100000"
    "CFG_DUT_LINK_1_DUT_PORT=Ethernet8"
    "CFG_DUT_LINK_1_VLAN_ID=2000"
    "CFG_DUT_LINK_0_BANDWIDTH=100000"
    "CFG_DUT_LINK_0_STC_PORT=Card1/Port9"
    "CFG_DUT_LINKS_COUNT=3"
    "CFG_TOPO_NAME=tgen_ptf64"
    "CFG_TOPO_VLAN_ID=2000"
    "CFG_TOPO_VLAN_PREFIX=192.168.200.1/24"
    "CFG_TOPO_VLAN_TAG=2000"
    "CFG_TOPO_DUT_TYPE=LeafRouter"
    "CFG_DUT_HOSTNAME=dut2"
    "CFG_DUT_MGMT_IP=192.168.1.9"
)
for change in "${invalidating[@]}"; do
    mg_pushed
    out="$(run_stage gen-config "${change}")"
    check "gen-config, ${change}: invalidates" "$(mg_state)" "DONE=0 FP=none"
    contains "gen-config, ${change}: says so" "${out}" "Testbed configuration changed."
    contains "gen-config, ${change}: tells the user what to run" "${out}" "Run --deploy-mg before running tests that require the updated DUT configuration."
done

# Switching the push wish (what testbed.deploy_minigraph resolves to) also invalidates.
mg_pushed
out="$(run_stage gen-config "CFG_DEPLOY_MINIGRAPH=false" "CFG_DEPLOY_MINIGRAPH_EFFECTIVE=0")"
check "gen-config, deploy_minigraph resolves differently: invalidates" "$(mg_state)" "DONE=0 FP=none"

# Nothing relevant changed: the record stays valid and nothing is printed.
unrelated=(
    "CFG_TESTBED_CONF_NAME=other" "CFG_TESTBED_INV_NAME=other" "CFG_TC_VERSION=5.65.2556"
    "CFG_DUT_PASSWORD=changed" "CFG_DUT_USER=root" "CFG_STC_CHASSIS_IP=10.9.9.9" "CFG_OTG_SERVICE_IP=10.9.9.9"
    "CFG_ALLURE_ENABLED=1" "CFG_TC_LICENSE_SERVER=@other" "CFG_TOPO_VLAN_MAC=00:11:22:33:44:55"
    "CFG_DEPLOY_MINIGRAPH=true"
    "CFG_CLEANUP_ENV_ON_FAILURE=1" "NO_CLEANUP=1"
)
# (CFG_TOPO_VLAN_MAC is a topology field: it is listed with the invalidating ones below, not here.)
unrelated=("${unrelated[@]/CFG_TOPO_VLAN_MAC=00:11:22:33:44:55}")
for change in "${unrelated[@]}"; do
    [[ -n "${change}" ]] || continue
    mg_pushed
    out="$(run_stage gen-config "${change}")"
    check "gen-config, ${change}: record stays valid" "$(mg_state)" "DONE=1 FP=set"
    lacks "gen-config, ${change}: nothing to warn about" "${out}" "Testbed configuration changed."
done
mg_pushed
run_stage gen-config "CFG_TOPO_VLAN_MAC=00:11:22:33:44:55" >/dev/null
check "gen-config, topology vlan mac changed: invalidates" "$(mg_state)" "DONE=0 FP=none"

# No record at all (nothing ever pushed): nothing to invalidate, nothing to say.
reset_state
out="$(run_stage gen-config "CFG_TOPO_VLAN_ID=2000")"
lacks "gen-config with nothing recorded: no warning" "${out}" "Testbed configuration changed."

# --- 4. test stages after a change ------------------------------------------------------------------
# virtual: the automatic push runs again, and no "run --deploy-mg" nag precedes it
mg_pushed
out="$(run_stage pretest STUB_MG=1 "CFG_TOPO_VLAN_ID=2000")"
contains "virtual --pretest after a VLAN change: minigraph pushed again" "${out}" "CALL phase_deploy_mg"
lacks "virtual --pretest after a VLAN change: no nag, the push is automatic" "${out}" "Run --deploy-mg before"
mg_pushed
out="$(run_stage pretest STUB_MG=1)"
lacks "virtual --pretest, nothing changed: no second push" "${out}" "CALL phase_deploy_mg"

# physical, deploy_minigraph auto: never pushed; the user is told the DUT may be out of date
PHYS=("CFG_TARGET=physical" "CFG_TC_MODE=physical" "CFG_DUT_MODE=physical" "CFG_DEPLOY_MINIGRAPH=auto" "CFG_DEPLOY_MINIGRAPH_EFFECTIVE=0")
reset_state
run_stage deploy-only "${PHYS[@]}" >/dev/null
run_stage deploy-mg "${PHYS[@]}" >/dev/null     # an explicit push is still allowed
check "physical: explicit --deploy-mg is recorded" "$(mg_state)" "DONE=1 FP=set"
out="$(run_stage pretest STUB_MG=1 "${PHYS[@]}")"
lacks "physical, auto, nothing changed: never pushes" "${out}" "CALL phase_deploy_mg"
lacks "physical, auto, nothing changed: no warning" "${out}" "Testbed configuration changed."
out="$(run_stage pretest STUB_MG=1 "${PHYS[@]}" "CFG_TOPO_VLAN_ID=2000")"
lacks "physical, auto, VLAN changed: still never pushes automatically" "${out}" "CALL phase_deploy_mg"
contains "physical, auto, VLAN changed: tests run (not blocked)" "${out}" "CALL phase_pretest"
contains "physical, auto, VLAN changed: user told to run --deploy-mg" "${out}" "Run --deploy-mg before running tests that require the updated DUT configuration."
check "physical, auto, VLAN changed: record invalidated" "$(state_get_f DEPLOY_MG_DONE)" "0"

# physical, deploy_minigraph true: a recorded push for the SAME settings is not pushed again, but it
# is described as a local record, not as the DUT's verified state
PHYS_TRUE=("CFG_TARGET=physical" "CFG_TC_MODE=physical" "CFG_DUT_MODE=physical" "CFG_DEPLOY_MINIGRAPH=true" "CFG_DEPLOY_MINIGRAPH_EFFECTIVE=1")
reset_state
run_stage deploy-only "${PHYS_TRUE[@]}" >/dev/null
run_stage deploy-mg "${PHYS_TRUE[@]}" >/dev/null
out="$(run_stage smoke-test STUB_MG=1 "${PHYS_TRUE[@]}")"
lacks "physical, true, same settings: no repeated overwrite of the DUT" "${out}" "CALL phase_deploy_mg"
contains "physical, true, recorded push: described as a local record" "${out}" "not verified on the physical DUT"
out="$(run_stage smoke-test STUB_MG=1 "${PHYS_TRUE[@]}" "CFG_TOPO_VLAN_ID=2000")"
contains "physical, true, VLAN changed: pushes again" "${out}" "CALL phase_deploy_mg"

# --- 5. --destroy forgets the push ----------------------------------------------------------------------
mg_pushed
(
    export SNAPPI_SOURCE_ONLY=1; set --
    # shellcheck disable=SC1090
    source "${SCRIPT}"
    STATE_FILE="${STATE}"; SONIC_MGMT_DIR="${TMP}/sonic-mgmt"; LOG_DIR="${TMP}"
    CFG_CLEANUP_ENV_ON_FAILURE=0; CFG_DOCKER_COMPOSE_KEEP_BUILD_IMAGE=1
    log_info() { :; }; log_ok() { :; }; log_warn() { :; }; log_step() { :; }; log_detail() { :; }
    phase_destroy >/dev/null 2>&1
)
check "--destroy clears DEPLOY_MG_DONE and the fingerprint" "$(mg_state)" "DONE=0 FP=none"

echo
if [[ ${fails} -eq 0 ]]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
