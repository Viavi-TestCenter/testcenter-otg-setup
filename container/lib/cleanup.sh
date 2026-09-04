#!/usr/bin/env bash
# cleanup.sh — phase 8: post-test cleanup.
#
# phase_cleanup_cache clears pytest's fact/result cache inside the sonic-mgmt
# container. This is unrelated to environment teardown (--destroy, see
# deploy.sh::phase_destroy) - clearing cache never removes any deployed
# service, container, or clab topology. --no-cleanup skips ONLY this phase,
# so cache/test state is preserved for debugging; it has no effect on
# --destroy or cleanup_env_on_failure below.
#
# cleanup_env_on_failure auto-tears-down tool-owned environment resources
# after a FAILED run, controlled by cleanup.env_on_failure in config.yaml
# (default: true). It uses the exact same scope as --destroy (phase_destroy)
# - only resources this tool created are ever removed. A successful run
# never calls this - the environment is always left deployed for reuse.

phase_cleanup_cache() {
    log_step "Clearing pytest/ansible fact cache"
    # Run as root (no --user): these caches can end up root-owned (e.g. a
    # pytest run executed as root inside the container at some point), and
    # this rm must still succeed regardless of who created those files - a
    # permission failure here silently leaves a stale
    # tests/common/cache/FactsCache tbinfo.pickle behind, which poisons
    # every later run's testbed lookup (get_tbinfo() caches by conf-name)
    # even after testbed.yaml is correctly re-patched. pytest's own cache
    # (.pytest_cache) lives at the sonic-mgmt repo root (its rootdir), not
    # under tests/.
    local repo; repo="$(sonic_mgmt_container_path)"
    docker exec -w "$repo" "$SONIC_MGMT_CONTAINER" bash -lc "rm -rf tests/_cache/* .pytest_cache" \
        && log_ok "Cache cleared (tests/_cache, .pytest_cache)" \
        || log_warn "Cache clear failed (non-fatal) - stale results may persist on next run"
}

# ensure_clean_pytest_cache recreates .pytest_cache immediately before a
# pytest invocation and hands it to the mapped non-root user (the one
# sonic_mgmt_exec runs pytest as). It closes the race where a run's own
# cache write (e.g. conditional_mark's pytest_collection() writing
# TESTS_MARK_CONDITIONS) hits a stale/root-owned .pytest_cache left over
# from bind-mount cleanup timing - pytest only warns (PytestCacheWarning)
# on a failed cache write rather than raising, so a write that silently
# no-ops there makes conditional_mark's YAML-driven skip rules
# (tests_mark_conditions.yaml) silently not apply for the whole run: e.g.
# test_disable_rsyslog_rate_limit's "skip on asic_type=='vs'" rule stops
# matching, so it runs and passes instead of being skipped - inflating
# pretest's "N passed" by 1 with no code or environment change. Run as
# root (no --user), same rationale as phase_cleanup_cache above.
ensure_clean_pytest_cache() {
    log_step "Resetting pytest cache before pretest"
    local repo; repo="$(sonic_mgmt_container_path)"
    local user; user="$(sonic_mgmt_user)"
    docker exec -w "$repo" "$SONIC_MGMT_CONTAINER" bash -lc \
        "rm -rf .pytest_cache && mkdir -p .pytest_cache && chown -R '$user' .pytest_cache" \
        && log_ok "pytest cache reset (owner: $user)" \
        || log_warn "pytest cache reset failed (non-fatal) - collection may hit stale cache permissions"
}

cleanup_env_on_failure() {
    if [[ "$MODE" == "deploy-only" ]]; then
        record_phase "Environment cleanup" "SKIPPED" "--deploy-only always keeps the environment"
        return
    fi
    if [[ "$CFG_CLEANUP_ENV_ON_FAILURE" != "1" ]]; then
        record_phase "Environment cleanup" "SKIPPED" "cleanup.env_on_failure=false - environment kept for debugging"
        return
    fi
    log_step "Run failed - tearing down tool-owned environment (cleanup.env_on_failure=true)"
    phase_destroy
    record_phase "Environment cleanup" "OK"
}
