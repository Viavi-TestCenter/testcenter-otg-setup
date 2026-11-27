#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2312  # variables are defined in the sourcing script / other lib files; pipelines in log helpers are best-effort
# deploy.sh — phase 5: deploy or reuse the labserver, OTG service, and
# containerlab (STC[+DUT]) topology; also implements --destroy, which only
# ever removes resources this tool itself created (tracked in $STATE_FILE).

# ------------------------------------------------------- version change ----
# Detects a tool-owned STC chassis container left over from a previous run
# that was deployed on a different deployment.stc.version than config.yaml now
# names. containerlab itself doesn't need this - _deploy_containerlab below
# always destroys+redeploys the STC node every run regardless of version -
# but the labserver/OTG service/sonic-mgmt container are all reused as-is
# whenever already healthy (see _deploy_labserver), so left alone, a version
# bump here would silently leave those other pieces on the old release.
# Governed by deployment.cleanup.replace_on_version_change (default true:
# replace the whole tool-owned environment, same scope as --destroy).
phase_check_version_change() {
    state_owns "${STATE_FILE}" OWN_CLAB || return 0
    # No version configured (e.g. physical, with nothing deployed that is chosen by version): there is
    # nothing to compare, and comparing against "" would tear a leftover virtual lab down ("replaced by .").
    [[ -n "${CFG_TC_VERSION}" ]] || return 0

    local cname
    cname="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -- '-snappi-sonic-stc$' | head -1)"
    [[ -n "${cname}" ]] || return 0

    local running_image running_version
    running_image="$(docker inspect --format '{{.Config.Image}}' "${cname}" 2>/dev/null)"
    running_version="${running_image#stc:}"
    [[ -n "${running_version}" && "${running_version}" != "${running_image}" ]] || return 0
    [[ "${running_version}" == "${CFG_TC_VERSION}" ]] && return 0

    log_info ""
    log_info "Detected existing deployment:"
    log_info "Version: ${running_version}"
    log_info ""

    if [[ "${CFG_REPLACE_ENV_ON_VERSION_CHANGE}" == "1" ]]; then
        log_info "Existing environment will be destroyed and replaced by ${CFG_TC_VERSION}."
        if phase_destroy; then
            record_phase "Version change" "REPLACED" "${running_version} -> ${CFG_TC_VERSION}"
        else
            record_phase "Version change" "REPLACED" "${running_version} -> ${CFG_TC_VERSION} (teardown had errors - see warnings above; deploy below will attempt to reconcile leftovers)"
        fi
    else
        log_warn "deployment.cleanup.replace_on_version_change is false - keeping the existing ${running_version} environment as-is; per-resource reuse checks below decide what (if anything) gets recreated on ${CFG_TC_VERSION}. Components may end up on mixed versions."
        record_phase "Version change" "KEPT" "${running_version} != ${CFG_TC_VERSION}"
    fi
}

# ------------------------------------------------- deployed identity ----
# The settings that decide WHICH environment --deploy-only builds, recorded in $STATE_FILE after a
# successful deploy and compared again before every test stage (--pretest, --smoke-test, --test-only,
# full run), so tests never run against an environment that no longer matches config.yaml.
# Deliberately small: target, STC version, deployment host address, Labserver and OTG service mode
# (docker-compose, standalone or provisioned - docker_compose.enabled is already reflected in both).
# Everything else in config.yaml (testbed:, license, logging, cleanup, minigraph, ...) is not part
# of it. The host address is only an identity when this tool deploys the Labserver or OTG service;
# a provisioned service's address is testbed.endpoints, not a deployment.
# Output, one per line: <state key>|<config key shown to the user>|<current value>
_deployed_identity_current() {
    local host_ip="n/a"
    if [[ "${CFG_LABSERVER_MODE}" != "provisioned" ]]; then
        host_ip="${CFG_LABSERVER_IP}"
    elif [[ "${CFG_OTG_MODE}" != "provisioned" ]]; then
        host_ip="${CFG_OTG_SERVICE_IP}"
    fi
    printf '%s\n' \
        "DEPLOYED_TARGET|deployment.target|${CFG_TARGET}" \
        "DEPLOYED_STC_VERSION|deployment.stc.version|${CFG_TC_VERSION}" \
        "DEPLOYED_HOST_IP|deployment.otg_labserver.host_ip|${host_ip}" \
        "DEPLOYED_LABSERVER_MODE|Labserver mode|${CFG_LABSERVER_MODE}" \
        "DEPLOYED_OTG_MODE|OTG service mode|${CFG_OTG_MODE}"
}

record_deployed_identity() {
    local key label value
    while IFS='|' read -r key label value; do
        state_set "${STATE_FILE}" "${key}" "${value}"
    done < <(_deployed_identity_current)
}

# Forget the record: the environment is being (re)deployed or removed, so what was recorded no
# longer describes it. A failed deploy therefore leaves "no record" rather than a stale one.
clear_deployed_identity() {
    local tmp; tmp="$(mktemp)"
    grep -v '^DEPLOYED_' "${STATE_FILE}" > "${tmp}" 2>/dev/null || true
    mv "${tmp}" "${STATE_FILE}"
}

# Exit unless the current deployment settings equal the recorded ones. A missing record (fresh
# host, failed or older deploy) is its own error, not a mismatch.
check_deployed_identity() {
    if [[ -z "$(state_get "${STATE_FILE}" DEPLOYED_TARGET)" ]]; then
        die_wrap "No deployment record found - the environment has not been deployed by this tool yet (or the last deployment did not finish)." \
            "Run --deploy-only before running tests."
    fi
    local key label current deployed shown_deployed shown_current mismatches=""
    while IFS='|' read -r key label current; do
        deployed="$(state_get "${STATE_FILE}" "${key}")"
        [[ "${deployed}" == "${current}" ]] && continue
        shown_deployed="${deployed:-(none)}"; shown_current="${current:-(none)}"
        mismatches+="  ${label}:"$'\n'"    deployed: ${shown_deployed}"$'\n'"    current:  ${shown_current}"$'\n'
    done < <(_deployed_identity_current)
    [[ -n "${mismatches}" ]] || return 0
    log_err "Configuration has changed since the environment was deployed:"
    _log ""
    printf '%s' "${mismatches}" | while IFS= read -r line; do _log "${line}"; done >&2
    _log ""
    _log "Run --deploy-only before running tests." >&2
    exit 1
}

