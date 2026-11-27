#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2312  # subshells are deliberate: they isolate sourcing run_snappi_test.sh; variables are consumed by the sourced code or other lib files; pipelines in tests are best-effort
# test_physical_confirm.sh - a minigraph push REPLACES a physical DUT's running configuration, so a run
# that would do it needs --yes. Without it the run stops before anything touches the DUT (before the
# access check, which also writes the SSH key to a physical DUT, and before a full run deploys).
# There is no prompt: the answer is the flag, so CI and scripts behave the same everywhere.
#
#   bash container/tests/test_physical_confirm.sh
#
# The staged run is exercised with every phase stubbed and the real guard; the option parsing and
# the validation order are exercised on the real script. Nothing is deployed or touched.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../run_snappi_test.sh"
fails=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/sonic-mgmt/.git"

check() {
    if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: $3"; echo "       got : $2"; fails=$((fails + 1)); fi
}
contains() {
    if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       missing: $3"; echo "       in     : $2"; fails=$((fails + 1)); fi
}
lacks() {
    if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       unexpected: $3"; echo "       in        : $2"; fails=$((fails + 1)); fi
}

PHYS=("CFG_TARGET=physical" "CFG_TC_MODE=physical" "CFG_DUT_MODE=physical")
AUTO=("CFG_DEPLOY_MINIGRAPH=auto" "CFG_DEPLOY_MINIGRAPH_EFFECTIVE=0")       # physical: auto never pushes
TRUE=("CFG_DEPLOY_MINIGRAPH=true" "CFG_DEPLOY_MINIGRAPH_EFFECTIVE=1")

# run_stage <mode> [assignment ...] -> phase calls (one per line, "CALL name"), messages, then "rc=<n>".
# Baseline: a virtual lab, no --yes. Assignments override CFG_* and the switches:
#   ASSUME_YES=1    --yes was given
#   ARGS='...'      the command line shown in the "re-run with" hint (ORIG_ARGS)
#   MG_VALID=1      a minigraph push is already recorded for the current settings
#   ACCESS_RC=1     the access check fails
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
        CFG_TC_VERSION=5.62.0766; CFG_DUT_HOSTNAME=dut1
        CFG_LABSERVER_MODE=docker-compose; CFG_OTG_MODE=docker-compose
        CFG_LABSERVER_IP=10.0.0.5; CFG_OTG_SERVICE_IP=10.0.0.5
        CFG_DEPLOY_MINIGRAPH=auto; CFG_DEPLOY_MINIGRAPH_EFFECTIVE=1
        CFG_CLEANUP_ENV_ON_FAILURE=0
        STATE_FILE="${TMP}/state.env"; SONIC_MGMT_DIR="${TMP}/sonic-mgmt"
        NO_CLEANUP=0; SKIP_ENV_CHECK=1
        RESULT_DEPLOY_MG=PASSED; RESULT_PRETEST=PASSED; RESULT_SMOKE=PASSED; SUMMARY_PRETEST=""; SUMMARY_SMOKE=""
        ASSUME_YES=0; ARGS=""; MG_VALID=0; ACCESS_RC=0
        for assignment in "${overrides[@]}"; do eval "${assignment}"; done
        # shellcheck disable=SC2206
        ORIG_ARGS=(${ARGS})
        rm -f "${STATE_FILE}"; touch "${STATE_FILE}"
        record_deployed_identity; state_set "${STATE_FILE}" DEPLOY_MG_DONE 0   # a deployed environment

        for f in phase_check_version_change phase_env_check phase_check_artifacts phase_sonic_mgmt_source \
                 phase_sonic_mgmt_container phase_deploy_services phase_gen_config phase_deploy_mg \
                 phase_pretest phase_smoke_test phase_cleanup_cache phase_destroy phase_report \
                 cleanup_env_on_failure require_deployed_environment print_run_config warn_labserver_unlicensed \
                 check_deployed_identity; do
            eval "${f}() { echo \"CALL ${f}\"; return 0; }"
        done
        phase_access_check() { echo "CALL phase_access_check"; return "${ACCESS_RC}"; }
        deploy_mg_done_valid() { [[ "${MG_VALID}" == "1" ]]; }
        record_phase() { :; }
        log_info() { :; }
        if [[ "${TRACE_GUARD:-0}" == "1" ]]; then   # show where the guard is called from
            eval "$(declare -f require_physical_dut_confirmation | sed '1s/.*/_real_guard ()/')"
            require_physical_dut_confirmation() { echo "CALL guard"; _real_guard; }
        fi
        run_stages
    ) 2>&1
    echo "rc=$?"
}
calls() { grep '^CALL ' <<<"$1" | sed 's/^CALL phase_//; s/^CALL //' | tr '\n' ' ' | sed 's/ $//'; }

HINT_DEPLOY_MG='  ./run_snappi_test.sh --deploy-mg --yes'

