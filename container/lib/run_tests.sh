#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2312  # pipelines/command substitutions in tests and log helpers are best-effort; failures are handled by callers; variables are consumed by the sourced code or other lib files; variables are defined in the sourcing script / other lib files
# run_tests.sh — phase 7: deploy-mg, pretest, and the snappi smoke test, run
# inside the sonic-mgmt container, with output captured under $LOG_DIR.

RESULT_DEPLOY_MG="SKIPPED"; RESULT_PRETEST="SKIPPED"; RESULT_SMOKE="SKIPPED"
SUMMARY_DEPLOY_MG=""; SUMMARY_PRETEST=""; SUMMARY_SMOKE=""

# ------------------------------------------------------ minigraph record ----
# DEPLOY_MG_DONE=1 in $STATE_FILE means "this tool pushed a minigraph, built from the settings in
# DEPLOY_MG_FINGERPRINT, and that push succeeded". It is only a local record: it is dropped when a
# virtual DUT is (re)deployed or destroyed, before every push, and by invalidate_stale_deploy_mg
# when the settings the minigraph is built from have changed. For a physical DUT it can never prove
# the DUT's actual configuration - the DUT may have been changed by hand since.
#
# The fingerprint covers only what the minigraph is built from: the DUT (target, hostname, mgmt IP,
# hwsku, interface speed, port count), its links, the topology (name, DUT type, VLAN) and whether a
# push is wanted at all (testbed.deploy_minigraph as it resolves for this target). Not the testbed
# definition names, endpoints, credentials, license, STC version, Allure, ... : those do not change
# what the DUT would be given.
_minigraph_fingerprint() {
    local i v ref
    {
        printf '%s\n' "target=${CFG_TARGET}" "hostname=${CFG_DUT_HOSTNAME}" "mgmt_ip=${CFG_DUT_MGMT_IP}" \
            "hwsku=${CFG_DUT_HWSKU}" "iface_speed=${CFG_DUT_IFACE_SPEED:-}" "total_ports=${CFG_DUT_TOTAL_PORTS:-}" \
            "links=${CFG_DUT_LINKS_COUNT:-0}" \
            "topo=${CFG_TOPO_NAME:-}" "dut_type=${CFG_TOPO_DUT_TYPE:-}" "vlan_id=${CFG_TOPO_VLAN_ID:-}" \
            "vlan_prefix=${CFG_TOPO_VLAN_PREFIX:-}" "vlan_prefix_v6=${CFG_TOPO_VLAN_PREFIX_V6:-}" \
            "vlan_tag=${CFG_TOPO_VLAN_TAG:-}" "vlan_mac=${CFG_TOPO_VLAN_MAC:-}" \
            "deploy_minigraph=${CFG_DEPLOY_MINIGRAPH_EFFECTIVE:-}"
        for (( i=0; i<${CFG_DUT_LINKS_COUNT:-0}; i++ )); do
            for v in DUT_PORT STC_PORT BANDWIDTH VLAN_ID; do
                ref="CFG_DUT_LINK_${i}_${v}"
                printf 'link%s.%s=%s\n' "${i}" "${v}" "${!ref:-}"
            done
        done
    } | sha256sum | cut -d' ' -f1
}

clear_deploy_mg_state() {
    state_set "${STATE_FILE}" DEPLOY_MG_DONE 0
    state_set "${STATE_FILE}" DEPLOY_MG_FINGERPRINT ""
}

# Is a recorded push still applicable to the current settings? A done flag without a matching
# fingerprint (never written, or written for other settings) is not.
deploy_mg_done_valid() {
    state_owns "${STATE_FILE}" DEPLOY_MG_DONE || return 1
    [[ "$(state_get "${STATE_FILE}" DEPLOY_MG_FINGERPRINT)" == "$(_minigraph_fingerprint)" ]]
}

# Called once the testbed files are generated from the current config (phase_gen_config): a recorded
# push for different settings is dropped, and MG_INVALIDATED=1 lets the caller tell the user. Silent
# when nothing was recorded.
MG_INVALIDATED=0
invalidate_stale_deploy_mg() {
    MG_INVALIDATED=0
    state_owns "${STATE_FILE}" DEPLOY_MG_DONE || return 0
    deploy_mg_done_valid && return 0
    clear_deploy_mg_state
    MG_INVALIDATED=1
}