phase_deploy_services() {
    log_step "Deploying/verifying lab (services + virtual chassis/DUT)"
    local log="${LOG_DIR}/deploy_services.log"
    if run_phase_with_spinner "Lab deployment" "${log}" _phase_deploy_services_impl; then
        log_ok "Lab ready (services + virtual chassis/DUT)"
    else
        return 1
    fi
}

# Runs under run_phase_with_spinner (backgrounded, output captured to a log
# file) - $ALLURE_URL is set here but must still be visible to the final
# report, so it's relayed back via phase_export.
_phase_deploy_services_impl() {
    # The compose stack deploys Labserver AND OTG service together; otherwise each
    # follows its own mode (standalone | provisioned), so any mix is possible.
    if [[ "${CFG_LABSERVER_MODE}" == "docker-compose" && "${CFG_OTG_MODE}" == "docker-compose" ]]; then
        _deploy_docker_compose_stack
    else
        _deploy_labserver
        _deploy_otg_service
    fi
    if [[ "${CFG_TC_MODE}" == "virtual" ]]; then
        # The containerlab topology is part of the deploy itself (it is only needed
        # to deploy a virtual lab), not of the testbed files generated by --gen-config.
        _gen_clab_topology
        _deploy_containerlab
        # A virtual DUT's credentials are in deployment.dut_vs, and containerlab
        # wipes its authorized_keys on every redeploy, so the key goes in right
        # here. A physical DUT is not contacted by the deploy stage at all: its
        # key is installed by the access step (--access-check).
        _install_dut_ssh_key
    else
        log_info "deployment.target=physical - STC chassis and DUT are external hardware: no containerlab, and the DUT is not contacted by the deploy stage (--access-check installs the sonic-mgmt key)"
    fi
    _deploy_allure
    # An `[[ ... ]] && cmd` here would be the function's last command and make the
    # whole phase "fail" (status 1) whenever Allure is off - which is the default.
    if [[ -n "${ALLURE_URL:-}" ]]; then
        phase_export ALLURE_URL "${ALLURE_URL}"
    fi
}

# ---------------------------------------------------------------- labserver -
# Virtual lab only: a tool-deployed Labserver that came up without a license server
# (deployment.stc.license_server was empty or the placeholder) is recorded in the state
# file as LABSERVER_UNLICENSED=1. A physical chassis has its own licensing path, so nothing
# is recorded there. --deploy-only and the test stages that do not redeploy (--smoke-test,
# --test-only) only warn about it (the license may come from elsewhere), and the next deploy
# recreates the Labserver once a valid value is set.
# Logged while deploying a Labserver with no usable license_server: a warning, or just a note when
# deployment.stc.license_managed_externally acknowledges that the lab is licensed another way.
_license_missing_note() {
    if [[ "${CFG_LICENSE_MANAGED_EXTERNALLY:-0}" == "1" ]]; then
        log_info "deployment.stc.license_server is not set - the Labserver is deployed without a license server ($1); deployment.stc.license_managed_externally is true"
    else
        log_warn "deployment.stc.license_server is empty or the placeholder - the Labserver is deployed WITHOUT a license server ($1). Set it and redeploy before running tests."
    fi
}

_record_labserver_license_state() {
    if [[ "${CFG_TC_MODE}" == "virtual" ]] && ! license_server_valid; then
        state_set "${STATE_FILE}" LABSERVER_UNLICENSED 1
    else
        state_set "${STATE_FILE}" LABSERVER_UNLICENSED 0
    fi
}

# True when the running tool-deployed Labserver must be recreated to pick up a license
# server that is valid now but was not when it was deployed (virtual lab only).
_labserver_needs_license_redeploy() {
    [[ "${CFG_TC_MODE}" == "virtual" ]] && license_server_valid && state_owns "${STATE_FILE}" LABSERVER_UNLICENSED
}

_deploy_labserver() {
    if [[ "${CFG_LABSERVER_MODE}" == "provisioned" ]]; then
        # Never deployed, never destroyed, and not contacted here: reachability of
        # a provisioned Labserver is checked by the access step (--access-check).
        log_info "Labserver is provisioned (${CFG_LABSERVER_IP:-address in testbed.endpoints.labserver_ip}) - not deployed by this tool; its reachability is checked by --access-check"
        state_set "${STATE_FILE}" LABSERVER_UNLICENSED 0
        return
    fi

    if _labserver_needs_license_redeploy && docker ps -a --format '{{.Names}}' | grep -qx labserver; then
        log_info "The labserver was deployed without a license server and deployment.stc.license_server is now set - recreating it"
        docker rm -f labserver >/dev/null
    elif docker ps --format '{{.Names}}' | grep -qx labserver; then
        local code; code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions")
        if [[ "${code}" != "000" ]]; then
            _warn_if_labserver_version_mismatch
            log_ok "Reusing already-running labserver container (HTTP ${code})"
            return
        fi
        log_warn "labserver container is running but not responding (HTTP ${code}) - recreating it"
        docker rm -f labserver >/dev/null
    elif docker ps -a --format '{{.Names}}' | grep -qx labserver; then
        log_info "labserver container exists but is stopped - starting it"
        docker start labserver >/dev/null
        sleep 3
        local code; code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions")
        if [[ "${code}" != "000" ]]; then
            _warn_if_labserver_version_mismatch
            log_ok "Reusing restarted labserver container (HTTP ${code})"
            return
        fi
        log_warn "labserver container did not come up healthy after start - recreating it"
        docker rm -f labserver >/dev/null
    fi

    local image_name
    image_name="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i "labserver.*${CFG_TC_LABSERVER_VERSION}" | head -1)"

    if [[ -n "${image_name}" ]]; then
        log_info "Deploying labserver from existing docker image ${image_name}"
    else
        [[ -n "${LABSERVER_IMAGE_FILE}" ]] \
            || die_wrap "labserver must be (re)created but no labserver artifact file was resolved." "- Re-run phase_check_artifacts, or" "- place labserver-${CFG_TC_LABSERVER_VERSION}.tar.xz under ${IMAGES_DIR} (deployment.images.dir)."

        log_info "Deploying standalone labserver from ${LABSERVER_IMAGE_FILE}"
        image_name=$(xz -dc "${LABSERVER_IMAGE_FILE}" | docker load | awk '{print $NF}' | tail -1)
        [[ -n "${image_name}" ]] || die "docker load of ${LABSERVER_IMAGE_FILE} did not report an image name"
    fi

    docker run --name labserver -v /data:/data --detach=true --restart=always \
        --net=host --log-opt max-size=10m --log-opt max-file=5 --shm-size=250m \
        "${image_name}" >/dev/null

    if license_server_valid; then
        log_info "Configuring license (${CFG_TC_LICENSE_SERVER}) and waiting for supervisor..."
        docker exec labserver sed -i \
            "s|environment=HOME=\"/home/testcenter\",CURLOPT_CAINFO=\"/etc/ssl/certs/ca-certificates.crt\"|environment=HOME=\"/home/testcenter\",CURLOPT_CAINFO=\"/etc/ssl/certs/ca-certificates.crt\",SPIRENTD_LICENSE_FILE=\"${CFG_TC_LICENSE_SERVER}\"|" \
            /etc/supervisor/conf.d/labserver.conf
        docker exec labserver grep -q SPIRENTD_LICENSE_FILE /etc/supervisor/conf.d/labserver.conf \
            || die "Failed to write license config into labserver.conf"
    else
        _license_missing_note "no SPIRENTD_LICENSE_FILE written"
        log_info "Waiting for labserver supervisor..."
    fi
    _record_labserver_license_state

    local i=0
    until docker exec labserver supervisorctl status >/dev/null 2>&1; do
        i=$((i+1)); (( i > 30 )) && die "labserver supervisor did not become ready in time"
        sleep 2
    done
    docker exec labserver supervisorctl restart testcenter-server >/dev/null

    _fix_labserver_stcweb_port_conflict

    state_set "${STATE_FILE}" OWN_LABSERVER 1
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
    if [[ -n "${running_image}" && "${running_image}" != *"${CFG_TC_LABSERVER_VERSION}"* ]]; then
        log_warn "Running labserver container was created from image '${running_image}', which does not match deployment.stc.version=${CFG_TC_VERSION} (labserver's version is derived from this) - continuing with the already-running labserver as-is. Run '--destroy' (or 'docker rm -f labserver') first to redeploy on the configured version."
    fi
}

