#!/usr/bin/env bash
# deploy.sh — phase 5: deploy or reuse the labserver, OTG service, and
# containerlab (STC[+DUT]) topology; also implements --destroy, which only
# ever removes resources this tool itself created (tracked in $STATE_FILE).

# ------------------------------------------------------- version change ----
# Detects a tool-owned STC chassis container left over from a previous run
# that was deployed on a different testcenter.version than config.yaml now
# names. containerlab itself doesn't need this - _deploy_containerlab below
# always destroys+redeploys the STC node every run regardless of version -
# but the labserver/OTG service/sonic-mgmt container are all reused as-is
# whenever already healthy (see _deploy_labserver), so left alone, a version
# bump here would silently leave those other pieces on the old release.
# Governed by cleanup.replace_on_version_change (default true: replace the
# whole tool-owned environment, same scope as --destroy).
phase_check_version_change() {
    state_owns "$STATE_FILE" OWN_CLAB || return 0

    local cname
    cname="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -- '-snappi-sonic-stc$' | head -1)"
    [[ -n "$cname" ]] || return 0

    local running_image running_version
    running_image="$(docker inspect --format '{{.Config.Image}}' "$cname" 2>/dev/null)"
    running_version="${running_image#stc:}"
    [[ -n "$running_version" && "$running_version" != "$running_image" ]] || return 0
    [[ "$running_version" == "$CFG_TC_VERSION" ]] && return 0

    log_info ""
    log_info "Detected existing deployment:"
    log_info "Version: ${running_version}"
    log_info ""

    if [[ "$CFG_REPLACE_ENV_ON_VERSION_CHANGE" == "1" ]]; then
        log_info "Existing environment will be destroyed and replaced by ${CFG_TC_VERSION}."
        phase_destroy
        record_phase "Version change" "REPLACED" "${running_version} -> ${CFG_TC_VERSION}"
    else
        log_warn "cleanup.replace_on_version_change is false - keeping the existing ${running_version} environment as-is; per-resource reuse checks below decide what (if anything) gets recreated on ${CFG_TC_VERSION}. Components may end up on mixed versions."
        record_phase "Version change" "KEPT" "${running_version} != ${CFG_TC_VERSION}"
    fi
}

phase_deploy_services() {
    log_step "Deploying/verifying lab services"
    local log="$LOG_DIR/deploy_services.log"
    if run_phase_with_spinner "Lab services deployment" "$log" _phase_deploy_services_impl; then
        log_ok "Lab services ready"
    else
        return 1
    fi
}

# Runs under run_phase_with_spinner (backgrounded, output captured to a log
# file) - $ALLURE_URL is set here but must still be visible to the final
# report, so it's relayed back via phase_export.
_phase_deploy_services_impl() {
    if [[ "$CFG_DEPLOY_MODE" == "docker-compose" ]]; then
        _deploy_docker_compose_stack
    else
        _deploy_labserver
        _deploy_otg_service
    fi
    _deploy_containerlab
    _install_dut_ssh_key
    _deploy_allure
    [[ -n "${ALLURE_URL:-}" ]] && phase_export ALLURE_URL "$ALLURE_URL"
}

# ---------------------------------------------------------------- labserver -
_deploy_labserver() {
    if [[ "$CFG_DEPLOY_MODE" == "provisioned" ]]; then
        log_info "Labserver mode=provisioned - verifying reachability at ${CFG_LABSERVER_IP}"
        local code; code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions")
        [[ "$code" == "000" ]] && die "Provisioned labserver at ${CFG_LABSERVER_IP} is not reachable (HTTP $code). This tool will not deploy one in provisioned mode - fix reachability or switch deployment.mode to standalone."
        log_ok "Provisioned labserver reachable (HTTP $code)"
        return
    fi

    if docker ps --format '{{.Names}}' | grep -qx labserver; then
        local code; code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions")
        if [[ "$code" != "000" ]]; then
            _warn_if_labserver_version_mismatch
            log_ok "Reusing already-running labserver container (HTTP $code)"
            return
        fi
        log_warn "labserver container is running but not responding (HTTP $code) - recreating it"
        docker rm -f labserver >/dev/null
    elif docker ps -a --format '{{.Names}}' | grep -qx labserver; then
        log_info "labserver container exists but is stopped - starting it"
        docker start labserver >/dev/null
        sleep 3
        local code; code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions")
        if [[ "$code" != "000" ]]; then
            _warn_if_labserver_version_mismatch
            log_ok "Reusing restarted labserver container (HTTP $code)"
            return
        fi
        log_warn "labserver container did not come up healthy after start - recreating it"
        docker rm -f labserver >/dev/null
    fi

    local image_name
    image_name="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i "labserver.*${CFG_TC_LABSERVER_VERSION}" | head -1)"

    if [[ -n "$image_name" ]]; then
        log_info "Deploying labserver from existing docker image $image_name"
    else
        [[ -n "$LABSERVER_IMAGE_FILE" ]] \
            || die "labserver must be (re)created but no labserver artifact file was resolved. Re-run phase_check_artifacts, or place labserver-${CFG_TC_LABSERVER_VERSION}.tar.xz under $IMAGES_DIR."

        log_info "Deploying standalone labserver from $LABSERVER_IMAGE_FILE"
        image_name=$(xz -dc "$LABSERVER_IMAGE_FILE" | docker load | awk '{print $NF}' | tail -1)
        [[ -n "$image_name" ]] || die "docker load of $LABSERVER_IMAGE_FILE did not report an image name"
    fi

    docker run --name labserver -v /data:/data --detach=true --restart=always \
        --net=host --log-opt max-size=10m --log-opt max-file=5 --shm-size=250m \
        "$image_name" >/dev/null

    log_info "Configuring license (${CFG_TC_LICENSE_SERVER}) and waiting for supervisor..."
    docker exec labserver sed -i \
        "s|environment=HOME=\"/home/testcenter\",CURLOPT_CAINFO=\"/etc/ssl/certs/ca-certificates.crt\"|environment=HOME=\"/home/testcenter\",CURLOPT_CAINFO=\"/etc/ssl/certs/ca-certificates.crt\",SPIRENTD_LICENSE_FILE=\"${CFG_TC_LICENSE_SERVER}\"|" \
        /etc/supervisor/conf.d/labserver.conf
    docker exec labserver grep -q SPIRENTD_LICENSE_FILE /etc/supervisor/conf.d/labserver.conf \
        || die "Failed to write license config into labserver.conf"

    local i=0
    until docker exec labserver supervisorctl status >/dev/null 2>&1; do
        i=$((i+1)); (( i > 30 )) && die "labserver supervisor did not become ready in time"
        sleep 2
    done
    docker exec labserver supervisorctl restart testcenter-server >/dev/null

    _fix_labserver_stcweb_port_conflict

    state_set "$STATE_FILE" OWN_LABSERVER 1
    log_ok "labserver deployed"
}

