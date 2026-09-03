#!/usr/bin/env bash
# run_snappi_test.sh — single-command deployment + test runner for the
# Snappi/OTG/STC-chassis lab's pretest and smoke test
#
# Usage:
#   ./run_snappi_test.sh [-c config.yaml] [options]
#
# Options:
#   -c, --config <path>   Path to config.yaml (default: ./config.yaml next to this script)
#   --skip-env-check      Skip host dependency check/install (phase 1)
#   --deploy-only         Deploy the environment (labserver+otg+containerlab),
#                          then stop - no inventory verify, no deploy-mg, no
#                          pretest/smoke test/cleanup.
#   --test-only           Do not touch deployed infrastructure (no service deploy, no
#                          containerlab destroy/deploy). Runs lightweight health/
#                          connectivity/inventory validation, then deploy-mg + pretest
#                          + smoke test against what is already running.
#   --deploy-mg           Run only deploy-mg against an already-deployed environment
#                          (same preconditions as --test-only: sonic-mgmt container
#                          running, source checkout present). Regenerates the Ansible
#                          config and runs connectivity/inventory verify first, then
#                          stops - no pretest/smoke test/cleanup.
#   --pretest              Run only the pretest against an already-deployed environment.
#                          If deploy-mg has not been done since the environment was last
#                          (re)deployed, it is triggered automatically first (same as
#                          --deploy-mg above); otherwise the prior deploy-mg is reused.
#   --smoke-test           Run only the Snappi smoke test against an already-deployed
#                          environment. Same automatic deploy-mg trigger as --pretest.
#   --no-cleanup          Skip the post-test pytest/ansible cache cleanup. Only affects
#                          cache state, never deployed services (see --destroy for that).
#   --destroy             Remove only resources this tool itself created (see the
#                          per-run state file). Never touches externally provisioned
#                          services, a user-supplied sonic-mgmt checkout, or a physical
#                          DUT. Runs no tests.
#   --show-config         Load, validate and print the resolved run configuration,
#                          then exit. Read-only - no lock, no log dir, no phases run.
#   -h, --help             Show this help and exit
#
# config.yaml's cleanup.env_on_failure (default: true) controls whether a FAILED
# run (deploy-mg or pretest/smoke test) automatically tears down the tool-owned
# environment afterward (same scope as --destroy). A successful run always keeps
# the environment deployed for reuse regardless of this setting. Set it to false
# to keep a failed environment around for debugging. Ignored by --deploy-only,
# which always keeps the environment deployed regardless of outcome.
#
# --pretest/--smoke-test decide whether deploy-mg is still needed by checking
# DEPLOY_MG_DONE in the per-run state file (.run_snappi_test/state.env) - set
# whenever deploy-mg last succeeded, and cleared whenever the environment is
# redeployed (containerlab always recreates the DUT) or torn down (--destroy).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

MODE="full"          # full | deploy-only | test-only | deploy-mg | pretest | smoke-test | destroy | show-config
SKIP_ENV_CHECK=0
NO_CLEANUP=0

usage() { sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        --skip-env-check) SKIP_ENV_CHECK=1; shift ;;
        --deploy-only) MODE="deploy-only"; shift ;;
        --test-only) MODE="test-only"; shift ;;
        --deploy-mg) MODE="deploy-mg"; shift ;;
        --pretest) MODE="pretest"; shift ;;
        --smoke-test) MODE="smoke-test"; shift ;;
        --no-cleanup) NO_CLEANUP=1; shift ;;
        --destroy) MODE="destroy"; shift ;;
        --show-config) MODE="show-config"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/env_check.sh