_fix_labserver_stcweb_port_conflict() {
    local yaml="/home/testcenter/server/stcweb.yaml"
    local nginx_conf="/etc/nginx/sites-enabled/stcapi_stcweb.conf"
    local current
    current=$(docker exec labserver grep -oP 'addr: 127\.0\.0\.1:\K[0-9]+' "${yaml}" 2>/dev/null || echo 8888)
    if ss -tlnp 2>/dev/null | grep -q ":${current} "; then
        local new_port=$((current + 10000))
        log_warn "Host port ${current} occupied - moving stcweb to ${new_port}"
        docker exec labserver sed -i "s|addr: 127\.0\.0\.1:${current}|addr: 127.0.0.1:${new_port}|" "${yaml}"
        docker exec labserver sed -i "s|proxy_pass http://127\.0\.0\.1:${current}|proxy_pass http://127.0.0.1:${new_port}|" "${nginx_conf}"
        docker exec labserver nginx -s reload
        docker exec labserver supervisorctl restart stcweb
    fi
}

# --------------------------------------------------------------- OTG service -
_deploy_otg_service() {
    if [[ "${CFG_OTG_MODE}" == "provisioned" ]]; then
        # Never deployed, never destroyed, and not contacted here: reachability of
        # a provisioned OTG service is checked by the access step (--access-check).
        log_info "OTG service is provisioned (${CFG_OTG_SERVICE_IP:-address in testbed.endpoints.otg_service}:${CFG_OTG_SERVICE_PORT}) - not deployed by this tool; its reachability is checked by --access-check"
        return
    fi

    if wait_for_tcp "${CFG_OTG_SERVICE_IP}" "${CFG_OTG_SERVICE_PORT}" 5; then
        log_ok "Reusing already-running OTG service on ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT}"
        return
    fi

    [[ -n "${OTGSERVICE_FILE:-}" ]] || die "otgservice installer not resolved - run phase_check_artifacts first"
    [[ -f "${OTGSERVICE_FILE}" ]] || die "otgservice installer ${OTGSERVICE_FILE} does not exist"

    log_info "Deploying standalone OTG service from ${OTGSERVICE_FILE}"
    # Wipe any previous extraction under OTGSERVICE_DIR first - this directory
    # is reused across runs, and a stale/partial directory left over from an
    # earlier attempt can collide with (or shadow) a fresh extraction below.
    rm -rf "${OTGSERVICE_DIR}"
    mkdir -p "${OTGSERVICE_DIR}"
    cp "${OTGSERVICE_FILE}" "${OTGSERVICE_DIR}/"

    local installer
    installer="${OTGSERVICE_DIR}/$(basename "${OTGSERVICE_FILE}")"
    chmod +x "${installer}"
    # --nox11: Makeself otherwise tries to respawn itself in an X terminal when
    # there is no tty and DISPLAY is set (e.g. WSLg + xset installed); with no
    # terminal emulator found that becomes `exec -e ...` and extraction fails.
    ( cd "${OTGSERVICE_DIR}" && "./$(basename "${OTGSERVICE_FILE}")" --nox11 )

    local extracted_dir
    extracted_dir="$(find "${OTGSERVICE_DIR}" -mindepth 1 -maxdepth 1 -type d -iname 'otgservice*' -print -quit)"
    [[ -n "${extracted_dir}" ]] || die_wrap "otgservice installer did not produce an otgservice.* directory." "${OTGSERVICE_DIR}"
    [[ -x "${extracted_dir}/otgctl" ]] || die_wrap "otgservice installer extracted, but otgctl is missing or not executable." "${extracted_dir}/otgctl"

    ( cd "${extracted_dir}" && ./otgctl --start )

    # Record ownership right away, as soon as the process actually exists -
    # NOT after the reachability wait below. otgctl --start above is what
    # actually launches the service; if the wait times out (slow startup,
    # transient network hiccup, wrong resolved IP) and we die before ever
    # recording OWN_OTG/OTG_INSTALL_DIR, the service keeps running but
    # becomes permanently untracked - a later run just finds it already
    # reachable via the reuse check above and returns without ever claiming
    # ownership, so --destroy can never find it to shut it down again.
    state_set "${STATE_FILE}" OWN_OTG 1
    state_set "${STATE_FILE}" OTG_INSTALL_DIR "${extracted_dir}"

    ( cd "${extracted_dir}" && ./otgctl --restserver "${CFG_LABSERVER_IP}:80" )

    wait_for_tcp "${CFG_OTG_SERVICE_IP}" "${CFG_OTG_SERVICE_PORT}" 60 \
        || die_wrap "OTG service did not become reachable on ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} after start." "It was still started and is now tracked as tool-owned, so --destroy can tear it down."

    log_ok "OTG service deployed"
}