# A reused labserver container was created from whatever image was current
# on some earlier run - it's never version-checked against config.yaml on
# reuse (unlike the containerlab STC node, which is always torn down and
# rebuilt on every run). Warn loudly on a mismatch so a stale labserver
# doesn't go unnoticed, but keep reusing it rather than force-recreating a
# container that may have live sessions/state on it.
_warn_if_labserver_version_mismatch() {
    local running_image
    running_image="$(docker inspect --format '{{.Config.Image}}' labserver 2>/dev/null)"
    if [[ -n "$running_image" && "$running_image" != *"${CFG_TC_LABSERVER_VERSION}"* ]]; then
        log_warn "Running labserver container was created from image '$running_image', which does not match testcenter.version=${CFG_TC_VERSION} (labserver's version is derived from this) - continuing with the already-running labserver as-is. Run '--destroy' (or 'docker rm -f labserver') first to redeploy on the configured version."
    fi
}

_fix_labserver_stcweb_port_conflict() {
    local yaml="/home/testcenter/server/stcweb.yaml"
    local nginx_conf="/etc/nginx/sites-enabled/stcapi_stcweb.conf"
    local current
    current=$(docker exec labserver grep -oP 'addr: 127\.0\.0\.1:\K[0-9]+' "$yaml" 2>/dev/null || echo 8888)
    if ss -tlnp 2>/dev/null | grep -q ":${current} "; then
        local new_port=$((current + 10000))
        log_warn "Host port ${current} occupied - moving stcweb to ${new_port}"
        docker exec labserver sed -i "s|addr: 127\.0\.0\.1:${current}|addr: 127.0.0.1:${new_port}|" "$yaml"
        docker exec labserver sed -i "s|proxy_pass http://127\.0\.0\.1:${current}|proxy_pass http://127.0.0.1:${new_port}|" "$nginx_conf"
        docker exec labserver nginx -s reload
        docker exec labserver supervisorctl restart stcweb
    fi
}

# --------------------------------------------------------------- OTG service -
_deploy_otg_service() {
    if [[ "$CFG_DEPLOY_MODE" == "provisioned" ]]; then
        log_info "OTG service mode=provisioned - verifying reachability at ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT}"
        wait_for_tcp "$CFG_OTG_SERVICE_IP" "$CFG_OTG_SERVICE_PORT" 10 \
            || die "Provisioned OTG service at ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} is not reachable. This tool will not deploy one in provisioned mode."
        log_ok "Provisioned OTG service reachable"
        return
    fi

    if wait_for_tcp "$CFG_OTG_SERVICE_IP" "$CFG_OTG_SERVICE_PORT" 5; then
        log_ok "Reusing already-running OTG service on ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT}"
        return
    fi

    [[ -n "${OTGSERVICE_FILE:-}" ]] || die "otgservice installer not resolved - run phase_check_artifacts first"
    [[ -f "$OTGSERVICE_FILE" ]] || die "otgservice installer $OTGSERVICE_FILE does not exist"

    log_info "Deploying standalone OTG service from $OTGSERVICE_FILE"
    # Wipe any previous extraction under OTGSERVICE_DIR first - this directory
    # is reused across runs, and a stale/partial directory left over from an
    # earlier attempt can collide with (or shadow) a fresh extraction below.
    rm -rf "$OTGSERVICE_DIR"
    mkdir -p "$OTGSERVICE_DIR"
    cp "$OTGSERVICE_FILE" "$OTGSERVICE_DIR/"

    local installer="$OTGSERVICE_DIR/$(basename "$OTGSERVICE_FILE")"
    chmod +x "$installer"
    ( cd "$OTGSERVICE_DIR" && "./$(basename "$OTGSERVICE_FILE")" )

    local extracted_dir
    extracted_dir="$(find "$OTGSERVICE_DIR" -mindepth 1 -maxdepth 1 -type d -iname 'otgservice*' -print -quit)"
    [[ -n "$extracted_dir" ]] || die "otgservice installer did not produce an otgservice.* directory under $OTGSERVICE_DIR"
    [[ -x "$extracted_dir/otgctl" ]] || die "otgservice installer extracted to $extracted_dir but $extracted_dir/otgctl is missing or not executable"

    ( cd "$extracted_dir" && ./otgctl --start )
    ( cd "$extracted_dir" && ./otgctl --restserver "${CFG_LABSERVER_IP}:80" )

    wait_for_tcp "$CFG_OTG_SERVICE_IP" "$CFG_OTG_SERVICE_PORT" 60 \
        || die "OTG service did not become reachable on ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} after start"

    state_set "$STATE_FILE" OWN_OTG 1
    state_set "$STATE_FILE" OTG_INSTALL_DIR "$extracted_dir"
    log_ok "OTG service deployed"
}

