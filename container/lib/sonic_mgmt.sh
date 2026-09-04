#!/usr/bin/env bash
# sonic_mgmt.sh — phase 3: sonic-mgmt source checkout (clone+patch, or reuse
# an existing checkout as-is) and the sonic-mgmt docker container.

SONIC_MGMT_CONTAINER="snappi-sonic-mgmt"

phase_sonic_mgmt_source() {
    log_step "Preparing sonic-mgmt source"

    if [[ "$SONIC_MGMT_USER_PROVIDED" -eq 1 ]]; then
        [[ -d "$SONIC_MGMT_DIR/.git" ]] || die "sonic_mgmt.source_dir does not look like a git checkout: $SONIC_MGMT_DIR"
        log_info "Using existing sonic-mgmt checkout: $SONIC_MGMT_DIR (not cloned by this tool)"

        if [[ -n "$(git -C "$SONIC_MGMT_DIR" status --porcelain 2>/dev/null)" ]]; then
            log_warn "sonic-mgmt checkout has a dirty working tree - leaving it untouched (no checkout, no patch apply)."
            log_warn "If you need the baseline commit or the STC/OTG patch applied, manage it yourself or point sonic_mgmt.source_dir at a clean checkout."
            SONIC_MGMT_PATCH_APPLIED="skipped (dirty tree)"
            return
        fi

        if [[ "$CFG_SONIC_MGMT_PATCH_APPLY" == "1" ]]; then
            _sonic_mgmt_apply_patch_if_needed
        else
            log_info "sonic_mgmt.patch.apply is false - leaving the existing checkout's patch state as-is."
            SONIC_MGMT_PATCH_APPLIED="skipped (apply=false)"
        fi
        return
    fi

    # Not user-provided: this tool owns the checkout. Once this tool has
    # successfully patched it and generated ansible config into it (see
    # gen_config.sh), the working tree is PERMANENTLY dirty by design on
    # every subsequent run - that is expected, not a problem, as long as
    # we're sitting on the commit we expect. Only refuse when the checkout
    # is both on the wrong commit AND dirty, since switching commits could
    # then clobber or conflict with real uncommitted changes.
    if [[ -d "$SONIC_MGMT_DIR/.git" ]]; then
        log_info "Reusing previously cloned sonic-mgmt at $SONIC_MGMT_DIR"
        local head; head="$(git -C "$SONIC_MGMT_DIR" rev-parse HEAD)"
        if [[ "$head" == "${CFG_SONIC_MGMT_BASELINE_COMMIT}"* ]]; then
            log_ok "Already on baseline commit ($CFG_SONIC_MGMT_BASELINE_COMMIT) - leaving working tree as-is (patch/config-gen changes are expected here)"
        else
            if [[ -n "$(git -C "$SONIC_MGMT_DIR" status --porcelain 2>/dev/null)" ]]; then
                die "Tool-owned sonic-mgmt checkout at $SONIC_MGMT_DIR is on commit ${head:0:12} (expected baseline $CFG_SONIC_MGMT_BASELINE_COMMIT) and has uncommitted changes - refusing to switch commits and risk losing them. Investigate/reset it manually, or remove the directory to let this tool re-clone."
            fi

            # The baseline commit is normally already present locally (it was
            # reachable from the branch tip at clone time), so checkout needs
            # no network round-trip - only fetch, and only the configured
            # branch (not an arbitrary commit, which not all git servers will
            # serve), when the commit truly isn't there yet (e.g. the baseline
            # was bumped in config.yaml to a commit landed after our clone).
            if ! git -C "$SONIC_MGMT_DIR" cat-file -e "${CFG_SONIC_MGMT_BASELINE_COMMIT}^{commit}" 2>/dev/null; then
                log_info "Baseline commit $CFG_SONIC_MGMT_BASELINE_COMMIT not found in local history - fetching $CFG_SONIC_MGMT_BRANCH from origin"
                git -C "$SONIC_MGMT_DIR" fetch origin "$CFG_SONIC_MGMT_BRANCH"
            fi
            git -C "$SONIC_MGMT_DIR" checkout --quiet --detach "$CFG_SONIC_MGMT_BASELINE_COMMIT"
        fi
    else
        log_info "Cloning $CFG_SONIC_MGMT_REPO ($CFG_SONIC_MGMT_BRANCH) -> $SONIC_MGMT_DIR"
        mkdir -p "$(dirname "$SONIC_MGMT_DIR")"
        git clone -b "$CFG_SONIC_MGMT_BRANCH" --single-branch "$CFG_SONIC_MGMT_REPO" "$SONIC_MGMT_DIR"
        state_set "$STATE_FILE" OWN_SONIC_MGMT_CLONE 1
        git -C "$SONIC_MGMT_DIR" checkout "$CFG_SONIC_MGMT_BASELINE_COMMIT"
    fi

    if [[ "$CFG_SONIC_MGMT_PATCH_APPLY" == "1" ]]; then
        _sonic_mgmt_apply_patch_if_needed
    else
        log_info "sonic_mgmt.patch.apply is false - skipping the STC/OTG compatibility patch."
        SONIC_MGMT_PATCH_APPLIED="skipped (apply=false)"
    fi
}