# --------------------------------------------------------- docker-compose --
# deployment.otg_labserver.docker_compose.enabled: true deploys the labserver
# AND OTG service together via VIAVI's testcenter-otg-setup docker-compose stack (guide §3.5,
# "Docker Compose" flow), sourced from $OTG_SOURCE_DIR - the testcenter-otg-setup
# checkout this container solution itself ships inside - instead of the
# standalone docker-run+otgctl path above. Uses a fixed compose project name
# ($COMPOSE_PROJECT) so reuse and teardown are scoped by Docker's own
# "com.docker.compose.project" label, never by the (fairly generic)
# "labserver"/"otg" container names alone.
_deploy_docker_compose_stack() {
    _preflight_check_compose_conflicts

    if _labserver_needs_license_redeploy && docker_compose_stack_up; then
        log_info "The labserver was deployed without a license server and deployment.stc.license_server is now set - recreating the docker-compose stack"
    elif _docker_compose_stack_healthy; then
        log_ok "Reusing already-running docker-compose labserver+OTG stack (project=${COMPOSE_PROJECT})"
        return
    fi

    _ensure_otg_source_dir "${OTG_SOURCE_DIR}"

    log_info "Preparing docker-compose stack from ${OTG_SOURCE_DIR}"
    rm -rf "${COMPOSE_DIR}"
    mkdir -p "${COMPOSE_DIR}"
    # Copy only the files the compose build needs (not the whole OTG source
    # tree) - $OTG_SOURCE_DIR is the live checkout this container solution
    # itself ships inside (it contains this "container/" directory, so a
    # wholesale copy would recurse into COMPOSE_DIR's own ancestry).
    local f
    for f in otg-compose.yaml Dockerfile entrypoint.sh; do
        cp "${OTG_SOURCE_DIR}/${f}" "${COMPOSE_DIR}/"
    done

    [[ -n "${OTGSERVICE_FILE:-}" ]] || die "otgservice installer not resolved - run phase_check_artifacts first"
    cp "${OTGSERVICE_FILE}" "${COMPOSE_DIR}/"

    _ensure_labserver_image_for_compose

    # .env keys match VIAVI's testcenter-otg-setup convention exactly (guide §3.5
    # step 3) - LICENSE_SERVER/LABSERVER/otg_build are read by otg-compose.yaml.
    local compose_license=""
    if license_server_valid; then
        compose_license="${CFG_TC_LICENSE_SERVER}"
    else
        _license_missing_note "LICENSE_SERVER left blank"
    fi
    cat > "${COMPOSE_DIR}/.env" <<EOF
LICENSE_SERVER=${compose_license}
LABSERVER=${CFG_LABSERVER_IP}
otg_build=$(basename "${OTGSERVICE_FILE}")
EOF
    _record_labserver_license_state

    # A small override file (rather than editing the vendored otg-compose.yaml
    # in place) pins the labserver image to an exact version tag - keeps this
    # integration resilient to unrelated formatting/content changes upstream.
    cat > "${COMPOSE_DIR}/snappi-labserver-image.override.yaml" <<EOF
services:
  labserver:
    image: registry.oriontest.net/labserver:${CFG_TC_LABSERVER_VERSION}
EOF

    local compose; compose="$(compose_cmd)"
    local compose_up_log="${WORK_DIR}/docker-compose-up.log"
    # Ownership is recorded BEFORE calling "up", not after it returns -
    # "up" can create/start some containers (e.g. labserver) and still exit
    # non-zero because a later one (e.g. otg) failed to bind a port; those
    # already-created containers are unambiguously tool-owned regardless of
    # the overall exit status, so --destroy must be able to find and remove
    # them even when this run dies on the very next line. Harmless no-op if
    # "up" fails before creating anything at all.
    state_set "${STATE_FILE}" OWN_COMPOSE 1

    log_info "Starting labserver+OTG via docker compose (${COMPOSE_DIR}, project=${COMPOSE_PROJECT})"
    phase_status "compose up (build)"
    if ! ( cd "${COMPOSE_DIR}" && ${compose} -p "${COMPOSE_PROJECT}" -f otg-compose.yaml -f snappi-labserver-image.override.yaml up -d --build 2>&1 | tee "${compose_up_log}" ); then
        _die_on_compose_up_failure "${compose_up_log}"
    fi

    _die_if_compose_containers_detached

    local code i=0
    phase_status "Labserver starting"
    until code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions"); [[ "${code}" != "000" ]]; do
        i=$((i+1)); (( i > 30 )) && die_wrap "labserver (docker-compose) did not become reachable at ${CFG_LABSERVER_IP} in time."
        sleep 2
    done
    phase_status "OTG starting"
    wait_for_tcp "${CFG_OTG_SERVICE_IP}" "${CFG_OTG_SERVICE_PORT}" 90 \
        || die_wrap "OTG service (docker-compose) did not become reachable on ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} after compose up."

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
    if grep -qiE "address already in use|port is already allocated" "${log}"; then
        local busy_port endpoint
        busy_port="$(grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+' "${log}" | tail -1)"
        endpoint="$(grep -oE 'endpoint [A-Za-z0-9_.-]+' "${log}" | tail -1)"
        die_wrap "docker compose up failed: host port${busy_port:+ ${busy_port}} is already in use${endpoint:+ (${endpoint})}." \
            "Most likely held by a previous labserver/OTG deployment (this tool's own from an earlier run, a standalone-mode leftover, or a manual one) that is still running." \
            "- Run './run_snappi_test.sh --destroy' to remove any tool-owned resources." \
            "- Confirm nothing else is bound to that port (e.g. 'ss -tlnp | grep <port>'), then re-run." \
            "Full output: ${log}"
    fi
    die "docker compose up failed for ${COMPOSE_DIR}/otg-compose.yaml - see ${log}"
}