# --------------------------------------------------------- docker-compose --
# deployment.mode=docker-compose deploys the labserver AND OTG service
# together via VIAVI's testcenter-otg-setup docker-compose stack (guide §3.5,
# "Docker Compose" flow), sourced from $OTG_SOURCE_DIR - the testcenter-otg-setup
# checkout this container solution itself ships inside - instead of the
# standalone docker-run+otgctl path above. Uses a fixed compose project name
# ($COMPOSE_PROJECT) so reuse and teardown are scoped by Docker's own
# "com.docker.compose.project" label, never by the (fairly generic)
# "labserver"/"otg" container names alone.
_deploy_docker_compose_stack() {
    _preflight_check_compose_conflicts

    if _docker_compose_stack_healthy; then
        log_ok "Reusing already-running docker-compose labserver+OTG stack (project=$COMPOSE_PROJECT)"
        return
    fi

    _ensure_otg_source_dir "$OTG_SOURCE_DIR"

    log_info "Preparing docker-compose stack from $OTG_SOURCE_DIR"
    rm -rf "$COMPOSE_DIR"
    mkdir -p "$COMPOSE_DIR"
    # Copy only the files the compose build needs (not the whole OTG source
    # tree) - $OTG_SOURCE_DIR is the live checkout this container solution
    # itself ships inside (it contains this "container/" directory, so a
    # wholesale copy would recurse into COMPOSE_DIR's own ancestry).
    local f
    for f in otg-compose.yaml Dockerfile entrypoint.sh; do
        cp "$OTG_SOURCE_DIR/$f" "$COMPOSE_DIR/"
    done

    [[ -n "${OTGSERVICE_FILE:-}" ]] || die "otgservice installer not resolved - run phase_check_artifacts first"
    cp "$OTGSERVICE_FILE" "$COMPOSE_DIR/"

    _ensure_labserver_image_for_compose

    # .env keys match VIAVI's testcenter-otg-setup convention exactly (guide §3.5
    # step 3) - LICENSE_SERVER/LABSERVER/otg_build are read by otg-compose.yaml.
    cat > "$COMPOSE_DIR/.env" <<EOF
LICENSE_SERVER=${CFG_TC_LICENSE_SERVER}
LABSERVER=${CFG_LABSERVER_IP}
otg_build=$(basename "$OTGSERVICE_FILE")
EOF

    # A small override file (rather than editing the vendored otg-compose.yaml
    # in place) pins the labserver image to an exact version tag - keeps this
    # integration resilient to unrelated formatting/content changes upstream.
    cat > "$COMPOSE_DIR/snappi-labserver-image.override.yaml" <<EOF
services:
  labserver:
    image: registry.oriontest.net/labserver:${CFG_TC_LABSERVER_VERSION}
EOF

    local compose; compose="$(compose_cmd)"
    local compose_up_log="$WORK_DIR/docker-compose-up.log"
    # Ownership is recorded BEFORE calling "up", not after it returns -
    # "up" can create/start some containers (e.g. labserver) and still exit
    # non-zero because a later one (e.g. otg) failed to bind a port; those
    # already-created containers are unambiguously tool-owned regardless of
    # the overall exit status, so --destroy must be able to find and remove
    # them even when this run dies on the very next line. Harmless no-op if
    # "up" fails before creating anything at all.
    state_set "$STATE_FILE" OWN_COMPOSE 1

    log_info "Starting labserver+OTG via docker compose ($COMPOSE_DIR, project=$COMPOSE_PROJECT)"
    if ! ( cd "$COMPOSE_DIR" && $compose -p "$COMPOSE_PROJECT" -f otg-compose.yaml -f snappi-labserver-image.override.yaml up -d --build 2>&1 | tee "$compose_up_log" ); then
        _die_on_compose_up_failure "$compose_up_log"
    fi

    local code i=0
    until code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions"); [[ "$code" != "000" ]]; do
        i=$((i+1)); (( i > 30 )) && die "labserver (docker-compose) did not become reachable at ${CFG_LABSERVER_IP} in time"
        sleep 2
    done
    wait_for_tcp "$CFG_OTG_SERVICE_IP" "$CFG_OTG_SERVICE_PORT" 90 \
        || die "OTG service (docker-compose) did not become reachable on ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} after compose up"

    log_ok "docker-compose labserver+OTG stack deployed"
}