# --- explicit --deploy-mg ---------------------------------------------------------------------------
out="$(run_stage deploy-mg "${PHYS[@]}" "${AUTO[@]}" ARGS='--deploy-mg')"
contains "physical + --deploy-mg, no --yes: blocked (exit 1)" "${out}" "rc=1"
contains "physical + --deploy-mg, no --yes: names the DUT and the consequence" "${out}" 'Minigraph deployment will replace the running configuration of physical DUT "dut1".'
contains "physical + --deploy-mg, no --yes: shows the exact command to re-run" "${out}" "Re-run with --yes to confirm:"
contains "physical + --deploy-mg, no --yes: the command includes the original options" "${out}" "${HINT_DEPLOY_MG}"
check "physical + --deploy-mg, no --yes: nothing ran - not the access check (writes the SSH key), not the push" "$(calls "${out}")" "print_run_config require_deployed_environment"

out="$(run_stage deploy-mg "${PHYS[@]}" "${AUTO[@]}" ASSUME_YES=1)"
check "physical + --deploy-mg --yes: access check, gen-config, push" "$(calls "${out}")" "print_run_config require_deployed_environment access_check gen_config deploy_mg report"
contains "physical + --deploy-mg --yes: exit 0" "${out}" "rc=0"

out="$(run_stage deploy-mg "${PHYS[@]}" "${TRUE[@]}" "ARGS='-c lab.yaml --deploy-mg'")"
contains "the hint keeps every original option (-c lab.yaml)" "${out}" "./run_snappi_test.sh -c lab.yaml --deploy-mg --yes"

# --- deploy_minigraph: auto never pushes to a physical DUT -------------------------------------------
for m in pretest smoke-test test-only full; do
    out="$(run_stage "${m}" "${PHYS[@]}" "${AUTO[@]}")"
    lacks "physical + auto, ${m}: no push" "${out}" "CALL phase_deploy_mg"
    contains "physical + auto, ${m}: runs without --yes" "${out}" "rc=0"
    lacks "physical + auto, ${m}: no confirmation requested" "${out}" "--yes"
done

# --- deploy_minigraph: true on a physical DUT, through a test command --------------------------------
for m in pretest smoke-test test-only; do
    out="$(run_stage "${m}" "${PHYS[@]}" "${TRUE[@]}" ARGS="--${m}")"
    contains "physical + true, ${m}, no --yes: blocked" "${out}" "rc=1"
    contains "physical + true, ${m}, no --yes: hint names this command" "${out}" "  ./run_snappi_test.sh --${m} --yes"
    check "physical + true, ${m}, no --yes: no access check, no push, no test" "$(calls "${out}")" "print_run_config require_deployed_environment check_deployed_identity"

    out="$(run_stage "${m}" "${PHYS[@]}" "${TRUE[@]}" ASSUME_YES=1)"
    contains "physical + true, ${m}, --yes: pushes" "${out}" "CALL phase_deploy_mg"
    contains "physical + true, ${m}, --yes: exit 0" "${out}" "rc=0"
done
# a full run is stopped before it deploys anything
out="$(run_stage full "${PHYS[@]}" "${TRUE[@]}")"
contains "physical + true, full run, no --yes: blocked" "${out}" "rc=1"
contains "physical + true, full run, no --yes: hint is the bare command" "${out}" "  ./run_snappi_test.sh --yes"
check "physical + true, full run, no --yes: stopped before the deploy stage" "$(calls "${out}")" "print_run_config"
out="$(run_stage full "${PHYS[@]}" "${TRUE[@]}" ASSUME_YES=1)"
contains "physical + true, full run, --yes: deploys, pushes, tests" "${out}" "CALL phase_deploy_mg"
contains "physical + true, full run, --yes: exit 0" "${out}" "rc=0"

# --pretest/--smoke-test do not push again when a push is recorded for the current settings:
# nothing replaces the configuration, so there is nothing to confirm
out="$(run_stage pretest "${PHYS[@]}" "${TRUE[@]}" MG_VALID=1)"
lacks "physical + true, pretest, push already recorded: no push, so no --yes needed" "${out}" "CALL phase_deploy_mg"
contains "physical + true, pretest, push already recorded: exit 0" "${out}" "rc=0"

# where the guard sits: before the access check (nothing on the DUT may change), and again immediately
# before the push
out="$(run_stage pretest "${PHYS[@]}" "${TRUE[@]}" ASSUME_YES=1 TRACE_GUARD=1)"
check "guard sits before the access check and immediately before the push" "$(calls "${out}")" \
    "print_run_config require_deployed_environment check_deployed_identity guard access_check gen_config guard deploy_mg pretest cleanup_cache report"
out="$(run_stage full "${PHYS[@]}" "${TRUE[@]}" ASSUME_YES=1 TRACE_GUARD=1)"
check "full run: asked before the deploy stage, again right before the push" "$(calls "${out}")" \
    "print_run_config guard check_version_change check_artifacts sonic_mgmt_source sonic_mgmt_container deploy_services check_deployed_identity guard access_check gen_config guard deploy_mg pretest smoke_test cleanup_cache report"

