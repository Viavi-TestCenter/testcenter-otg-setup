#!/usr/bin/env bash
# report.sh — phase 9: structured console summary plus a machine-readable
# summary.json alongside the run's logs.

PHASE_RECORDS=()   # "Label|STATUS|Detail"
record_phase() { PHASE_RECORDS+=("$1|$2|${3:-}"); }

# print_run_config — echoes the resolved config.yaml values that materially
# shape this run (versions, deployment topology, sonic-mgmt source, cleanup
# policy). Printed once, right after config.yaml is loaded and before any
# phase executes, so a run's console/log output is self-describing even
# without opening config.yaml. Purely informational - reads CFG_*, never
# mutates state.
row() { printf '%-32s : %s\n' "$1" "$2"; }

print_run_config() {
    log_step "Run configuration"
    echo "================ SNAPPI TEST CONFIGURATION ================="

    row "Run mode" "$MODE"
    row "Config file" "$CONFIG_FILE"
    echo "--- Traffic generator (TestCenter) ---------------------------"
    row "TestCenter version" "$CFG_TC_VERSION"
    row "Labserver version" "$CFG_TC_LABSERVER_VERSION (derived from testcenter.version)"
    row "OTG service version" "${CFG_TC_OTGSERVICE_VERSION}.* (major.minor match against testcenter.version)"

    echo "--- Deployment topology ---------------------------------------"
    row "Labserver deployment mode" "$CFG_DEPLOY_MODE"
    row "OTG service deployment mode" "$CFG_DEPLOY_MODE"
    if [[ "$CFG_DEPLOY_MODE" == "docker-compose" ]]; then
        row "  Compose stack" "otg-compose.yaml (project=$COMPOSE_PROJECT, source=$OTG_SOURCE_DIR)"
    fi
    if [[ "$CFG_DEPLOY_MODE" != "provisioned" ]]; then
        row "STC chassis" "Docker container via containerlab (mgmt ${CFG_STC_CHASSIS_IP})"
    else
        row "STC chassis" "Externally provisioned (mgmt ${CFG_STC_CHASSIS_IP})"
    fi
    if [[ "$CFG_DUT_MODE" == "virtual" ]]; then
        row "SONiC DUT" "Virtual (sonic-vs) - Docker container via containerlab"
        row "  DUT image" "$CFG_DUT_IMAGE"
    else
        row "SONiC DUT" "Physical hardware"
    fi
    row "  DUT hostname / hwsku" "$CFG_DUT_HOSTNAME / $CFG_DUT_HWSKU"

    echo "--- sonic-mgmt source -------------------------------------------"
    row "Repository / branch" "$CFG_SONIC_MGMT_REPO ($CFG_SONIC_MGMT_BRANCH)"
    row "Source commit id" "$CFG_SONIC_MGMT_BASELINE_COMMIT"
    if [[ "$CFG_SONIC_MGMT_PATCH_APPLY" == "1" ]]; then
        row "STC/OTG patch" "Enabled ($CFG_SONIC_MGMT_PATCH_FILE)"
    else
        row "STC/OTG patch" "Disabled"
    fi
    if [[ "$SONIC_MGMT_USER_PROVIDED" -eq 1 ]]; then
        row "Keep source on destroy" "N/A (user-supplied checkout, never deleted by this tool)"
    elif [[ "$CFG_SONIC_MGMT_KEEP_SRC" == "1" ]]; then
        row "Keep source on destroy" "True (--destroy will not delete the tool-owned clone)"
    else
        row "Keep source on destroy" "False (--destroy removes the tool-owned clone)"
    fi

    echo "--- Reporting / cleanup policy ----------------------------------"
    if [[ "$CFG_ALLURE_ENABLED" == "1" ]]; then
        row "Allure service" "Enabled - deployed via docker-compose (UI port ${CFG_ALLURE_UI_PORT})"
    else
        row "Allure service" "Disabled"
    fi
    if [[ "$CFG_CLEANUP_ENV_ON_FAILURE" == "1" ]]; then
        row "Cleanup ENV on failure" "True (environment auto torn down on failure)"
    else
        row "Cleanup ENV on failure" "False (kept for debugging)"
    fi
    if [[ "$CFG_REPLACE_ENV_ON_VERSION_CHANGE" == "1" ]]; then
        row "Replace ENV on version change" "True (tool-owned environment auto torn down/redeployed on a testcenter.version change)"
    else
        row "Replace ENV on version change" "False (old environment kept; per-resource reuse checks decide)"
    fi

    echo "==============================================================="
}

_json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

phase_report() {
    log_step "Run summary"
    local overall="PASS"
    local width=24

    echo "================= SNAPPI TEST SUMMARY ================="
    local rec label status detail
    for rec in "${PHASE_RECORDS[@]}"; do
        IFS='|' read -r label status detail <<< "$rec"
        printf '%-*s : %s%s\n' "$width" "$label" "$status" "${detail:+ ($detail)}"
        [[ "$status" == "FAILED" ]] && overall="FAIL"
    done
    echo "---------------------------------------------------------"
    echo "Logs   : ${LOG_DIR:-n/a}"
    # ALLURE_URL is normally set by phase_deploy_services (deploy.sh), which
    # --test-only skips since it assumes Allure is already running. Fall back
    # to deriving it from config here so the summary still shows the link.
    if [[ "${CFG_ALLURE_ENABLED:-0}" == "1" && -z "${ALLURE_URL:-}" ]]; then
        local allure_host="${CFG_ALLURE_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
        ALLURE_URL="http://${allure_host}:${CFG_ALLURE_API_PORT}/allure-docker-service/projects/${CFG_ALLURE_PROJECT_ID}/reports/latest/index.html"
    fi
    if [[ "${CFG_ALLURE_ENABLED:-0}" == "1" && -n "${ALLURE_URL:-}" ]]; then
        echo "Allure : $ALLURE_URL"
    else
        echo "Allure : not enabled"
    fi
    echo "========================================================="
    echo "RESULT: $overall"

    _write_summary_json "$overall"

    [[ "$overall" == "PASS" ]]
}

_write_summary_json() {
    local overall="$1"
    [[ -n "${LOG_DIR:-}" ]] || return 0
    mkdir -p "$LOG_DIR"
    local f="$LOG_DIR/summary.json"

    {
        printf '{\n'
        printf '  "timestamp": %s,\n' "$(_json_escape "$(date -Is)")"
        printf '  "result": %s,\n' "$(_json_escape "$overall")"
        printf '  "config_file": %s,\n' "$(_json_escape "$CONFIG_FILE")"
        printf '  "log_dir": %s,\n' "$(_json_escape "$LOG_DIR")"
        printf '  "allure_url": %s,\n' "$(_json_escape "${ALLURE_URL:-}")"
        printf '  "phases": [\n'
        local n=${#PHASE_RECORDS[@]} i=0
        local rec label status detail
        for rec in "${PHASE_RECORDS[@]}"; do
            IFS='|' read -r label status detail <<< "$rec"
            i=$((i+1))
            printf '    {"name": %s, "status": %s, "detail": %s}%s\n' \
                "$(_json_escape "$label")" "$(_json_escape "$status")" "$(_json_escape "$detail")" \
                "$([[ $i -lt $n ]] && echo ',')"
        done
        printf '  ]\n'
        printf '}\n'
    } > "$f"
    log_info "Machine-readable summary: $f"
}