# Recognizes Docker's port-conflict failure signatures in a captured
# `docker compose up` log and dies with an actionable message naming the
# busy port and the exact remediation command, instead of a generic
# "see output above". `docker compose up` only fails to bind a host port
# this way when something OUTSIDE its own project already owns it -
# _preflight_check_compose_conflicts above already ruled out a foreign
# "labserver"/"otg" container by name, so a port conflict this specific
# almost always means either a stale (crashed-mid-deploy or manually
# started) container from a PAST docker-compose run holding the port under
# a container name this check didn't cover, or an unrelated process
# entirely - --destroy clears the former; the message below points at
# checking for the latter too.
_die_on_compose_up_failure() {
    local log="$1"
    if grep -qiE "address already in use|port is already allocated" "$log"; then
        local busy_port endpoint
        busy_port="$(grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+' "$log" | tail -1)"
        endpoint="$(grep -oE 'endpoint [A-Za-z0-9_.-]+' "$log" | tail -1)"
        die "docker compose up failed: host port${busy_port:+ $busy_port} is already in use${endpoint:+ (${endpoint})} - most likely held by a previous labserver/OTG deployment (this tool's own from an earlier run, a standalone-mode leftover, or a manual one) still running. Run './run_snappi_test.sh --destroy' to remove any tool-owned resources, confirm nothing else is bound to that port (e.g. 'ss -tlnp | grep <port>'), then re-run. Full output: $log"
    fi
    die "docker compose up failed for $COMPOSE_DIR/otg-compose.yaml - see $log"
}

# Dies with a clear remediation message if a "labserver"/"otg" container
# already exists but wasn't created by THIS tool's compose project - e.g.
# left over from deployment.mode=standalone, or a manual run. Without this,
# `docker compose up` would fail on it with a much less helpful native
# "container name already in use" error.
_preflight_check_compose_conflicts() {
    local name proj
    for name in labserver otg; do
        docker ps -a --format '{{.Names}}' | grep -qx "$name" || continue
        proj="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null)"
        [[ "$proj" == "$COMPOSE_PROJECT" ]] && continue
        die "A container named '$name' already exists but is not part of this tool's docker-compose stack (compose project='${proj:-<none>}', expected '$COMPOSE_PROJECT') - likely left over from deployment.mode=standalone or a manual run. Remove it first (docker rm -f $name, or --destroy under whichever mode created it), then re-run with deployment.mode=docker-compose."
    done
}

# Reuse check scoped by compose project label (not container name alone) -
# a container merely named "labserver"/"otg" from some other source is never
# mistaken for this tool's own deployment. Uses the same docker_compose_stack_up
# (common.sh) that phase_check_artifacts uses to decide whether the OTG
# installer is needed, so the two checks can never disagree.
_docker_compose_stack_healthy() {
    docker_compose_stack_up || return 1

    local running_image; running_image="$(docker inspect --format '{{.Config.Image}}' labserver 2>/dev/null)"
    if [[ -n "$running_image" && "$running_image" != "registry.oriontest.net/labserver:${CFG_TC_LABSERVER_VERSION}" ]]; then
        log_warn "Reusing already-running docker-compose labserver, but its image ($running_image) does not match testcenter.version=${CFG_TC_VERSION} - run --destroy to redeploy on the configured version."
    fi
    return 0
}

# Every network git operation elsewhere in this file (e.g. env_check.sh's
# vrnetlab clone) goes through _git_net, which disables ALL interactive
# prompts and bounds the call with a hard timeout. Without this, an SSH
# remote that needs a passphrase, or enforces SAML SSO and would otherwise
# print an error and exit, can instead hang the whole deploy indefinitely -
# the process ends up blocked on a prompt with nothing attached that could
# ever answer it, and the only visible symptom is a spinner that never
# finishes. See PID trace from an actual occurrence: `ssh -o
# SendEnv=GIT_PROTOCOL git@github.com git-upload-pack '...'` left running for
# 7+ minutes with no output.
_git_net() {
    GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new" \
    timeout 60 git "$@"
}

# $OTG_SOURCE_DIR (the directory this container solution itself ships
# inside - see config.sh) IS a checkout of the same testcenter-otg-setup
# repository the docker-compose stack needs, so it's used directly instead
# of cloning a separate copy. This only sanity-checks that its layout still
# matches what this integration expects.
_ensure_otg_source_dir() {
    local dir="$1"
    local f
    for f in otg-compose.yaml Dockerfile entrypoint.sh; do
        [[ -f "$dir/$f" ]] || die "OTG source directory $dir is missing expected file '$f' - this integration expects the testcenter-otg-setup layout documented in guide §3.5."
    done
    grep -q '^\s*labserver:' "$dir/otg-compose.yaml" || die "otg-compose.yaml under $dir does not define a 'labserver' service as expected - the testcenter-otg-setup layout may have changed."
    grep -q '^\s*otg:' "$dir/otg-compose.yaml" || die "otg-compose.yaml under $dir does not define an 'otg' service as expected - the testcenter-otg-setup layout may have changed."
}