warn_deploy_mg_stale() {
    [[ "${MG_INVALIDATED:-0}" == "1" ]] || return 0
    log_warn "Testbed configuration changed."
    log_detail "Run --deploy-mg before running tests that require the updated DUT configuration."
}

phase_deploy_mg() {
    log_step "Deploying minigraph to DUT (deploy-mg)"
    mkdir -p "${LOG_DIR}"
    local log="${LOG_DIR}/deploy_mg.log"

    # From here on the DUT is being modified: whatever was recorded no longer holds, and must stay
    # gone if this attempt fails or is interrupted. Recorded as done only after it succeeded.
    clear_deploy_mg_state

    local cmd="./testbed-cli.sh -t testbed.yaml deploy-mg ${CFG_TESTBED_CONF_NAME} ${CFG_TESTBED_INV_NAME} password.txt -vvvv"
    log_cmd "${cmd}"
    sonic_mgmt_exec ansible "${cmd}" > "${log}" 2>&1 &
    if spinner_wait "deploy-mg" $!; then
        RESULT_DEPLOY_MG="PASSED"
        state_set "${STATE_FILE}" DEPLOY_MG_FINGERPRINT "$(_minigraph_fingerprint)"
        state_set "${STATE_FILE}" DEPLOY_MG_DONE 1
        log_ok "deploy-mg PASSED (log: ${log})"
    else
        RESULT_DEPLOY_MG="FAILED"
        log_err "deploy-mg FAILED - see ${log}"
        tail -n 40 "${log}" >&2
        return 1
    fi
}

# Extracts the "N" in pytest's final "N passed" summary token (last
# occurrence, in case it's echoed earlier too). Empty output means pytest
# never reported a nonzero passed count - i.e. every collected test was
# skipped, or nothing was collected at all.
_pytest_passed_count() {
    grep -oP '\d+(?= passed)' "$1" | tail -1
}

_run_pytest() {
    # _run_pytest <name> <label> <test_path> <extra_pytest_args...>
    local name="$1" label="$2" test_path="$3"; shift 3
    local log="${LOG_DIR}/${name}.log"
    local allure_args=()
    if [[ "${CFG_ALLURE_ENABLED}" == "1" ]]; then
        local allure_host="${CFG_ALLURE_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
        allure_args=(--allure_server_addr="${allure_host}" --allure_server_port="${CFG_ALLURE_API_PORT}" \
                     --allure_server_project_id="${CFG_ALLURE_PROJECT_ID}" \
                     --alluredir="/tmp/allure_results/${CFG_ALLURE_PROJECT_ID}")
    fi

    local pytest_cmd="python3 -m pytest -s \
        --inventory ../ansible/${CFG_TESTBED_INV_NAME} \
        --host-pattern ${CFG_DUT_HOSTNAME} \
        --testbed ${CFG_TESTBED_CONF_NAME} \
        --testbed_file ../ansible/testbed.yaml \
        --show-capture=stdout --log-cli-level info --showlocals -ra \
        --allow_recover --skip_sanity --disable_loganalyzer \
        ${allure_args[*]} \
        $* \
        ${test_path}"
    log_cmd "${pytest_cmd}"
    sonic_mgmt_exec tests "export ANSIBLE_CONFIG=../ansible ANSIBLE_LIBRARY=../ansible && ${pytest_cmd}" > "${log}" 2>&1 &
    spinner_wait "${label}" $!
    return $?
}