source "$LIB_DIR/env_check.sh"
# shellcheck source=lib/sonic_mgmt.sh
source "$LIB_DIR/sonic_mgmt.sh"
# shellcheck source=lib/gen_config.sh
source "$LIB_DIR/gen_config.sh"
# shellcheck source=lib/deploy.sh
source "$LIB_DIR/deploy.sh"
# shellcheck source=lib/verify.sh
source "$LIB_DIR/verify.sh"
# shellcheck source=lib/run_tests.sh
source "$LIB_DIR/run_tests.sh"
# shellcheck source=lib/cleanup.sh
source "$LIB_DIR/cleanup.sh"
# shellcheck source=lib/report.sh
source "$LIB_DIR/report.sh"

load_config

if [[ "$MODE" == "show-config" ]]; then
    print_run_config
    exit 0
fi

# Foreground and before anything backgrounds docker calls (run_phase_with_spinner) -
# see docker_bootstrap_sudo in lib/common.sh.
docker_bootstrap_sudo

LOG_DIR="$LOG_BASE_DIR/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/run.log"

state_file_init "$STATE_FILE"
acquire_lock "$LOCK_FILE"
_on_exit() {
    release_lock
    [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
}
trap _on_exit EXIT

log_info "run_snappi_test.sh starting - mode=$MODE config=$CONFIG_FILE log_dir=$LOG_DIR"

# ---------------------------------------------------------------- destroy ---
if [[ "$MODE" == "destroy" ]]; then
    phase_destroy
    exit $?
fi

print_run_config

# --------------------------------------------------------- infra + deploy ---
if [[ "$MODE" == "full" || "$MODE" == "deploy-only" ]]; then
    phase_check_version_change

    if [[ "$SKIP_ENV_CHECK" -eq 1 ]]; then
        record_phase "Environment prep" "SKIPPED"
    elif phase_env_check; then
        record_phase "Environment prep" "OK"
    else
        record_phase "Environment prep" "FAILED"; phase_report; exit 1
    fi

    if phase_check_artifacts; then
        record_phase "Artifact validation" "OK"
    else
        record_phase "Artifact validation" "FAILED"; phase_report; exit 1
    fi

    phase_sonic_mgmt_source
    record_phase "sonic-mgmt source" "OK" "${SONIC_MGMT_PATCH_APPLIED:-n/a}"

    phase_sonic_mgmt_container
    record_phase "sonic-mgmt container" "OK"

    phase_generate_ansible_config
    record_phase "Ansible config generation" "OK"

    if phase_deploy_services; then
        record_phase "Service deployment" "OK" "labserver+otg+clab(${CFG_DUT_MODE})"
        # containerlab always recreates the DUT node above, which wipes out
        # any minigraph pushed by a previous deploy-mg - so a prior "done"
        # flag must not survive past this point. Cleared unconditionally
        # (not just on success) so a failed deploy-mg right after this can't
        # leave a stale DEPLOY_MG_DONE=1 from an earlier run in place.
        state_set "$STATE_FILE" DEPLOY_MG_DONE 0
    else
        record_phase "Service deployment" "FAILED"; phase_report; exit 1
    fi
fi

if [[ "$MODE" == "deploy-only" ]]; then
    log_ok "Environment deployed (--deploy-only) - skipping inventory verify, deploy-mg, pretest/smoke test/cleanup."
    phase_report
    exit $?
fi

# --------------------------------------------------- verify (full only) ---
if [[ "$MODE" == "full" ]]; then
    if phase_verify; then
        record_phase "Connectivity/inventory verify" "OK"
    else
        record_phase "Connectivity/inventory verify" "FAILED"; phase_report; exit 1
    fi
fi

# ---------------------------- test-only / deploy-mg / pretest / smoke-test ---
# All four assume the environment is already deployed and never touch
# infrastructure themselves.
if [[ "$MODE" == "test-only" || "$MODE" == "deploy-mg" || "$MODE" == "pretest" || "$MODE" == "smoke-test" ]]; then
    docker ps --format '{{.Names}}' | grep -qx "$SONIC_MGMT_CONTAINER" \
        || die "sonic-mgmt container '$SONIC_MGMT_CONTAINER' is not running. --${MODE} assumes the environment is already deployed - run without this option (or with --deploy-only) first."
    [[ -d "$SONIC_MGMT_DIR/.git" ]] || die "sonic-mgmt source not found at $SONIC_MGMT_DIR"

    phase_generate_ansible_config
    record_phase "Ansible config generation" "OK"
fi

# deploy-mg is needed whenever this run must guarantee a fresh minigraph:
# full/test-only/--deploy-mg always do, while --pretest/--smoke-test only do
# it if a previous deploy-mg hasn't already been recorded as done since the
# environment was last (re)deployed or destroyed.
NEED_DEPLOY_MG=0
case "$MODE" in
    full|test-only|deploy-mg) NEED_DEPLOY_MG=1 ;;
    pretest|smoke-test) state_owns "$STATE_FILE" DEPLOY_MG_DONE || NEED_DEPLOY_MG=1 ;;