# Ensures the labserver image is present under BOTH the exact configured-
# version tag docker-compose mode runs (registry.oriontest.net/labserver:<version>,
# matched by snappi-labserver-image.override.yaml above - versioned rather
# than an unversioned ":latest" so multiple STC releases can coexist on the
# same host) AND the bare "labserver:<version>" tag standalone mode uses/
# produces - `docker tag` is additive (never removes a source tag), so
# whichever of the two already exists becomes the source for the other; a
# fresh docker load only happens if NEITHER exists yet.
_ensure_labserver_image_for_compose() {
    local expected="registry.oriontest.net/labserver:${CFG_TC_LABSERVER_VERSION}"
    local bare="labserver:${CFG_TC_LABSERVER_VERSION}"

    local source_tag=""
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "$expected"; then
        source_tag="$expected"
    elif docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "$bare"; then
        source_tag="$bare"
    else
        source_tag="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i "labserver.*${CFG_TC_LABSERVER_VERSION}" | head -1)"
    fi

    if [[ -n "$source_tag" ]]; then
        log_info "Found labserver image '$source_tag' matching ${CFG_TC_LABSERVER_VERSION} - artifact file not required"
    else
        [[ -n "${LABSERVER_IMAGE_FILE:-}" ]] || die "No labserver image matching ${CFG_TC_LABSERVER_VERSION} exists under any tag, and no labserver artifact file was resolved - re-run phase_check_artifacts, or place labserver-${CFG_TC_LABSERVER_VERSION}.tar.xz under $IMAGES_DIR."

        log_info "Loading labserver image for docker-compose from $LABSERVER_IMAGE_FILE"
        source_tag=$(xz -dc "$LABSERVER_IMAGE_FILE" | docker load | awk '{print $NF}' | tail -1)
        [[ -n "$source_tag" ]] || die "docker load of $LABSERVER_IMAGE_FILE did not report an image name"
    fi

    local t
    for t in "$expected" "$bare"; do
        if [[ "$t" != "$source_tag" ]] && ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "$t"; then
            log_info "Tagging '$source_tag' as $t"
            docker tag "$source_tag" "$t" || die "Failed to tag $source_tag as $t"
        fi
    done

    docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "$expected" \
        || die "labserver image still not tagged as $expected - fix manually."
    log_ok "labserver images $expected and $bare both ready"
}

# ------------------------------------------------------------- containerlab -
_deploy_containerlab() {
    _ensure_stc_image_loaded

    # gen_config.sh writes $CLAB_TOPO_FILE moments before this runs. On some
    # hosts (seen on WSL2, possibly endpoint-security file scanning briefly
    # intercepting a newly-created .yml) a process reading it right after can
    # transiently get ENOENT even though the write already completed. Wait
    # for it to be stably present/non-empty before trusting it, and fail with
    # a precise diagnostic - not containerlab's generic "no such file" - if
    # it genuinely never shows up.
    _wait_for_stable_file "$CLAB_TOPO_FILE" \
        || die "Expected containerlab topology file is missing right before deploy: $CLAB_TOPO_FILE
$(ls -la "$(dirname "$CLAB_TOPO_FILE")" 2>&1)
This should have been written by phase_generate_ansible_config moments earlier - re-run and check for antivirus/security-agent interference with $WORK_DIR on this host if it recurs."

    log_info "Redeploying containerlab topology (dut.mode=${CFG_DUT_MODE}) - always destroy+deploy, this resource is fully tool-owned"
    mkdir -p "$WORK_DIR"
    local destroy_out
    destroy_out="$(containerlab destroy -t "$CLAB_TOPO_FILE" --cleanup 2>&1)"
    if [[ $? -ne 0 && "$destroy_out" != *"no containerlab containers found"* ]]; then
        log_warn "containerlab destroy reported an issue before redeploy (continuing anyway - deploy will fail loudly if this matters):"
        log_warn "$destroy_out"
    fi

    local deploy_log="$WORK_DIR/containerlab-deploy.log"
    if ! containerlab deploy -t "$CLAB_TOPO_FILE" 2>&1 | tee "$deploy_log"; then
        die "containerlab deploy failed for $CLAB_TOPO_FILE - see $deploy_log"
    fi

    _verify_containerlab_nodes_up

    state_set "$STATE_FILE" OWN_CLAB 1
    log_ok "containerlab topology deployed and verified in 'docker ps'"
}

_wait_for_stable_file() {
    local f="$1" tries=10 i
    for (( i=0; i<tries; i++ )); do
        [[ -f "$f" && -s "$f" ]] && return 0
        sleep 0.5
    done
    return 1
}