# Dies with the real cause when a just-started compose container is running but attached to no
# network. Docker then publishes none of its ports, so the reachability waits that follow would
# only time out with a generic "did not become reachable". Seen on WSL2 after an earlier
# "docker compose up" failed with "port is already allocated" and left a half-created container.
_die_if_compose_containers_detached() {
    local name nets
    for name in labserver otg; do
        [[ "$(docker inspect --format '{{.State.Running}}' "${name}" 2>/dev/null)" == "true" ]] || continue
        nets="$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${name}" 2>/dev/null)"
        [[ -n "${nets// /}" ]] && continue
        die_wrap "Container '${name}' is running but is attached to no Docker network." \
            "None of its published ports are reachable from the host. Typically left behind by an earlier failed 'docker compose up' (e.g. 'port is already allocated')." \
            "- Run './run_snappi_test.sh --destroy' and deploy again." \
            "- If it still has no network, restart the Docker daemon first." \
            "Check with: docker inspect ${name} --format '{{json .NetworkSettings.Networks}}'"
    done
}

# Dies with a clear remediation message if a "labserver"/"otg" container
# already exists but wasn't created by THIS tool's compose project - e.g.
# left over from a standalone deployment, or a manual run. Without this,
# `docker compose up` would fail on it with a much less helpful native
# "container name already in use" error.
_preflight_check_compose_conflicts() {
    local name proj
    for name in labserver otg; do
        docker ps -a --format '{{.Names}}' | grep -qx "${name}" || continue
        proj="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "${name}" 2>/dev/null)"
        [[ "${proj}" == "${COMPOSE_PROJECT}" ]] && continue
        die_wrap "A container named '${name}' already exists but is not part of this tool's docker-compose stack (compose project='${proj:-<none>}', expected '${COMPOSE_PROJECT}')." \
            "Likely left over from a standalone deployment or a manual run, or it is a Labserver/OTG service that belongs to someone else. This tool will not remove it." \
            "- Remove it yourself: docker rm -f ${name}" \
            "- Or keep it and describe it as an existing component: deployment.otg_labserver.docker_compose.enabled: false with labserver.mode / otg_service.mode: provisioned (addresses in testbed.endpoints)."
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
    if [[ -n "${running_image}" && "${running_image}" != "registry.oriontest.net/labserver:${CFG_TC_LABSERVER_VERSION}" ]]; then
        log_warn "Reusing already-running docker-compose labserver, but its image (${running_image}) does not match deployment.stc.version=${CFG_TC_VERSION} - run --destroy to redeploy on the configured version."
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
        [[ -f "${dir}/${f}" ]] || die_wrap "OTG source directory ${dir} is missing expected file '${f}'." "This integration expects the testcenter-otg-setup layout."
    done
    grep -q '^\s*labserver:' "${dir}/otg-compose.yaml" || die_wrap "otg-compose.yaml under ${dir} does not define a 'labserver' service." "The testcenter-otg-setup layout may have changed."
    grep -q '^\s*otg:' "${dir}/otg-compose.yaml" || die_wrap "otg-compose.yaml under ${dir} does not define an 'otg' service." "The testcenter-otg-setup layout may have changed."
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
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "${expected}"; then
        source_tag="${expected}"
    elif docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "${bare}"; then
        source_tag="${bare}"
    else
        source_tag="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i "labserver.*${CFG_TC_LABSERVER_VERSION}" | head -1)"
    fi

    if [[ -n "${source_tag}" ]]; then
        log_info "Found labserver image '${source_tag}' matching ${CFG_TC_LABSERVER_VERSION} - artifact file not required"
    else
        [[ -n "${LABSERVER_IMAGE_FILE:-}" ]] || die_wrap "No labserver image matching ${CFG_TC_LABSERVER_VERSION} exists under any tag, and no labserver artifact file was resolved." "- Re-run phase_check_artifacts, or" "- place labserver-${CFG_TC_LABSERVER_VERSION}.tar.xz under ${IMAGES_DIR}."

        log_info "Loading labserver image for docker-compose from ${LABSERVER_IMAGE_FILE}"
        source_tag=$(xz -dc "${LABSERVER_IMAGE_FILE}" | docker load | awk '{print $NF}' | tail -1)
        [[ -n "${source_tag}" ]] || die "docker load of ${LABSERVER_IMAGE_FILE} did not report an image name"
    fi

    local t
    for t in "${expected}" "${bare}"; do
        if [[ "${t}" != "${source_tag}" ]] && ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "${t}"; then
            log_info "Tagging '${source_tag}' as ${t}"
            docker tag "${source_tag}" "${t}" || die "Failed to tag ${source_tag} as ${t}"
        fi
    done

    docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "${expected}" \
        || die "labserver image still not tagged as ${expected} - fix manually."
    log_ok "labserver images ${expected} and ${bare} both ready"
}

# ------------------------------------------------------------- containerlab -
_deploy_containerlab() {
    _ensure_stc_image_loaded

    # _gen_clab_topology (gen_config.sh) writes $CLAB_TOPO_FILE moments before this runs. On some
    # hosts (seen on WSL2, possibly endpoint-security file scanning briefly
    # intercepting a newly-created .yml) a process reading it right after can
    # transiently get ENOENT even though the write already completed. Wait
    # for it to be stably present/non-empty before trusting it, and fail with
    # a precise diagnostic - not containerlab's generic "no such file" - if
    # it genuinely never shows up.
    _wait_for_stable_file "${CLAB_TOPO_FILE}" \
        || die_wrap "Expected containerlab topology file is missing right before deploy: ${CLAB_TOPO_FILE}" \
            "$(ls -la "$(dirname "${CLAB_TOPO_FILE}")" 2>&1)" \
            "This should have been written by _gen_clab_topology moments earlier. Re-run, and check for antivirus/security-agent interference with ${WORK_DIR} on this host if it recurs."

    log_info "Redeploying containerlab topology (deployment.target=${CFG_TARGET}) - always destroy+deploy, this resource is fully tool-owned"
    mkdir -p "${WORK_DIR}"
    local destroy_out
    phase_status "clab: tear down"
    destroy_out="$(containerlab destroy -t "${CLAB_TOPO_FILE}" --cleanup 2>&1)"
    if [[ $? -ne 0 && "${destroy_out}" != *"no containerlab containers found"* ]]; then
        log_warn "containerlab destroy reported an issue before redeploy (continuing anyway - deploy will fail loudly if this matters):"
        log_warn "${destroy_out}"
    fi

    local deploy_log="${WORK_DIR}/containerlab-deploy.log"
    phase_status "clab: deploy"
    if ! containerlab deploy -t "${CLAB_TOPO_FILE}" 2>&1 | tee "${deploy_log}"; then
        die "containerlab deploy failed for ${CLAB_TOPO_FILE} - see ${deploy_log}"
    fi

    _verify_containerlab_nodes_up

    state_set "${STATE_FILE}" OWN_CLAB 1
    log_ok "containerlab topology deployed and verified in 'docker ps'"
}

