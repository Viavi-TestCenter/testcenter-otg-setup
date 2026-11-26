#!/usr/bin/env bash
# run_snappi_test.sh — single-command deployment + test runner for the
# Snappi/OTG/STC-chassis lab's pretest and smoke test
#
# Usage:
#   ./run_snappi_test.sh [-c config.yaml] [options]
#
# The run is split into stages. Deployment is separate from the
# testbed configuration and from the minigraph push:
#   1 deploy        --deploy-only    reads config.yaml's deployment: section only
#   2 access check  --access-check   reachability + DUT login (+ key install on a physical DUT)
#   3 gen config    --gen-config     sonic-mgmt testbed files, then the inventory check
#   4 deploy-mg     --deploy-mg      push the generated minigraph to the DUT
#   5 tests         --pretest, --smoke-test, --test-only, and the full run (no flag)
# Every test stage (4, 5) first runs stage 2 and then stage 3.
#
# Options:
#   -c, --config <path>   Path to config.yaml (default: ./config.yaml next to this script)
#   --skip-env-check      Skip host dependency check/install (phase 1)
#   --deploy-only         Stage 1. Deploy the environment (sonic-mgmt source and container,
#                          whatever this tool owns of Labserver/OTG service and the virtual
#                          chassis/DUT), then stop. Reads only the deployment: section (plus
#                          testbed.endpoints.labserver_ip when a standalone OTG service runs
#                          against a provisioned Labserver). Writes no ansible/testbed files,
#                          contacts no external component, and never touches a physical DUT.
#   --access-check        Stage 2. Check that every external component (physical chassis and
#                          DUT, provisioned Labserver and OTG service) is reachable and that
#                          the sonic-mgmt container can log in to the DUT. For a PHYSICAL DUT it
#                          also appends the sonic-mgmt public key to the DUT admin user's
#                          ~/.ssh/authorized_keys if it is missing (its only write; SONiC
#                          configuration is not modified, no minigraph is pushed). Needs only
#                          testbed.endpoints.* and testbed.dut.{mgmt_ip, credentials}; needs the
#                          sonic-mgmt container running (run --deploy-only first).
#   --gen-config          Stage 3. Regenerate the testbed config files (device/link CSVs,
#                          Ansible inventory, testbed.yaml, topology vars, DUT/OTG credentials),
#                          then check that the inventory lists the DUT. Requires the sonic-mgmt
#                          source checkout (does not deploy or clone anything), contacts no
#                          external component, and runs no tests. The inventory check is skipped
#                          with a warning if the sonic-mgmt container is not running.
#   --deploy-mg           Stage 4. Run stages 2-3, then push the generated minigraph. Always
#                          pushes, whatever testbed.deploy_minigraph says. On a physical DUT this
#                          REPLACES its running configuration.
#   --pretest             Run only the pretest against an already-deployed environment (stages
#                          2-3 first). The minigraph is pushed first only when
#                          testbed.deploy_minigraph resolves to true AND no push is recorded as
#                          done since the environment was last (re)deployed.
#   --smoke-test          Run only the Snappi smoke test against an already-deployed environment.
#                          Same automatic push rule as --pretest.
#   --test-only           Do not touch deployed infrastructure. Stages 2-3, then the minigraph
#                          push (only when testbed.deploy_minigraph resolves to true), pretest and
#                          smoke test against what is already running.
#   --validate            Validate the whole config.yaml (deployment: and testbed:) and exit.
#   --no-cleanup          Skip the post-test pytest/ansible cache cleanup. Only affects
#                          cache state, never deployed services (see --destroy for that).
#   --destroy             Remove only resources this tool itself created (see the
#                          per-run state file). Never touches externally provisioned
#                          services, a user-supplied sonic-mgmt checkout, or a physical
#                          DUT. Runs no tests.
#   --show-config         Load, validate and print the resolved run configuration (including
#                          each component's address and which section owns it), then exit.
#                          Read-only - no lock, no log dir, no phases run. testbed: problems are
#                          shown as warnings. For a legacy flat config.yaml it also prints the
#                          migrated deployment:/testbed: layout so you can copy it.
#   --list-versions       Scan deployment.images.dir and report which TestCenter (STC) versions
#                          are currently deliverable/testable (STC + labserver artifacts
#                          present, OTG service installer matching major.minor), plus
#                          whether the configured deployment.stc.version is ready. Read-only -
#                          no lock, no log dir, no phases run, nothing extracted/downloaded.
#   -h, --help             Show this help and exit
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