esac

# --test-only and --deploy-mg both need a fresh verify before deploy-mg;
# --pretest/--smoke-test only need it when they're about to trigger deploy-mg
# themselves. "full" already ran its own verify above.
if [[ "$MODE" == "test-only" ]] || { [[ "$NEED_DEPLOY_MG" -eq 1 ]] && [[ "$MODE" != "full" ]]; }; then
    if phase_verify; then
        record_phase "Connectivity/inventory verify" "OK"
    else
        record_phase "Connectivity/inventory verify" "FAILED"; phase_report; exit 1
    fi
fi

# ------------------------------------------------------------- deploy-mg ---
if [[ "$NEED_DEPLOY_MG" -eq 1 ]]; then
    if phase_deploy_mg; then
        record_phase "deploy-mg" "$RESULT_DEPLOY_MG"
        state_set "$STATE_FILE" DEPLOY_MG_DONE 1
    else
        record_phase "deploy-mg" "$RESULT_DEPLOY_MG"
        cleanup_env_on_failure
        phase_report; exit 1
    fi
else
    log_ok "deploy-mg already done since the environment was last (re)deployed - skipping (use --deploy-mg to force a rerun)"
    record_phase "deploy-mg" "SKIPPED" "already done"
fi

if [[ "$MODE" == "deploy-mg" ]]; then
    phase_report
    exit $?
fi

# ------------------------------------------------------------------ tests --
overall_rc=0

if [[ "$MODE" == "smoke-test" ]]; then
    record_phase "Pretest" "SKIPPED" "not requested"
elif phase_pretest; then
    record_phase "Pretest" "$RESULT_PRETEST" "$SUMMARY_PRETEST"
else
    record_phase "Pretest" "$RESULT_PRETEST" "$SUMMARY_PRETEST"
    overall_rc=1
fi

if [[ "$MODE" == "pretest" ]]; then
    record_phase "Snappi smoke test" "SKIPPED" "not requested"
elif [[ $overall_rc -eq 0 ]]; then
    if phase_smoke_test; then
        record_phase "Snappi smoke test" "$RESULT_SMOKE" "$SUMMARY_SMOKE"
    else
        record_phase "Snappi smoke test" "$RESULT_SMOKE" "$SUMMARY_SMOKE"
        overall_rc=1
    fi
else
    record_phase "Snappi smoke test" "SKIPPED" "pretest failed"
fi

# ----------------------------------------------------------------- cleanup --
if [[ $overall_rc -ne 0 ]]; then
    cleanup_env_on_failure
fi

if [[ "$NO_CLEANUP" -eq 1 ]]; then
    record_phase "Cache cleanup" "SKIPPED" "--no-cleanup"
elif [[ $overall_rc -ne 0 && "$CFG_CLEANUP_ENV_ON_FAILURE" == "1" ]]; then
    record_phase "Cache cleanup" "SKIPPED" "environment torn down"
else
    phase_cleanup_cache
    record_phase "Cache cleanup" "OK"
fi

phase_report
report_rc=$?
exit $(( overall_rc != 0 ? 1 : report_rc ))