_wait_for_stable_file() {
    local f="$1" tries=10 i
    for (( i=0; i<tries; i++ )); do
        [[ -f "${f}" && -s "${f}" ]] && return 0
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
    [[ -n "${STC_IMAGE_FILE:-}" ]] || die_wrap "STC image stc:${CFG_TC_VERSION} is not in 'docker images' and no artifact file was resolved." "Run phase_check_artifacts first."

    log_info "Loading STC image from ${STC_IMAGE_FILE}"
    local load_out
    load_out="$(docker load -i "${STC_IMAGE_FILE}")" || die "docker load failed for ${STC_IMAGE_FILE}"
    log_info "${load_out}"

    local loaded_tag=""
    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "stc:${CFG_TC_VERSION}"; then
        loaded_tag="$(printf '%s' "${load_out}" | awk '{print $NF}' | tail -1)"
        if [[ -n "${loaded_tag}" && "${loaded_tag}" != "stc:${CFG_TC_VERSION}" ]]; then
            log_warn "Loaded image is tagged '${loaded_tag}', not 'stc:${CFG_TC_VERSION}' - re-tagging so containerlab can find it"
            docker tag "${loaded_tag}" "stc:${CFG_TC_VERSION}" 2>/dev/null || true
        fi
    fi

    docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "stc:${CFG_TC_VERSION}" \
        || die_wrap "docker load of ${STC_IMAGE_FILE} completed but image stc:${CFG_TC_VERSION} still isn't present (loaded as '${loaded_tag:-unknown}')." "- Set deployment.stc.version in config.yaml to match, or" "- re-tag the image manually."
    log_ok "STC image stc:${CFG_TC_VERSION} ready"
}

# Confirms containerlab actually brought the expected node containers up -
# `containerlab deploy` can exit 0 while individual nodes still fail to
# start, so this is a second, independent check against `docker ps`.
_verify_containerlab_nodes_up() {
    local expected=("snappi-sonic-stc")
    [[ "${CFG_DUT_MODE}" == "virtual" ]] && expected+=("${CFG_DUT_HOSTNAME}")

    local node i
    for node in "${expected[@]}"; do
        i=0
        until docker ps --format '{{.Names}}' | grep -q -- "-${node}\$"; do
            i=$((i + 1))
            if (( i > 15 )); then
                die_wrap "containerlab node '${node}' did not appear as a running container within 30s after deploy." "Check ${WORK_DIR}/containerlab-deploy.log and 'containerlab inspect -t ${CLAB_TOPO_FILE}'."
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
    [[ -n "${cname}" ]] || die "Could not resolve DUT container name for node '${CFG_DUT_HOSTNAME}' via docker ps"

    local i=0 status
    status="$(docker inspect --format '{{.State.Health.Status}}' "${cname}" 2>/dev/null || echo "none")"
    [[ "${status}" == "healthy" || "${status}" == "none" ]] && return 0
    log_info "Waiting for the SONiC-VS DUT '${cname}' to boot (~1-2 min, max 15)..."
    local t0=${SECONDS}
    phase_status "DUT boot ~1-2 min"
    while true; do
        status="$(docker inspect --format '{{.State.Health.Status}}' "${cname}" 2>/dev/null || echo "none")"
        if [[ "${status}" == "healthy" || "${status}" == "none" ]]; then
            phase_status ""
            log_ok "DUT '${cname}' is up (booted in $((SECONDS - t0))s)"
            return 0
        fi
        i=$((i+1))
        if (( i > 90 )); then
            die_wrap "DUT container '${cname}' did not report healthy within 15m (status=${status})." "The nested SONiC VM may be stuck booting; check 'docker logs ${cname}'."
        fi
        sleep 10
    done
}