MODE="full"          # full | deploy-only | access-check | gen-config | deploy-mg | pretest | smoke-test | test-only | validate | destroy | show-config | list-versions
SKIP_ENV_CHECK=0
NO_CLEANUP=0

usage() { sed -n '2,/^set -uo pipefail/{/^set -uo pipefail/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        --skip-env-check) SKIP_ENV_CHECK=1; shift ;;
        --deploy-only) MODE="deploy-only"; shift ;;
        --access-check) MODE="access-check"; shift ;;
        --gen-config) MODE="gen-config"; shift ;;
        --deploy-mg) MODE="deploy-mg"; shift ;;
        --pretest) MODE="pretest"; shift ;;
        --smoke-test) MODE="smoke-test"; shift ;;
        --test-only) MODE="test-only"; shift ;;
        --validate) MODE="validate"; shift ;;
        --no-cleanup) NO_CLEANUP=1; shift ;;
        --destroy) MODE="destroy"; shift ;;
        --show-config) MODE="show-config"; shift ;;
        --list-versions) MODE="list-versions"; shift ;;
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
# shellcheck source=lib/versions.sh
source "$LIB_DIR/versions.sh"

# deployment.stc.license_server tells this tool which license server to write into a Labserver it
# deploys, and which one a virtual (containerized) STC chassis uses. It is only advisory here: the
# license may come from somewhere this tool cannot see (an Aion license, or a license server set
# up by hand in the Labserver), so a missing value is a WARNING, never a stop. It is shown before
# the test cases run (full, --test-only, --smoke-test) and after the deploy (--deploy-only, see
# warn_labserver_unlicensed). deployment.stc.license_managed_externally: true acknowledges that the
# lab is licensed another way and silences all of them. The value itself is a run-mode rule, not a schema one, so it is
# checked here, not in the loader.
check_license_server() {
    local reason=""
    if [[ "$CFG_TC_MODE" == "virtual" && ( "$MODE" == "full" || "$MODE" == "test-only" || "$MODE" == "smoke-test" ) ]]; then
        reason="this run sends real traffic through a virtual (containerized) STC chassis"
    fi
    if [[ "$CFG_LABSERVER_MODE" != "provisioned" && "$MODE" == "full" ]]; then
        reason="this tool deploys the Labserver and writes the license server into it"
    fi
    [[ -n "$reason" ]] || return 0
    license_server_valid && return 0
    [[ "${CFG_LICENSE_MANAGED_EXTERNALLY:-0}" == "1" ]] && return 0

    if [[ "$CFG_LABSERVER_MODE" == "provisioned" ]]; then
        log_warn "deployment.stc.license_server is empty or still the placeholder '@license-server.example.com'. The Labserver is provisioned (not deployed by this tool), so this value is not used; make sure that Labserver is licensed for the virtual chassis. You can ignore this if it already is."
        return 0
    fi

    log_warn "deployment.stc.license_server is empty or still the placeholder '@license-server.example.com'; ${reason}.
         If the Labserver is licensed another way (an Aion license, or a license server you configured in the Labserver yourself) you can ignore this.
         Otherwise set a valid license server (for example '@hostname' or 'host:port') and run --deploy-only again; the STC tests need a licensed Labserver."
}