# containerlab's "linux kind" node resolves its image purely from the local
# docker image store - it never loads a tarball itself. If the STC tgz
# wasn't already reflected in `docker images` (checked in phase_check_artifacts),
# load it now, before deploy, and confirm the exact tag containerlab expects
# is actually present afterwards.
_ensure_stc_image_loaded() {
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "stc:${CFG_TC_VERSION}"; then
        return 0
    fi
    [[ -n "${STC_IMAGE_FILE:-}" ]] || die "STC image stc:${CFG_TC_VERSION} is not in 'docker images' and no artifact file was resolved - run phase_check_artifacts first"

    log_info "Loading STC image from $STC_IMAGE_FILE"
    local load_out
    load_out="$(docker load -i "$STC_IMAGE_FILE")" || die "docker load failed for $STC_IMAGE_FILE"
    log_info "$load_out"

    local loaded_tag=""
    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "stc:${CFG_TC_VERSION}"; then
        loaded_tag="$(printf '%s' "$load_out" | awk '{print $NF}' | tail -1)"
        if [[ -n "$loaded_tag" && "$loaded_tag" != "stc:${CFG_TC_VERSION}" ]]; then
            log_warn "Loaded image is tagged '$loaded_tag', not 'stc:${CFG_TC_VERSION}' - re-tagging so containerlab can find it"
            docker tag "$loaded_tag" "stc:${CFG_TC_VERSION}" 2>/dev/null || true
        fi
    fi

    docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "stc:${CFG_TC_VERSION}" \
        || die "docker load of $STC_IMAGE_FILE completed but image stc:${CFG_TC_VERSION} still isn't present (loaded as '${loaded_tag:-unknown}'). Set testcenter.version in config.yaml to match, or re-tag manually."
    log_ok "STC image stc:${CFG_TC_VERSION} ready"
}

# Confirms containerlab actually brought the expected node containers up -
# `containerlab deploy` can exit 0 while individual nodes still fail to
# start, so this is a second, independent check against `docker ps`.
_verify_containerlab_nodes_up() {
    local expected=("snappi-sonic-stc")
    [[ "$CFG_DUT_MODE" == "virtual" ]] && expected+=("${CFG_DUT_HOSTNAME}")

    local node i
    for node in "${expected[@]}"; do
        i=0
        until docker ps --format '{{.Names}}' | grep -q -- "-${node}\$"; do
            i=$((i + 1))
            if (( i > 15 )); then
                die "containerlab node '${node}' did not appear as a running container within 30s after deploy - check $WORK_DIR/containerlab-deploy.log and 'containerlab inspect -t $CLAB_TOPO_FILE'"
            fi
            sleep 2
        done
    done
}

# ----------------------------------------------------------- DUT SSH bootstrap
# ansible-core 2.19+ disables SSH password auth by default (password_mechanism
# changed to ssh_askpass), so the sonic-mgmt container's pubkey must be
# installed on the DUT. containerlab destroy/deploy wipes authorized_keys on
# every virtual redeploy, so this always re-runs after _deploy_containerlab.
# containerlab reports the DUT node container as "running" the instant the
# vrnetlab launcher starts - its own port-22 proxy comes up immediately, long
# before the nested SONiC VM has actually finished booting and sshd/PAM inside
# it are ready to authenticate. Wait for the container's own healthcheck
# (which vrnetlab wires to real boot completion) before _install_dut_ssh_key
# attempts SSH auth, or it fails against a DUT that only *looks* reachable.
_wait_for_dut_container_healthy() {
    local cname; cname="$(docker ps --format '{{.Names}}' | grep -- "-${CFG_DUT_HOSTNAME}\$" | head -1)"
    [[ -n "$cname" ]] || die "Could not resolve DUT container name for node '${CFG_DUT_HOSTNAME}' via docker ps"

    local i=0 status
    status="$(docker inspect --format '{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "none")"
    [[ "$status" == "healthy" || "$status" == "none" ]] && return 0
    log_info "Waiting for DUT container '$cname' to report healthy (SONiC VM still booting)..."
    while true; do
        status="$(docker inspect --format '{{.State.Health.Status}}' "$cname" 2>/dev/null || echo "none")"
        [[ "$status" == "healthy" || "$status" == "none" ]] && return 0
        i=$((i+1))
        if (( i > 90 )); then
            die "DUT container '$cname' did not report healthy within 15m (status=$status) - the nested SONiC VM may be stuck booting; check 'docker logs $cname'"
        fi
        sleep 10
    done
}

_install_dut_ssh_key() {
    log_info "Installing sonic-mgmt SSH key onto DUT ${CFG_DUT_MGMT_IP}"

    [[ "$CFG_DUT_MODE" == "virtual" ]] && _wait_for_dut_container_healthy

    local cuser; cuser="$(sonic_mgmt_user)"
    [[ -n "$cuser" ]] || die "Could not resolve sonic-mgmt container user - is $SONIC_MGMT_CONTAINER running?"
    local pubkey_path="/home/${cuser}/.ssh/id_ed25519.pub"

    if ! docker exec "$SONIC_MGMT_CONTAINER" test -f "$pubkey_path"; then
        docker exec --user "$cuser" "$SONIC_MGMT_CONTAINER" \
            ssh-keygen -t ed25519 -f "/home/${cuser}/.ssh/id_ed25519" -N '' -q
    fi
    local pubkey; pubkey="$(docker exec "$SONIC_MGMT_CONTAINER" cat "$pubkey_path")"

    local i=0
    until docker exec "$SONIC_MGMT_CONTAINER" bash -c "echo > /dev/tcp/${CFG_DUT_MGMT_IP}/22" 2>/dev/null; do
        i=$((i+1)); (( i > 30 )) && die "DUT ${CFG_DUT_MGMT_IP} SSH port not reachable after redeploy"
        sleep 5
    done

    local keyinstall_cmd="sshpass -p '${CFG_DUT_PASSWORD}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${CFG_DUT_USER}@${CFG_DUT_MGMT_IP} '...'"
    log_cmd "$keyinstall_cmd"
    docker exec "$SONIC_MGMT_CONTAINER" bash -c "
        sshpass -p '${CFG_DUT_PASSWORD}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ${CFG_DUT_USER}@${CFG_DUT_MGMT_IP} \
            'mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo \"${pubkey}\" >> ~/.ssh/authorized_keys && sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
    " || die "Failed to install SSH key on DUT ${CFG_DUT_MGMT_IP} (check dut.credentials in config.yaml)"

    docker exec --user "$cuser" "$SONIC_MGMT_CONTAINER" \
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${CFG_DUT_USER}@${CFG_DUT_MGMT_IP}" true \
        || die "Passwordless SSH to DUT ${CFG_DUT_MGMT_IP} still failing after key install"

    log_ok "DUT SSH key auth confirmed"
}