# --- virtual DUT: unchanged --------------------------------------------------------------------------------
out="$(run_stage deploy-mg)"
contains "virtual + --deploy-mg, no --yes: pushes" "${out}" "CALL phase_deploy_mg"
contains "virtual + --deploy-mg, no --yes: exit 0" "${out}" "rc=0"
for m in pretest smoke-test test-only full; do
    out="$(run_stage "${m}")"
    contains "virtual, ${m}, no --yes: pushes (always on a virtual lab under auto)" "${out}" "CALL phase_deploy_mg"
    lacks "virtual, ${m}, no --yes: never asks for --yes" "${out}" "--yes"
done

# --- modes that never push to the DUT need no confirmation, even on a physical DUT --------------------------
for m in access-check gen-config deploy-only destroy; do
    out="$(run_stage "${m}" "${PHYS[@]}" "${TRUE[@]}")"
    contains "physical + true, ${m}, no --yes: not asked" "${out}" "rc=0"
    lacks "physical + true, ${m}, no --yes: not asked (no hint)" "${out}" "--yes"
done

# --- --yes confirms the replacement only: other checks still apply -----------------------------------------------
out="$(run_stage deploy-mg "${PHYS[@]}" "${AUTO[@]}" ASSUME_YES=1 ACCESS_RC=1)"
contains "--yes does not bypass a failing access check: exit 1" "${out}" "rc=1"
lacks "--yes does not bypass a failing access check: no push" "${out}" "CALL phase_deploy_mg"

# On the real script: --yes is accepted, documented, and validation still comes first.
BIN="${TMP}/bin"; mkdir -p "${BIN}"
for tool in docker sudo; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/tool-calls"\nexit 1\n' "${tool}" "${TMP}" > "${BIN}/${tool}"
    chmod +x "${BIN}/${tool}"
done
parsed() {   # what the real option parser makes of a command line
    # shellcheck disable=SC1090
    ( export SNAPPI_SOURCE_ONLY=1; source "${SCRIPT}" "$@"; echo "MODE=${MODE} ASSUME_YES=${ASSUME_YES} ARGS=${ORIG_ARGS[*]}" )
}
check "--yes sets the confirmation" "$(parsed --deploy-mg --yes)" "MODE=deploy-mg ASSUME_YES=1 ARGS=--deploy-mg --yes"
check "without --yes the confirmation is off" "$(parsed --deploy-mg)" "MODE=deploy-mg ASSUME_YES=0 ARGS=--deploy-mg"
check "--yes works before the mode too" "$(parsed --yes --pretest)" "MODE=pretest ASSUME_YES=1 ARGS=--yes --pretest"
help="$(bash "${SCRIPT}" --help)"
contains "--help documents --yes" "${help}" "--yes"
contains "--help states that --yes confirms replacing the physical DUT's running configuration" "${help}" "replacement of the running configuration of a physical DUT"
out="$(cd "${TMP}" && cp "${HERE}/../config.yaml" cfg-ok.yaml && PATH="${BIN}:${PATH}" bash "${SCRIPT}" -c "${TMP}/cfg-ok.yaml" --validate --yes 2>&1)"; rc=$?
check "--yes is accepted (valid config, --validate --yes)" "${rc}" "0"

bad_run() {   # bad_run <label> <python on cfg> <expected text> <option...>
    local label="$1" stmt="$2" want="$3"; shift 3
    local d="${TMP}/bad.${RANDOM}"; mkdir -p "${d}"
    python3 - "${HERE}/../config.yaml" "${d}/config.yaml" "${stmt}" <<'PY'
import sys, yaml
src, dst, stmt = sys.argv[1:4]
cfg = yaml.safe_load(open(src))
exec(stmt)
yaml.safe_dump(cfg, open(dst, "w"))
PY
    rm -f "${TMP}/tool-calls"
    local o rc
    o="$(cd "${d}" && PATH="${BIN}:${PATH}" bash "${SCRIPT}" -c "${d}/config.yaml" "$@" 2>&1)"; rc=$?
    check "${label}: still rejected (exit 1)" "${rc}" "1"
    contains "${label}: by the normal validation" "${o}" "${want}"
    lacks "${label}: not a confirmation message" "${o}" "Re-run with --yes"
    check "${label}: docker never called, nothing created" "$(cat "${TMP}/tool-calls" 2>/dev/null || true)$(ls -A "${d}")" "config.yaml"
}
bad_run "--deploy-mg --yes, physical, one link" \
    'cfg["deployment"]["target"]="physical"; cfg["testbed"]["dut"]["links"]=cfg["testbed"]["dut"]["links"][:1]' \
    "At least two testbed.dut.links entries" --deploy-mg --yes
bad_run "--pretest --yes, bad topology name" \
    'cfg["testbed"]["topology"]["name"]="ptf32"' 'must start with "tgen"' --pretest --yes
bad_run "--yes with a compose/provisioned conflict" \
    'cfg["deployment"]["otg_labserver"]["labserver"]["mode"]="provisioned"' "docker_compose.enabled is true" --test-only --yes

echo
if [[ ${fails} -eq 0 ]]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