# Virtual lab only. --smoke-test and --test-only do not redeploy, so they would run against a
# Labserver that --deploy-only brought up without a license server. Warn before the test cases
# start (the license may have been set up another way). Skipped when the config value is itself
# missing, since check_license_server has just said so. The full run redeploys first, and a
# physical chassis has its own licensing path, so neither is checked here.
check_labserver_licensed() {
    [[ "$CFG_TC_MODE" == "virtual" && ( "$MODE" == "smoke-test" || "$MODE" == "test-only" ) ]] || return 0
    license_server_valid || return 0
    [[ "${CFG_LICENSE_MANAGED_EXTERNALLY:-0}" == "1" ]] && return 0
    state_owns "$STATE_FILE" LABSERVER_UNLICENSED || return 0
    log_warn "The Labserver was deployed without a license server, and deployment.stc.license_server is set now.
         If you licensed it another way you can ignore this. Otherwise run --deploy-only again to redeploy the Labserver with the configured license server."
}

# After --deploy-only on a virtual lab: say so when the Labserver came up without a license
# server. Printed here, in the foreground, because the deploy phase's own output goes to a log file.
warn_labserver_unlicensed() {
    [[ "$MODE" == "deploy-only" && "$CFG_TC_MODE" == "virtual" ]] || return 0
    [[ "${CFG_LICENSE_MANAGED_EXTERNALLY:-0}" == "1" ]] && return 0
    state_owns "$STATE_FILE" LABSERVER_UNLICENSED || return 0
    log_warn "The Labserver was deployed without a license server (deployment.stc.license_server is empty or still the placeholder '@license-server.example.com').
         If you license it another way (an Aion license, or a license server you configure in the Labserver yourself) you can ignore this.
         Otherwise set a valid license server in config.yaml and run --deploy-only again before running tests."
}

# Does this mode need a reachable docker daemon from the start? --gen-config does not: it only
# writes host-side files and skips its inventory check with a warning when the sonic-mgmt
# container (or docker itself) is not available, so it must not prompt for sudo or die
# without docker (docker_bootstrap_sudo does both).
mode_needs_docker() {
    [[ "$MODE" != "gen-config" ]]
}

# Will phase 1 (phase_env_check) run in this invocation? It is what installs docker, so the
# docker bootstrap must not be fatal before it has had its chance.
env_check_will_run() {
    [[ ( "$MODE" == "full" || "$MODE" == "deploy-only" ) && "$SKIP_ENV_CHECK" -ne   1 ]]
}

# The post-deploy modes assume stage 1 already ran: the sonic-mgmt container
# must be up and the source checkout present.
require_deployed_environment() {
    docker ps --format '{{.Names}}' | grep -qx "$SONIC_MGMT_CONTAINER" \
        || die "sonic-mgmt container '$SONIC_MGMT_CONTAINER' is not running. --${MODE} assumes the environment is already deployed - run without this option (or with --deploy-only) first."
    [[ -d "$SONIC_MGMT_DIR/.git" ]] || die "sonic-mgmt source not found at $SONIC_MGMT_DIR"
}

# Stage 2: reachability of every component, DUT login, key install on a physical DUT.
run_access_step() {
    if phase_access_check; then
        record_phase "Access check" "OK"
    else
        record_phase "Access check" "FAILED"; phase_report; exit 1
    fi
}

# Stage 3: testbed files for sonic-mgmt, then the inventory check.
run_gen_step() {
    if phase_gen_config; then
        record_phase "Testbed config generation" "OK"
    else
        record_phase "Testbed config generation" "FAILED"; phase_report; exit 1
    fi
}