# --------------------------------------------------------------------- allure
_deploy_allure() {
    if [[ "$CFG_ALLURE_ENABLED" != "1" ]]; then
        log_info "Allure not enabled - skipping"
        return
    fi
    local allure_host="${CFG_ALLURE_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    if docker ps --format '{{.Names}}' | grep -qx allure; then
        ALLURE_URL="http://${allure_host}:${CFG_ALLURE_API_PORT}/allure-docker-service/projects/${CFG_ALLURE_PROJECT_ID}/reports/latest/index.html"
        log_ok "Reusing already-running allure container - $ALLURE_URL"
        return
    fi

    mkdir -p "$WORK_DIR/allure/projects"
    cat > "$WORK_DIR/allure/docker-compose.yml" <<EOF
services:
  allure:
    image: "frankescobar/allure-docker-service"
    container_name: allure
    environment:
      CHECK_RESULTS_EVERY_SECONDS: NONE
      KEEP_HISTORY: 1
      KEEP_HISTORY_LATEST: 25
    ports:
      - "${CFG_ALLURE_API_PORT}:5050"
    volumes:
      - ${WORK_DIR}/allure/projects:/app/projects

  allure-ui:
    image: "frankescobar/allure-docker-service-ui"
    container_name: allure-ui
    environment:
      ALLURE_DOCKER_PUBLIC_API_URL: "http://${allure_host}:${CFG_ALLURE_API_PORT}"
      ALLURE_DOCKER_PUBLIC_API_URL_PREFIX: ""
    ports:
      - "${CFG_ALLURE_UI_PORT}:5252"
EOF
    ( cd "$WORK_DIR/allure" && docker compose up -d )
    state_set "$STATE_FILE" OWN_ALLURE 1
    ALLURE_URL="http://${allure_host}:${CFG_ALLURE_API_PORT}/allure-docker-service/projects/${CFG_ALLURE_PROJECT_ID}/reports/latest/index.html"
    log_ok "Allure deployed - $ALLURE_URL"
}