_sonic_mgmt_apply_patch_if_needed() {
    [[ -f "$PATCH_FILE" ]] || die "Patch file not found: $PATCH_FILE (sonic_mgmt.patch.file in config.yaml)"

    if git -C "$SONIC_MGMT_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
        log_ok "STC/OTG patch already applied to this checkout - skipping."
        SONIC_MGMT_PATCH_APPLIED="already applied"
        return
    fi

    if ! git -C "$SONIC_MGMT_DIR" apply --check "$PATCH_FILE" 2>/tmp/.patch_check.$$; then
        local out; out="$(cat /tmp/.patch_check.$$)"; rm -f /tmp/.patch_check.$$
        die "Patch does not apply cleanly to $SONIC_MGMT_DIR (expected baseline $CFG_SONIC_MGMT_BASELINE_COMMIT). git apply --check said:
$out"
    fi
    rm -f /tmp/.patch_check.$$

    git -C "$SONIC_MGMT_DIR" apply "$PATCH_FILE"
    log_ok "Applied snappi-stc-patch: $(basename "$PATCH_FILE")"
    SONIC_MGMT_PATCH_APPLIED="applied"
}

phase_sonic_mgmt_container() {
    log_step "Deploying sonic-mgmt docker container"

    local image="sonicdev-microsoft.azurecr.io:443/docker-sonic-mgmt:latest"

    if docker ps --format '{{.Names}}' | grep -qx "$SONIC_MGMT_CONTAINER"; then
        if docker exec "$SONIC_MGMT_CONTAINER" test -d "$(sonic_mgmt_container_path)" 2>/dev/null; then
            local running_image; running_image="$(docker inspect --format '{{.Config.Image}}' "$SONIC_MGMT_CONTAINER" 2>/dev/null)"
            log_ok "Container '$SONIC_MGMT_CONTAINER' (image: ${running_image:-unknown}) is already running - reusing it, no need to deploy again."
            if [[ -n "$running_image" && "$running_image" != "$image" ]]; then
                log_warn "Running container's image ($running_image) differs from the configured one ($image) - leaving it as-is; recreate it manually (docker rm -f $SONIC_MGMT_CONTAINER) if you want the configured image instead."
            fi
            return
        fi
        log_warn "sonic-mgmt container '$SONIC_MGMT_CONTAINER' is running but $(sonic_mgmt_container_path) isn't mounted inside it - recreating it"
        docker rm -f "$SONIC_MGMT_CONTAINER" >/dev/null
    elif docker ps -a --format '{{.Names}}' | grep -qx "$SONIC_MGMT_CONTAINER"; then
        # setup-container.sh treats "container name already exists" (any
        # state) as success without starting it - so a stopped container
        # would otherwise be silently left stopped forever.
        log_info "sonic-mgmt container exists but is stopped - starting it"
        docker start "$SONIC_MGMT_CONTAINER" >/dev/null
        sleep 2
        if docker exec "$SONIC_MGMT_CONTAINER" test -d "$(sonic_mgmt_container_path)" 2>/dev/null; then
            log_ok "Reusing restarted sonic-mgmt container: $SONIC_MGMT_CONTAINER"
            return
        fi
        log_warn "Restarted sonic-mgmt container is missing $(sonic_mgmt_container_path) - recreating it"
        docker rm -f "$SONIC_MGMT_CONTAINER" >/dev/null
    fi

    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "$image"; then
        local local_tar
        local_tar=$(find "$IMAGES_DIR" -maxdepth 1 -iname 'docker-sonic-mgmt*.tar.gz' -print -quit 2>/dev/null)
        if [[ -n "$local_tar" ]]; then
            log_info "Loading sonic-mgmt image from $local_tar"
            docker load -i "$local_tar"
        else
            log_info "sonic-mgmt image not local - pulling $image"
            docker pull "$image"
        fi
    fi

    if [[ ! -x "$SONIC_MGMT_DIR/setup-container.sh" ]]; then
        die "setup-container.sh not found/executable in $SONIC_MGMT_DIR"
    fi

    if grep -qi microsoft /proc/version 2>/dev/null; then
        log_info "WSL detected - running 'mount --make-rshared /' once before setup-container.sh"
        $SUDO mount --make-rshared / || true
    fi

    # setup-container.sh's -d is the MOUNT POINT INSIDE THE CONTAINER, not a
    # host path (default "/var/src") - it bind-mounts the PARENT of wherever
    # setup-container.sh itself lives (i.e. dirname "$SONIC_MGMT_DIR") to that
    # container path, so the repo ends up visible at "/data/$(basename
    # "$SONIC_MGMT_DIR")" - exactly what sonic_mgmt_container_path() assumes.
    # Passing a host path here (as an earlier version of this script did)
    # produces a container-side directory named after that host path instead
    # of the intended /data, silently leaving /data unmounted.
    ( cd "$SONIC_MGMT_DIR" && ./setup-container.sh -n "$SONIC_MGMT_CONTAINER" -i "$image" -d /data )
    state_set "$STATE_FILE" OWN_SONIC_MGMT_CONTAINER 1
    log_ok "sonic-mgmt container deployed: $SONIC_MGMT_CONTAINER"
}

# Path of the bind-mounted checkout as seen INSIDE the sonic-mgmt container
# (setup-container.sh mounts it at /data/<repo-dir-basename>).
sonic_mgmt_container_path() { printf '/data/%s' "$(basename "$SONIC_MGMT_DIR")"; }

sonic_mgmt_user() {
    docker exec "$SONIC_MGMT_CONTAINER" bash -c "id -nu $(id -u)" 2>/dev/null
}

# sonic_mgmt_exec <subdir-under-repo-root> <command...>
sonic_mgmt_exec() {
    local subdir="$1"; shift
    docker exec --user "$(sonic_mgmt_user)" -w "$(sonic_mgmt_container_path)/$subdir" "$SONIC_MGMT_CONTAINER" bash -lc "$*"
}