# The staged run. Everything below is driven by $MODE and the resolved CFG_* values;
# tests/test_stage_flow.sh stubs every phase and asserts the call order per mode.
run_stages() {
    # ---------------------------------------------------------------- destroy ---
    if [[ "$MODE" == "destroy" ]]; then
        phase_destroy
        exit $?
    fi

    # ------------------------------------------------- stage 3: gen-config alone ---
    if [[ "$MODE" == "gen-config" ]]; then
        [[ -d "$SONIC_MGMT_DIR/.git" ]] \
            || die "sonic-mgmt source not found at $SONIC_MGMT_DIR - --gen-config assumes the environment has already been deployed at least once (run without this option, or --deploy-only, first)."
        phase_gen_config
        exit $?
    fi

    print_run_config

    # ----------------------------------------------- stage 1: infra + deploy ---
    if [[ "$MODE" == "full" || "$MODE" == "deploy-only" ]]; then
        phase_check_version_change

        if [[ "$SKIP_ENV_CHECK" -eq 1 ]]; then
            record_phase "Environment prep" "SKIPPED"
        elif phase_env_check; then
            record_phase "Environment prep" "OK"
            # docker may have just been installed: set up the sudo fallback now (foreground).
            docker_bootstrap_sudo
        else
            record_phase "Environment prep" "FAILED"; phase_report; exit 1
        fi

        if phase_check_artifacts; then
            record_phase "Artifact validation" "OK"
        else
            record_phase "Artifact validation" "FAILED"; phase_report; exit 1
        fi

        phase_sonic_mgmt_source
        record_phase "sonic-mgmt source" "OK" "patch: ${SONIC_MGMT_PATCH_APPLIED:-n/a}, custom tests: ${SONIC_MGMT_CUSTOM_TESTS_APPLIED:-n/a}"

        phase_sonic_mgmt_container
        record_phase "sonic-mgmt container" "OK"

        # No ansible/testbed files are generated here (stage 3 does that, just before
        # they are needed); the containerlab topology is part of the deploy itself.
        if phase_deploy_services; then
            if [[ "$CFG_TC_MODE" == "virtual" ]]; then
                record_phase "Service deployment" "OK" "labserver=${CFG_LABSERVER_MODE} otg=${CFG_OTG_MODE} clab(${CFG_DUT_MODE})"
            else
                record_phase "Service deployment" "OK" "labserver=${CFG_LABSERVER_MODE} otg=${CFG_OTG_MODE} (deployment.target=physical, no clab)"
            fi
            # containerlab (when deployment.target=virtual) always recreates the DUT
            # node above, which wipes out any minigraph pushed by a previous
            # deploy-mg - so a prior "done" flag must not survive past this point.
            # Cleared unconditionally (not just on success, and regardless of
            # target) so a failed deploy-mg right after this can't leave a stale
            # DEPLOY_MG_DONE=1 from an earlier run in place.
            state_set "$STATE_FILE" DEPLOY_MG_DONE 0
        else
            record_phase "Service deployment" "FAILED"; phase_report; exit 1
        fi
    fi

    if [[ "$MODE" == "deploy-only" ]]; then
        log_ok "Environment deployed (--deploy-only) - skipping access check, gen-config, deploy-mg, pretest/smoke test/cleanup."
        warn_labserver_unlicensed
        phase_report
        exit $?
    fi

    # ------------------------------------------------- stage 2: access check ---
    # Every post-deploy mode assumes the environment is already deployed and never
    # touches infrastructure itself; "full" has just deployed it.
    [[ "$MODE" == "full" ]] || require_deployed_environment

    run_access_step

    if [[ "$MODE" == "access-check" ]]; then
        phase_report
        exit $?
    fi

    # ----------------------------------------------- stage 3: testbed config ---
    run_gen_step

    # ------------------------------------------------------ stage 4: deploy-mg ---
    # The minigraph is pushed when this run must guarantee a fresh one and
    # testbed.deploy_minigraph allows it: --deploy-mg always pushes; full/--test-only
    # push whenever the effective setting is true (always on a virtual lab under
    # "auto"); --pretest/--smoke-test push only if a previous deploy-mg hasn't already
    # been recorded as done since the environment was last (re)deployed or destroyed.
    # A physical DUT under "auto" is never pushed to automatically.
    NEED_DEPLOY_MG=0
    case "$MODE" in
        deploy-mg) NEED_DEPLOY_MG=1 ;;
        full|test-only)
            [[ "$CFG_DEPLOY_MINIGRAPH_EFFECTIVE" == "1" ]] && NEED_DEPLOY_MG=1 ;;
        pretest|smoke-test)
            if [[ "$CFG_DEPLOY_MINIGRAPH_EFFECTIVE" == "1" ]] && ! state_owns "$STATE_FILE" DEPLOY_MG_DONE; then
                NEED_DEPLOY_MG=1
            fi ;;
    esac

    if [[ "$NEED_DEPLOY_MG" -eq 1 ]]; then
        if phase_deploy_mg; then
            record_phase "deploy-mg" "$RESULT_DEPLOY_MG"
            state_set "$STATE_FILE" DEPLOY_MG_DONE 1
        else
            record_phase "deploy-mg" "$RESULT_DEPLOY_MG"
            cleanup_env_on_failure
            phase_report; exit 1
        fi
    elif [[ "$CFG_DEPLOY_MINIGRAPH_EFFECTIVE" != "1" ]]; then
        log_ok "testbed.deploy_minigraph resolves to false (${CFG_DEPLOY_MINIGRAPH:-auto}, target ${CFG_TARGET}) - no minigraph pushed; the DUT's configuration is left as it is (use --deploy-mg to push explicitly)"
        record_phase "deploy-mg" "SKIPPED" "deploy_minigraph=${CFG_DEPLOY_MINIGRAPH:-auto} on ${CFG_TARGET}"
    else
        log_ok "deploy-mg already done since the environment was last (re)deployed - skipping (use --deploy-mg to force a rerun)"
        record_phase "deploy-mg" "SKIPPED" "already done"
    fi

    if [[ "$MODE" == "deploy-mg" ]]; then
        phase_report
        exit $?
    fi

    # -------------------------------------------------------- stage 5: tests --
    local overall_rc=0

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
    elif [[ $overall_rc -ne 0 && "${CFG_CLEANUP_ENV_ON_FAILURE:-0}" == "1" ]]; then
        record_phase "Cache cleanup" "SKIPPED" "environment torn down"
    else
        phase_cleanup_cache
        record_phase "Cache cleanup" "OK"
    fi

    phase_report
    local report_rc=$?
    exit $(( overall_rc != 0 ? 1 : report_rc ))
}