# ------------------------------------------------------------------- destroy
# Removes ONLY resources this tool created (per $STATE_FILE). Externally
# provisioned labserver/OTG and a user-supplied sonic-mgmt checkout/container
# are never touched, regardless of deployment.mode/dut.mode in config.yaml.
# sonic_mgmt.keep_sonic_mgmt_src additionally exempts a tool-owned sonic-mgmt
# clone from deletion - every other tool-owned resource is still removed.
phase_destroy() {
    log_step "Tearing down tool-owned resources"

    # Any previously deployed minigraph is gone once the environment is torn
    # down - a later --pretest/--smoke-test must not skip deploy-mg based on
    # a stale "done" flag from before this teardown.
    state_set "$STATE_FILE" DEPLOY_MG_DONE 0

    if state_owns "$STATE_FILE" OWN_CLAB; then
        log_info "Destroying containerlab topology"
        containerlab destroy -t "$CLAB_TOPO_FILE" --cleanup || log_warn "containerlab destroy reported an error - check manually"
        state_set "$STATE_FILE" OWN_CLAB 0
    else
        log_info "containerlab topology not tool-owned - skipping"
    fi

    # OWN_LABSERVER/OWN_OTG are only ever set by the standalone deploy path
    # (_deploy_labserver / _deploy_otg_service) - deployment.mode=docker-compose
    # deploys both through _deploy_docker_compose_stack instead, which tracks
    # ownership via OWN_COMPOSE below. So in docker-compose mode these two
    # flags are always unset by construction, not because the resources
    # aren't tool-owned - printing "not tool-owned - skipping" here for them
    # would wrongly imply the compose-deployed labserver/OTG were left
    # running. Skip these standalone-only checks entirely in that mode.
    if [[ "$CFG_DEPLOY_MODE" != "docker-compose" ]]; then
        if state_owns "$STATE_FILE" OWN_LABSERVER; then
            log_info "Removing labserver container"
            docker rm -f labserver >/dev/null 2>&1 || true
            state_set "$STATE_FILE" OWN_LABSERVER 0
        else
            log_info "labserver not tool-owned (provisioned or externally running) - skipping"
        fi

        if state_owns "$STATE_FILE" OWN_OTG; then
            local d; d="$(state_get "$STATE_FILE" OTG_INSTALL_DIR)"
            log_info "Stopping OTG service"
            [[ -n "$d" && -x "$d/otgctl" ]] && ( cd "$d" && ./otgctl --shutdown ) || true
            state_set "$STATE_FILE" OWN_OTG 0
        else
            log_info "OTG service not tool-owned - skipping"
        fi
    fi

    if state_owns "$STATE_FILE" OWN_COMPOSE; then
        log_info "Stopping docker-compose labserver+OTG stack (project=$COMPOSE_PROJECT)"
        if [[ -d "$COMPOSE_DIR" ]]; then
            local compose; compose="$(compose_cmd)"
            ( cd "$COMPOSE_DIR" && $compose -p "$COMPOSE_PROJECT" -f otg-compose.yaml -f snappi-labserver-image.override.yaml down ) 2>/dev/null || true
        else
            # $COMPOSE_DIR is gone (e.g. manually deleted) - fall back to
            # removing containers by compose project LABEL, never by the
            # generic "labserver"/"otg" names alone, so an unrelated
            # container that happens to share one of those names is never
            # touched.
            log_warn "docker-compose work dir $COMPOSE_DIR is gone - removing tool-owned containers by compose project label instead"
            local cid
            for cid in $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" 2>/dev/null); do
                docker rm -f "$cid" >/dev/null 2>&1 || true
            done
        fi
        # "down" above never removes images by itself (no --rmi passed), so
        # the OTG image built for this stack is kept by default already -
        # this only matters when the user explicitly wants it gone too.
        # Labserver images (both tags - see _ensure_labserver_image_for_compose)
        # are never touched here regardless of this setting: they're cached
        # VIAVI artifacts, not build output, and may still be in use by a
        # standalone-mode deployment.
        if [[ "$CFG_DOCKER_COMPOSE_KEEP_BUILD_IMAGE" != "1" ]]; then
            log_info "docker_compose.keep_build_image is false - removing built OTG image (otg:latest)"
            docker rmi otg:latest >/dev/null 2>&1 || true
        fi
        state_set "$STATE_FILE" OWN_COMPOSE 0
    else
        log_info "docker-compose stack not tool-owned - skipping"
    fi

    if state_owns "$STATE_FILE" OWN_ALLURE; then
        log_info "Removing allure containers"
        ( cd "$WORK_DIR/allure" && docker compose down ) 2>/dev/null || true
        state_set "$STATE_FILE" OWN_ALLURE 0
    fi

    if state_owns "$STATE_FILE" OWN_SONIC_MGMT_CONTAINER; then
        log_info "Removing sonic-mgmt container ($SONIC_MGMT_CONTAINER)"
        docker rm -f "$SONIC_MGMT_CONTAINER" >/dev/null 2>&1 || true
        state_set "$STATE_FILE" OWN_SONIC_MGMT_CONTAINER 0
    else
        log_info "sonic-mgmt container not tool-owned - skipping"
    fi

    if state_owns "$STATE_FILE" OWN_SONIC_MGMT_CLONE; then
        if [[ "$CFG_SONIC_MGMT_KEEP_SRC" == "1" ]]; then
            log_info "sonic_mgmt.keep_sonic_mgmt_src=true - keeping cloned sonic-mgmt checkout ($(realpath --relative-to="$PWD" "$SONIC_MGMT_DIR" 2>/dev/null || printf '%s' "$SONIC_MGMT_DIR"))"
        else
            log_info "Removing cloned sonic-mgmt checkout ($SONIC_MGMT_DIR)"
            rm -rf "$SONIC_MGMT_DIR"
            state_set "$STATE_FILE" OWN_SONIC_MGMT_CLONE 0
        fi
    else
        log_info "sonic-mgmt source not tool-owned (user-supplied) - skipping"
    fi

    # dut.build_sonic_vs's build output. Only ever touched here if THIS tool
    # actually built it (OWN_DUT_IMAGE/OWN_DUT_ARTIFACTS) - a manually
    # provided/pulled dut.image or a user's own vrnetlab checkout is never
    # tool-owned and is left alone regardless of these settings.
    if state_owns "$STATE_FILE" OWN_DUT_IMAGE; then
        if [[ "$CFG_DUT_KEEP_IMAGE" == "1" ]]; then
            log_info "dut.keep_dut_image=true - keeping built sonic-vs image ($CFG_DUT_IMAGE)"
        else
            log_info "Removing built sonic-vs image ($CFG_DUT_IMAGE)"
            docker rmi "$CFG_DUT_IMAGE" >/dev/null 2>&1 || true
            state_set "$STATE_FILE" OWN_DUT_IMAGE 0
        fi
    else
        log_info "sonic-vs image not tool-built - skipping"
    fi

    if state_owns "$STATE_FILE" OWN_DUT_ARTIFACTS; then
        if [[ "$CFG_DUT_KEEP_ARTIFACTS" == "1" ]]; then
            log_info "dut.keep_dut_artifacts=true - keeping vrnetlab source/build artifacts ($IMAGES_DIR/vrnetlab)"
        else
            log_info "Removing vrnetlab source/build artifacts ($IMAGES_DIR/vrnetlab)"
            rm -rf "$IMAGES_DIR/vrnetlab"
            state_set "$STATE_FILE" OWN_DUT_ARTIFACTS 0
        fi
    else
        log_info "vrnetlab source/build artifacts not tool-downloaded - skipping"
    fi

    log_ok "Teardown complete (tool-owned resources only)"
}