# Single-quote a string for a POSIX shell: ab'c -> 'ab'\''c'.
_shell_squote() {
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

# The command the DUT's shell runs to install the sonic-mgmt public key. Append
# only if missing (proposal §3b item 7): a repeat run leaves authorized_keys
# byte-identical, other entries keep their order (sshd uses the first matching
# line, so a re-sort could change which from=/command= options apply to a key),
# and a last line without a trailing newline is not glued onto. The key is
# embedded as a single-quoted literal, so a comment with spaces, quotes or a
# dollar sign cannot break out of it. -x -F compares the whole line, so the same
# key with a different comment is added once more (harmless).
_dut_key_install_remote_cmd() {
    local pubkey; pubkey="$(_shell_squote "$1")"
    # shellcheck disable=SC2016  # single quotes are deliberate: this text runs in the DUT's shell
    printf 'pubkey=%s; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && { grep -qxF -- "$pubkey" ~/.ssh/authorized_keys || { [ -z "$(tail -c1 ~/.ssh/authorized_keys)" ] || echo >> ~/.ssh/authorized_keys; echo "$pubkey" >> ~/.ssh/authorized_keys; }; } && chmod 600 ~/.ssh/authorized_keys' "${pubkey}"
}

# Called from the deploy stage for a VIRTUAL DUT (containerlab wipes
# authorized_keys on every redeploy; credentials are in deployment.dut_vs) and
# from the access step (--access-check, and each test stage) for a PHYSICAL DUT,
# where it is the one write this tool makes to the DUT: at most one appended
# line, nothing at all when the key is already there.
_install_dut_ssh_key() {
    log_info "Installing sonic-mgmt SSH key onto DUT ${CFG_DUT_MGMT_IP} (appended only if missing)"

    [[ "${CFG_DUT_MODE}" == "virtual" ]] && _wait_for_dut_container_healthy
    phase_status "DUT SSH key"

    local cuser; cuser="$(sonic_mgmt_user)"
    [[ -n "${cuser}" ]] || die "Could not resolve sonic-mgmt container user - is ${SONIC_MGMT_CONTAINER} running?"
    local pubkey_path="/home/${cuser}/.ssh/id_ed25519.pub"

    if ! docker exec "${SONIC_MGMT_CONTAINER}" test -f "${pubkey_path}"; then
        docker exec --user "${cuser}" "${SONIC_MGMT_CONTAINER}" \
            ssh-keygen -t ed25519 -f "/home/${cuser}/.ssh/id_ed25519" -N '' -q
    fi
    local pubkey; pubkey="$(docker exec "${SONIC_MGMT_CONTAINER}" cat "${pubkey_path}")"

    local i=0
    until docker exec "${SONIC_MGMT_CONTAINER}" bash -c "echo > /dev/tcp/${CFG_DUT_MGMT_IP}/22" 2>/dev/null; do
        i=$((i+1)); (( i > 30 )) && die "DUT ${CFG_DUT_MGMT_IP} SSH port not reachable after redeploy"
        sleep 5
    done

    # No `bash -c "..."` around the ssh call: docker exec passes an argv vector, so
    # the remote command reaches ssh as one argument with no local re-quoting.
    local remote_cmd; remote_cmd="$(_dut_key_install_remote_cmd "${pubkey}")"
    log_cmd "sshpass -p '${CFG_DUT_PASSWORD}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${CFG_DUT_USER}@${CFG_DUT_MGMT_IP} '<append the sonic-mgmt key to ~/.ssh/authorized_keys if missing>'"
    docker exec "${SONIC_MGMT_CONTAINER}" \
        sshpass -p "${CFG_DUT_PASSWORD}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${CFG_DUT_USER}@${CFG_DUT_MGMT_IP}" "${remote_cmd}" \
        || die_wrap "Failed to install SSH key on DUT ${CFG_DUT_MGMT_IP}." "Check the DUT credentials: $([[ "${CFG_DUT_MODE}" == "virtual" ]] && echo deployment.dut_vs.credentials || echo testbed.dut.credentials) in config.yaml."

    docker exec --user "${cuser}" "${SONIC_MGMT_CONTAINER}" \
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${CFG_DUT_USER}@${CFG_DUT_MGMT_IP}" true \
        || die "Passwordless SSH to DUT ${CFG_DUT_MGMT_IP} still failing after key install"

    log_ok "DUT SSH key auth confirmed"
    phase_status ""
}

# --------------------------------------------------------------------- allure
_deploy_allure() {
    if [[ "${CFG_ALLURE_ENABLED}" != "1" ]]; then
        log_info "Allure not enabled - skipping"
        return
    fi
    local allure_host="${CFG_ALLURE_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    # testbed.reporting.allure_project_id is not read by --deploy-only; fall back to the default name
    local allure_project="${CFG_ALLURE_PROJECT_ID:-snappi-smoke}"
    if docker ps --format '{{.Names}}' | grep -qx allure; then
        ALLURE_URL="http://${allure_host}:${CFG_ALLURE_API_PORT}/allure-docker-service/projects/${allure_project}/reports/latest/index.html"
        log_ok "Reusing already-running allure container - ${ALLURE_URL}"
        return
    fi

    mkdir -p "${WORK_DIR}/allure/projects"
    cat > "${WORK_DIR}/allure/docker-compose.yml" <<EOF
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
    ( cd "${WORK_DIR}/allure" && docker compose up -d )
    state_set "${STATE_FILE}" OWN_ALLURE 1
    ALLURE_URL="http://${allure_host}:${CFG_ALLURE_API_PORT}/allure-docker-service/projects/${allure_project}/reports/latest/index.html"
    log_ok "Allure deployed - ${ALLURE_URL}"
}

# ------------------------------------------------------------------- destroy
# Removes ONLY resources this tool created (per $STATE_FILE). Externally
# provisioned labserver/OTG, a physical chassis/DUT and a user-supplied
# sonic-mgmt checkout/container are never touched, whatever config.yaml says.
# deployment.sonic_mgmt.keep_sonic_mgmt_src additionally exempts a tool-owned
# sonic-mgmt clone from deletion - every other tool-owned resource is still removed.
phase_destroy() {
    log_step "Tearing down tool-owned resources"

    # Tracks whether every removal below was actually verified to succeed -
    # phase_destroy's return code (and run_snappi_test.sh's --destroy exit
    # code, which is just $?) reflects this, and the final message below
    # says plainly whether anything may still be left running, instead of
    # unconditionally claiming a clean teardown.
    local ok=1

    # Any previously deployed minigraph is gone once the environment is torn
    # down - a later --pretest/--smoke-test must not skip deploy-mg based on
    # a stale "done" flag from before this teardown.
    clear_deploy_mg_state
    state_set "${STATE_FILE}" LABSERVER_UNLICENSED 0
    clear_deployed_identity

    if state_owns "${STATE_FILE}" OWN_CLAB; then
        log_info "Destroying containerlab topology"
        if containerlab destroy -t "${CLAB_TOPO_FILE}" --cleanup; then
            state_set "${STATE_FILE}" OWN_CLAB 0
        else
            log_warn "containerlab destroy reported an error - check manually"
            ok=0
        fi
    else
        log_info "containerlab topology not tool-owned - skipping"
    fi

    # OWN_LABSERVER/OWN_OTG are only ever set by the standalone deploy path
    # (_deploy_labserver / _deploy_otg_service); the compose stack tracks
    # ownership via OWN_COMPOSE below. Each component is decided on its own
    # ownership flag, never on a shared mode, so a provisioned Labserver is
    # never removed while a standalone OTG service is. The "skipping" lines are
    # only printed for a component whose configured mode is not the compose stack
    # (in compose mode these flags are unset by construction, and a "not
    # tool-owned" line would wrongly imply the compose-deployed ones were left
    # running).
    if state_owns "${STATE_FILE}" OWN_LABSERVER; then
        log_info "Removing labserver container"
        docker rm -f labserver >/dev/null 2>&1
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx labserver; then
            log_warn "labserver container still present after 'docker rm -f labserver' - check manually (docker ps -a, docker logs labserver)"
            ok=0
        else
            state_set "${STATE_FILE}" OWN_LABSERVER 0
            log_ok "labserver container removed"
        fi
    elif [[ "${CFG_LABSERVER_MODE}" == "provisioned" ]]; then
        log_info "labserver is provisioned (external) - never removed by this tool"
    elif [[ "${CFG_LABSERVER_MODE}" == "standalone" ]]; then
        log_info "labserver not tool-owned (externally running) - skipping"
    fi

    if state_owns "${STATE_FILE}" OWN_OTG; then
        local d; d="$(state_get "${STATE_FILE}" OTG_INSTALL_DIR)"
        log_info "Stopping OTG service"
        if [[ -n "${d}" && -x "${d}/otgctl" ]] && ( cd "${d}" && ./otgctl --shutdown ); then
            state_set "${STATE_FILE}" OWN_OTG 0
            log_ok "OTG service stopped"
        else
            log_warn "OTG service shutdown failed or otgctl was not found at '${d}' - check manually (it may still be running)"
            ok=0
        fi
    elif [[ "${CFG_OTG_MODE}" == "provisioned" ]]; then
        log_info "OTG service is provisioned (external) - never stopped by this tool"
    elif [[ "${CFG_OTG_MODE}" == "standalone" ]]; then
        log_info "OTG service not tool-owned - skipping"
    fi

    if state_owns "${STATE_FILE}" OWN_COMPOSE; then
        log_info "Stopping docker-compose labserver+OTG stack (project=${COMPOSE_PROJECT})"
        if [[ -d "${COMPOSE_DIR}" ]]; then
            local compose; compose="$(compose_cmd)"
            ( cd "${COMPOSE_DIR}" && ${compose} -p "${COMPOSE_PROJECT}" -f otg-compose.yaml -f snappi-labserver-image.override.yaml down ) 2>/dev/null || true
        else
            # $COMPOSE_DIR is gone (e.g. manually deleted) - fall back to
            # removing containers by compose project LABEL, never by the
            # generic "labserver"/"otg" names alone, so an unrelated
            # container that happens to share one of those names is never
            # touched.
            log_warn "docker-compose work dir ${COMPOSE_DIR} is gone - removing tool-owned containers by compose project label instead"
            local cid
            for cid in $(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null); do
                docker rm -f "${cid}" >/dev/null 2>&1 || true
            done
        fi
        if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null)" ]]; then
            log_warn "docker-compose stack (project=${COMPOSE_PROJECT}) still has containers after teardown - check manually (docker ps -a --filter label=com.docker.compose.project=${COMPOSE_PROJECT})"
            ok=0
        else
            state_set "${STATE_FILE}" OWN_COMPOSE 0
            log_ok "docker-compose stack removed"
        fi
        # "down" above never removes images by itself (no --rmi passed), so
        # the OTG image built for this stack is kept by default already -
        # this only matters when the user explicitly wants it gone too.
        # Labserver images (both tags - see _ensure_labserver_image_for_compose)
        # are never touched here regardless of this setting: they're cached
        # VIAVI artifacts, not build output, and may still be in use by a
        # standalone-mode deployment.
        if [[ "${CFG_DOCKER_COMPOSE_KEEP_BUILD_IMAGE}" != "1" ]]; then
            log_info "deployment.otg_labserver.docker_compose.keep_build_image is false - removing built OTG image (otg:latest)"
            docker rmi otg:latest >/dev/null 2>&1 || true
        fi
    else
        log_info "docker-compose stack not tool-owned - skipping"
    fi

    if state_owns "${STATE_FILE}" OWN_ALLURE; then
        log_info "Removing allure containers"
        if ( cd "${WORK_DIR}/allure" && docker compose down ) 2>/dev/null; then
            state_set "${STATE_FILE}" OWN_ALLURE 0
            log_ok "allure containers removed"
        else
            log_warn "allure teardown ('docker compose down' in ${WORK_DIR}/allure) reported an error - check manually"
            ok=0
        fi
    fi

    if state_owns "${STATE_FILE}" OWN_SONIC_MGMT_CONTAINER; then
        log_info "Removing sonic-mgmt container (${SONIC_MGMT_CONTAINER})"
        docker rm -f "${SONIC_MGMT_CONTAINER}" >/dev/null 2>&1
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${SONIC_MGMT_CONTAINER}"; then
            log_warn "sonic-mgmt container '${SONIC_MGMT_CONTAINER}' still present after 'docker rm -f' - check manually"
            ok=0
        else
            state_set "${STATE_FILE}" OWN_SONIC_MGMT_CONTAINER 0
            log_ok "sonic-mgmt container removed"
        fi
    else
        log_info "sonic-mgmt container not tool-owned - skipping"
    fi

    if state_owns "${STATE_FILE}" OWN_SONIC_MGMT_CLONE; then
        if [[ "${CFG_SONIC_MGMT_KEEP_SRC}" == "1" ]]; then
            log_info "deployment.sonic_mgmt.keep_sonic_mgmt_src=true - keeping cloned sonic-mgmt checkout ($(realpath --relative-to="${PWD}" "${SONIC_MGMT_DIR}" 2>/dev/null || printf '%s' "${SONIC_MGMT_DIR}"))"
        else
            log_info "Removing cloned sonic-mgmt checkout (${SONIC_MGMT_DIR})"
            rm -rf "${SONIC_MGMT_DIR}"
            state_set "${STATE_FILE}" OWN_SONIC_MGMT_CLONE 0
        fi
    else
        log_info "sonic-mgmt source not tool-owned (user-supplied) - skipping"
    fi

    # deployment.dut_vs.build_sonic_vs's build output. Only ever touched here if THIS tool
    # actually built it (OWN_DUT_IMAGE/OWN_DUT_ARTIFACTS) - a manually
    # provided/pulled deployment.dut_vs.image or a user's own vrnetlab checkout is never
    # tool-owned and is left alone regardless of these settings.
    if state_owns "${STATE_FILE}" OWN_DUT_IMAGE; then
        if [[ "${CFG_DUT_KEEP_IMAGE}" == "1" ]]; then
            log_info "deployment.dut_vs.keep_dut_image=true - keeping built sonic-vs image (${CFG_DUT_IMAGE})"
        else
            log_info "Removing built sonic-vs image (${CFG_DUT_IMAGE})"
            docker rmi "${CFG_DUT_IMAGE}" >/dev/null 2>&1 || true
            state_set "${STATE_FILE}" OWN_DUT_IMAGE 0
        fi
    else
        log_info "sonic-vs image not tool-built - skipping"
    fi

    if state_owns "${STATE_FILE}" OWN_DUT_ARTIFACTS; then
        if [[ "${CFG_DUT_KEEP_ARTIFACTS}" == "1" ]]; then
            log_info "deployment.dut_vs.keep_dut_artifacts=true - keeping vrnetlab source/build artifacts (${IMAGES_DIR}/vrnetlab)"
        else
            log_info "Removing vrnetlab source/build artifacts (${IMAGES_DIR}/vrnetlab)"
            rm -rf "${IMAGES_DIR}/vrnetlab"
            state_set "${STATE_FILE}" OWN_DUT_ARTIFACTS 0
        fi
    else
        log_info "vrnetlab source/build artifacts not tool-downloaded - skipping"
    fi

    if [[ "${ok}" -eq 1 ]]; then
        log_ok "Teardown complete (tool-owned resources only)"
        return 0
    else
        log_warn "Teardown finished with errors - some tool-owned resources may still be running (see warnings above)"
        return 1
    fi
}