phase_pretest() {
    log_step "Running pretest"
    local log="${LOG_DIR}/pretest.log"
    ensure_clean_pytest_cache
    _run_pytest pretest "Pretest" test_pretest.py
    local rc=$?
    SUMMARY_PRETEST="$(grep -E '[0-9]+ (passed|failed|error)' "${log}" | tail -1)"
    local passed; passed="$(_pytest_passed_count "${log}")"

    if [[ "${rc}" -ne 0 ]]; then
        RESULT_PRETEST="FAILED"
        log_err "pretest FAILED - see ${log}"
        tail -n 40 "${log}" >&2
        return 1
    elif [[ "${passed:-0}" -eq 0 ]]; then
        # pytest exits 0 both when tests pass AND when everything collected
        # was skipped (or nothing was collected) - a bare exit-code check
        # can't tell those apart, so this run validated nothing even though
        # nothing technically errored either.
        RESULT_PRETEST="FAILED"
        SUMMARY_PRETEST="0 tests passed - everything was skipped or nothing was collected (${SUMMARY_PRETEST:-see ${log}})"
        log_err "pretest FAILED - ${SUMMARY_PRETEST}"
        return 1
    else
        RESULT_PRETEST="PASSED"
        log_ok "pretest PASSED - ${SUMMARY_PRETEST:-see ${log}}"
    fi
}

# When a test log shows STC's "could not connect to a license server" failure, say plainly what it
# means and how to fix it (the raw failure is buried in a long gRPC traceback). Returns 0 and prints
# the hint when the log matches, 1 otherwise. Used after a failed smoke test.
license_failure_hint() {
    local log="$1"
    grep -q "Failed to connect to a license server" "${log}" 2>/dev/null || return 1
    if [[ "${CFG_LABSERVER_MODE:-}" == "provisioned" ]]; then
        log_err "Cause: the Labserver (${CFG_LABSERVER_IP}) has no usable license server."
        log_detail "It is provisioned, so this tool does not configure it."
        log_detail "- License it (SPIRENTD_LICENSE_FILE on the Labserver) and re-run."
    else
        log_err "Cause: the Labserver has no usable license server."
        log_detail "- Set a valid deployment.stc.license_server in config.yaml (for example '@hostname' or 'host:port') and run --deploy-only again to redeploy the Labserver with it."
        log_detail "- Licensed the Labserver another way? Check that setup."
    fi
    return 0
}

phase_smoke_test() {
    log_step "Running snappi smoke test"
    local log="${LOG_DIR}/smoke_test.log"
    # Upstream sonic-mgmt's shared conditional_mark rule for the whole
    # snappi_tests/ directory skips on asic_type=='vs', which would also
    # blanket-skip this specific file's patch-added vs-tolerant thresholds
    # before they ever run. --ignore-conditional-mark disables that plugin
    # for this one pytest invocation only - since only test_snappi.py is
    # ever collected here (never the rest of snappi_tests/, which is NOT
    # vs-safe), this can't accidentally pull in unrelated hardware-only
    # tests the way patching the shared rule file would.
    _run_pytest smoke_test "Snappi smoke test" snappi_tests/test_snappi.py --ignore-conditional-mark
    local rc=$?
    SUMMARY_SMOKE="$(grep -E '[0-9]+ (passed|failed|error)' "${log}" | tail -1)"
    local passed; passed="$(_pytest_passed_count "${log}")"

    if [[ "${rc}" -ne 0 ]]; then
        RESULT_SMOKE="FAILED"
        log_err "snappi smoke test FAILED - see ${log}"
        tail -n 40 "${log}" >&2
        if license_failure_hint "${log}"; then
            SUMMARY_SMOKE="${SUMMARY_SMOKE:+${SUMMARY_SMOKE} - }Labserver has no usable license server (see config.yaml deployment.stc.license_server)"
        fi
        return 1
    elif [[ "${passed:-0}" -eq 0 ]]; then
        # Same "exit 0 but nothing actually ran" case as phase_pretest above -
        # most commonly the whole file got skipped (see the SKIPPED reason in
        # $log), which is not a pass.
        RESULT_SMOKE="FAILED"
        SUMMARY_SMOKE="0 tests passed - the smoke test was skipped, not actually run (see ${log})"
        log_err "snappi smoke test FAILED - ${SUMMARY_SMOKE}"
        return 1
    else
        RESULT_SMOKE="PASSED"
        log_ok "snappi smoke test PASSED"
        [[ -n "${SUMMARY_SMOKE}" ]] && log_info "${SUMMARY_SMOKE}"
    fi
}