# Test seam (tests/test_stage_flow.sh): only define the functions above.
if [[ "${SNAPPI_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

load_config

if [[ "$MODE" == "validate" ]]; then
    log_ok "config.yaml is valid for every stage (deployment: and testbed:)"
    exit 0
fi

check_license_server
check_labserver_licensed

if [[ "$MODE" == "show-config" ]]; then
    print_run_config
    # A legacy flat file is migrated in memory on every run (with a deprecation warning);
    # print the migrated layout so it can be copied into config.yaml.
    if [[ "${CFG_CONFIG_LEGACY:-0}" == "1" ]]; then
        echo
        echo "================ MIGRATED LAYOUT (copy into config.yaml) ================"
        python3 "$LIB_DIR/config_loader.py" "$CONFIG_FILE" --print-migrated 2>/dev/null
        echo "========================================================================="
    fi
    exit 0
fi

if [[ "$MODE" == "list-versions" ]]; then
    phase_list_versions
    exit 0
fi

# Foreground and before anything backgrounds docker calls (run_phase_with_spinner) -
# see docker_bootstrap_sudo in lib/common.sh.
if mode_needs_docker; then
    if env_check_will_run; then
        docker_bootstrap_sudo --soft   # phase 1 installs/starts docker; re-checked after it
    else
        docker_bootstrap_sudo
    fi
fi

LOG_DIR="$LOG_BASE_DIR/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/run.log"

state_file_init "$STATE_FILE"
acquire_lock "$LOCK_FILE"
_on_exit() {
    release_lock
    [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    [[ -n "${DOCKER_SHIM_DIR:-}" ]] && rm -rf "$DOCKER_SHIM_DIR"
}
trap _on_exit EXIT

log_info "run_snappi_test.sh starting - mode=$MODE config=$CONFIG_FILE log_dir=$LOG_DIR"

run_stages
