#!/usr/bin/env bash
# env_check.sh — phase 1 (host dependency check/install) and phase 2
# (VIAVI artifact validation). Idempotent: never reinstalls something that
# already meets the minimum requirement.

phase_env_check() {
    log_step "Checking host environment"
    local log="$LOG_DIR/env_check.log"
    if run_phase_with_spinner "Environment check" "$log" _phase_env_check_impl; then
        log_ok "Host environment ready"
    else
        return 1
    fi
}

# Runs under run_phase_with_spinner (backgrounded, output captured to a log
# file) - $SUDO is set here but must still be visible to sonic_mgmt.sh later
# in this run, so it's relayed back via phase_export.
_phase_env_check_impl() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO=""
    elif require_cmd sudo; then
        SUDO="sudo"
    else
        SUDO=""
        log_warn "Not running as root and 'sudo' is not available - installs below may fail."
    fi
    phase_export SUDO "$SUDO"

    _ensure_apt_pkgs git sshpass curl jq ca-certificates make unzip

    _ensure_docker
    _ensure_docker_compose
    _ensure_containerlab
    _ensure_python_deps
}

_ensure_apt_pkgs() {
    local missing=()
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        log_ok "Base packages already present: $*"
        return
    fi
    require_cmd apt-get || die "Package(s) missing (${missing[*]}) and apt-get is not available - install them manually."
    log_info "Installing missing packages: ${missing[*]}"
    $SUDO apt-get update -y
    $SUDO apt-get install -y --no-install-recommends "${missing[@]}"
    log_ok "Installed: ${missing[*]}"
}

_ensure_docker() {
    if require_cmd docker && docker info >/dev/null 2>&1; then
        log_ok "docker already installed and reachable ($(docker --version))"
        return
    fi
    log_info "docker not found/reachable - installing via get.docker.com ..."
    curl -fsSL https://get.docker.com | $SUDO sh
    $SUDO systemctl enable --now docker 2>/dev/null || true
    require_cmd docker || die "docker installation failed"
    log_ok "docker installed ($(docker --version))"
}

_ensure_docker_compose() {
    if docker compose version >/dev/null 2>&1 || require_cmd docker-compose; then
        log_ok "docker-compose already available"
        return
    fi
    log_info "docker-compose not found - installing docker-compose-plugin ..."
    $SUDO apt-get update -y
    $SUDO apt-get install -y --no-install-recommends docker-compose-plugin || true
    if ! docker compose version >/dev/null 2>&1 && ! require_cmd docker-compose; then
        die "docker-compose installation failed - install it manually (https://docs.docker.com/compose/install/)"
    fi
    log_ok "docker-compose installed"
}

_ensure_containerlab() {
    if require_cmd containerlab; then
        log_ok "containerlab already installed ($(containerlab version 2>/dev/null | head -1))"
        return
    fi
    log_info "containerlab not found - installing via containerlab.dev/get script ..."
    curl -sL https://get.containerlab.dev | $SUDO bash
    require_cmd containerlab || die "containerlab installation failed"
    log_ok "containerlab installed"
}

_ensure_python_deps() {
    require_cmd python3 || die "python3 is required and was not found. Install it manually (it is a hard dependency of sonic-mgmt/ansible/pytest tooling)."
    if python3 -c "import yaml" >/dev/null 2>&1; then
        log_ok "PyYAML already available"
    else
        log_info "Installing PyYAML ..."
        python3 -m pip install --quiet --user pyyaml \
            || $SUDO apt-get install -y --no-install-recommends python3-yaml \
            || die "Failed to install PyYAML"
        log_ok "PyYAML installed"
    fi
}

# --- artifact validation: exact filename match, fail on zero or multiple ----
#
# IMPORTANT: _find_exact_artifact is invoked via command substitution
# (`X=$(_find_exact_artifact ...)`), which runs it in a subshell. A `die`
# (i.e. `exit`) called from inside that subshell only terminates the
# subshell - the parent script would see an empty result and keep going as
# if nothing failed. So _find_exact_artifact must never call die(); it
# reports failure via its exit status (0=found, 1=not found/optional,
# 2=not found/required, 3=ambiguous) and the caller - running in the main
# shell, not a subshell - is the one that calls die().
phase_check_artifacts() {
    log_step "Validating VIAVI artifacts in $IMAGES_DIR"
    [[ -d "$IMAGES_DIR" ]] || die "Images directory does not exist: $IMAGES_DIR (see images.dir in config.yaml)"
    local rc

    # --- STC: containerlab always needs image tag stc:<version> locally ---
    # VIAVI ships the docker image either as a raw tarball (stc_<version>.tgz)
    # or as a zip distribution (Spirent_TestCenter_Docker_<version>.zip) that
    # contains that same tgz - the zip is only unpacked when no plain tgz is
    # found, so an already-extracted tgz is always reused as-is.
    STC_IMAGE_FILE=""
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qx "stc:${CFG_TC_VERSION}"; then
        log_ok "STC image stc:${CFG_TC_VERSION} already present in 'docker images' - artifact file not required"
    else
        STC_IMAGE_FILE=$(_find_exact_artifact "stc_${CFG_TC_VERSION}.tgz" "stc_*${CFG_TC_VERSION}*.tgz" true); rc=$?
        if [[ $rc -eq 3 ]]; then
            die "Ambiguous artifact match for STC image (stc:${CFG_TC_VERSION}) under $IMAGES_DIR (see the file list logged above). Pin an exact version in config.yaml so exactly one file matches."
        elif [[ $rc -ne 0 ]]; then
            local stc_zip zip_rc
            stc_zip=$(_find_exact_artifact "Spirent_TestCenter_Docker_${CFG_TC_VERSION}.zip" "Spirent_TestCenter_Docker_*${CFG_TC_VERSION}*.zip" true); zip_rc=$?
            case "$zip_rc" in
                0) _extract_stc_tgz_from_zip "$stc_zip" ;;
                3) die "Ambiguous artifact match for STC image zip (stc:${CFG_TC_VERSION}) under $IMAGES_DIR (see the file list logged above). Pin an exact version in config.yaml so exactly one file matches." ;;
                *) die "STC image (stc:${CFG_TC_VERSION}) not found under $IMAGES_DIR (expected 'stc_${CFG_TC_VERSION}.tgz' or 'Spirent_TestCenter_Docker_${CFG_TC_VERSION}.zip') and no equivalent already imported into docker. Obtain it from VIAVI support and place it there, or import it into docker/containerd first." ;;
            esac
        fi
    fi

    # --- Labserver: reuse if a container/image already exists, else require file ---
    # The loose substring match below intentionally also matches an image
    # loaded under some other tag than the exact one docker-compose mode
    # ultimately runs (registry.oriontest.net/labserver:<version>) - deploy.sh's
    # _ensure_labserver_image_for_compose retags a loose match like that onto
    # the exact tag itself, with no reload and no artifact file needed. Only
    # when NO matching image exists under any tag does the artifact file
    # actually get required here.
    LABSERVER_IMAGE_FILE=""
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx labserver; then
        log_ok "labserver container already exists - artifact file not required"
    elif docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qi "labserver.*${CFG_TC_LABSERVER_VERSION}"; then
        log_ok "labserver image matching ${CFG_TC_LABSERVER_VERSION} already present in 'docker images' - artifact file not required"
    else
        LABSERVER_IMAGE_FILE=$(_find_exact_artifact "labserver-${CFG_TC_LABSERVER_VERSION}.tar.xz" "labserver*${CFG_TC_LABSERVER_VERSION}*.tar.xz"); rc=$?
        _die_on_artifact_rc "$rc" "Labserver image (labserver-${CFG_TC_LABSERVER_VERSION})" "labserver-${CFG_TC_LABSERVER_VERSION}.tar.xz"
    fi

    # --- OTG service (standalone and docker-compose modes only): reuse if already reachable ---
    # docker-compose mode uses docker_compose_stack_up() (common.sh) here -
    # the SAME label-scoped check deploy.sh's own reuse logic uses - rather
    # than bare port reachability. Using a looser check here previously let
    # phase_check_artifacts decide the installer wasn't needed just because
    # *something* answered on the configured port, while deploy.sh's
    # stricter check then found no tool-owned stack and tried to redeploy
    # with no installer file resolved.
    OTGSERVICE_FILE=""
    if [[ "$CFG_DEPLOY_MODE" == "standalone" ]]; then
        if wait_for_tcp "$CFG_OTG_SERVICE_IP" "$CFG_OTG_SERVICE_PORT" 3; then
            log_ok "OTG service already reachable at ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} - installer artifact not required"
        else
            # OTG service versioning doesn't track STC's, so there's no
            # exact filename to try first here (unlike STC/Labserver) - only
            # the leading major.minor (CFG_TC_OTGSERVICE_VERSION, derived
            # from testcenter.version) is required to match.
            OTGSERVICE_FILE=$(_find_exact_artifact "" "otgservice.${CFG_TC_OTGSERVICE_VERSION}.*.sh"); rc=$?
            _die_on_artifact_rc "$rc" "OTG service installer (otgservice.${CFG_TC_OTGSERVICE_VERSION}.*.sh, matching testcenter.version ${CFG_TC_VERSION})" "otgservice.${CFG_TC_OTGSERVICE_VERSION}.*.sh"
        fi
    elif [[ "$CFG_DEPLOY_MODE" == "docker-compose" ]]; then
        if docker_compose_stack_up; then
            log_ok "docker-compose labserver+OTG stack already running (project=$COMPOSE_PROJECT) - installer artifact not required"
        else
            OTGSERVICE_FILE=$(_find_exact_artifact "" "otgservice.${CFG_TC_OTGSERVICE_VERSION}.*.sh"); rc=$?
            _die_on_artifact_rc "$rc" "OTG service installer (otgservice.${CFG_TC_OTGSERVICE_VERSION}.*.sh, matching testcenter.version ${CFG_TC_VERSION})" "otgservice.${CFG_TC_OTGSERVICE_VERSION}.*.sh"
        fi
    fi

    # --- sonic-vs (virtual DUT mode only) ---
    SONIC_VS_ARCHIVE=""
    if [[ "$CFG_DUT_MODE" == "virtual" ]]; then
        if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qx "${CFG_DUT_IMAGE}"; then
            log_ok "sonic-vs image ${CFG_DUT_IMAGE} already present in 'docker images' - artifact file not required"
        elif [[ -n "$CFG_DUT_IMAGE_ARCHIVE" ]]; then
            SONIC_VS_ARCHIVE="$(resolve_path "$CFG_DUT_IMAGE_ARCHIVE")"
            [[ -f "$SONIC_VS_ARCHIVE" ]] || die "dut.image_archive does not exist: $SONIC_VS_ARCHIVE"
        else
            SONIC_VS_ARCHIVE=$(_find_exact_artifact "" "sonic-vs-*.tar.gz sonic-vs-*.gz" true); rc=$?
            if [[ $rc -ne 0 ]]; then
                if [[ "$CFG_DUT_BUILD_SONIC_VS" == "1" && "$CFG_DUT_IMAGE" == vrnetlab/sonic_sonic-vs:* ]]; then
                    _build_sonic_vs_image
                elif [[ "$CFG_DUT_BUILD_SONIC_VS" == "1" ]]; then
                    die "Configured image ${CFG_DUT_IMAGE} is not available locally, and dut.build_sonic_vs only supports building vrnetlab/sonic_sonic-vs:<tag> images. Set dut.image to vrnetlab/sonic_sonic-vs:<tag> to use the automatic build, or place/tag ${CFG_DUT_IMAGE} manually (or via dut.image_archive)."
                else
                    die "sonic-vs image ${CFG_DUT_IMAGE} is not in 'docker images' and no sonic-vs-*.tar.gz archive was found under $IMAGES_DIR. Set dut.image_archive in config.yaml, place a matching archive under images.dir, set dut.build_sonic_vs: true, or load/tag the image manually."
                fi
            fi
        fi
    fi

    log_ok "Artifacts validated: stc=$(basename "${STC_IMAGE_FILE:-<docker images>}") labserver=$(basename "${LABSERVER_IMAGE_FILE:-<existing>}")${OTGSERVICE_FILE:+ otgservice=$(basename "$OTGSERVICE_FILE")}"
}

# Builds the sonic-vs docker image per guide §3.3: downloads sonic-vs.img.gz
# for the branch matching CFG_DUT_IMAGE's tag from https://sonic.software/
# and runs vrnetlab's build. The resulting docker tag comes from vrnetlab's
# own Makefile (it derives VERSION from the sonic-vs-<tag>.qcow2 filename it
# finds via IMAGE_GLOB, not from anything this script tells it), so naming
# the extracted file sonic-vs-<tag>.qcow2 is what makes it land as
# vrnetlab/sonic_sonic-vs:<tag> - this only works for tags sonic.software
# actually publishes a sonic-vs.img.gz build for (master and recent releases;
# see the die message below if a given tag has none).
_build_sonic_vs_image() {
    log_step "dut.image (${CFG_DUT_IMAGE}) not found locally - building it per guide §3.3 (dut.build_sonic_vs=true)"
    local log="$LOG_DIR/sonic_vs_build.log"
    run_phase_with_spinner "Building sonic-vs image" "$log" _build_sonic_vs_image_impl \
        || die "Building ${CFG_DUT_IMAGE} failed - see $log"
    log_ok "sonic-vs image ${CFG_DUT_IMAGE} built and present in 'docker images'"
}

_build_sonic_vs_image_impl() {
    local vrnetlab_dir="$IMAGES_DIR/vrnetlab"
    local sonic_dir="$vrnetlab_dir/sonic"
    local tag="${CFG_DUT_IMAGE##*:}"

    _ensure_vrnetlab_repo "$vrnetlab_dir"
    [[ -d "$sonic_dir" ]] || die "vrnetlab checkout at $vrnetlab_dir has no 'sonic' subdirectory - the upstream repository layout may have changed (expected https://github.com/srl-labs/vrnetlab/tree/master/sonic)."

    if [[ -f "$sonic_dir/sonic-vs-$tag.qcow2" ]]; then
        # dut.keep_dut_artifacts=true kept this from a previous build - reuse
        # it instead of re-downloading ~1GB. A qcow2 only ever exists here
        # once gunzip+mv below have both fully succeeded, so its presence is
        # itself proof it isn't a stray/incomplete leftover.
        log_info "Reusing previously extracted $sonic_dir/sonic-vs-$tag.qcow2 (dut.keep_dut_artifacts=true) - skipping download"
    else
        # vrnetlab's Makefile builds every *.qcow2 it finds in this directory, so
        # a stray file left over from an earlier interrupted attempt must not
        # still be sitting here.
        rm -f "$sonic_dir"/*.qcow2 "$sonic_dir"/*.img "$sonic_dir"/*.img.gz

        _fetch_sonic_vs_img_gz "$tag" "$sonic_dir/sonic-vs-$tag.img.gz"

        log_info "Extracting sonic-vs.img.gz"
        gunzip -f "$sonic_dir/sonic-vs-$tag.img.gz" || die "gunzip of the downloaded sonic-vs.img.gz failed."
        mv "$sonic_dir/sonic-vs-$tag.img" "$sonic_dir/sonic-vs-$tag.qcow2"
    fi

    log_info "Building the sonic-vs docker image (vrnetlab's 'make')"
    ( cd "$sonic_dir" && make ) || die "vrnetlab 'make' failed building sonic-vs - see log above."

    docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "${CFG_DUT_IMAGE}" \
        || die "'make' completed but ${CFG_DUT_IMAGE} still isn't in 'docker images' - the vrnetlab sonic/Makefile layout may have changed upstream, or its derived tag doesn't match '$tag'."

    # Tracks that THIS tool actually built the image, so --destroy only ever
    # considers removing it when dut.keep_dut_image=false (never a
    # manually-provided/pulled image it didn't create) - see phase_destroy.
    state_set "$STATE_FILE" OWN_DUT_IMAGE 1
}

# Downloads sonic-vs.img.gz for $tag into $dest_file, per dut.download_source
# (CFG_DUT_DOWNLOAD_SOURCE). Only ever called once _build_sonic_vs_image_impl
# has already established the image isn't present locally and no cached
# qcow2/archive covers it - branch/tag lookups never run before that.
_fetch_sonic_vs_img_gz() {
    local tag="$1" dest_file="$2"
    case "$CFG_DUT_DOWNLOAD_SOURCE" in
        sonic.software)
            _download_sonic_vs_from_sonic_software "$tag" "$dest_file" \
                || die "Download of sonic-vs.img.gz for tag '$tag' from sonic.software failed - see log above. Place/tag ${CFG_DUT_IMAGE} manually (or via dut.image_archive) instead."
            ;;
        azure)
            _download_sonic_vs_from_azure "$tag" "$dest_file" \
                || die "Download of sonic-vs.img.gz for tag '$tag' from Azure Pipelines failed - see log above. Place/tag ${CFG_DUT_IMAGE} manually (or via dut.image_archive) instead."
            ;;
        auto)
            if _download_sonic_vs_from_azure "$tag" "$dest_file"; then
                return 0
            fi
            log_info "Azure download failed for tag '$tag' - falling back to sonic.software (dut.download_source=auto)"
            _download_sonic_vs_from_sonic_software "$tag" "$dest_file" \
                || die "Download of sonic-vs.img.gz for tag '$tag' failed from both Azure Pipelines and sonic.software - see log above. Place/tag ${CFG_DUT_IMAGE} manually (or via dut.image_archive) instead."
            ;;
        *)
            die "Unknown dut.download_source '${CFG_DUT_DOWNLOAD_SOURCE}' - must be 'auto', 'azure', or 'sonic.software'."
            ;;
    esac
}

# Downloads sonic-vs.img.gz for $tag from https://sonic.software/ into
# $dest_file (guide §3.3). Reports failure via return code rather than
# die() so 'auto' mode can fall back to the other source instead of aborting.
_download_sonic_vs_from_sonic_software() {
    local tag="$1" dest_file="$2"
    log_info "Fetching build index from https://sonic.software/builds.json"
    local builds_json url
    builds_json="$(curl -fsSL --max-time 30 https://sonic.software/builds.json)" || {
        log_info "Failed to fetch https://sonic.software/builds.json - check network access."
        return 1
    }
    url="$(printf '%s' "$builds_json" | jq -r --arg tag "$tag" '.[$tag]["sonic-vs.img.gz"].url // empty')"
    if [[ -z "$url" ]]; then
        log_info "No successful sonic-vs.img.gz build found for tag '$tag' in https://sonic.software/builds.json."
        return 1
    fi

    log_info "Downloading sonic-vs.img.gz ('$tag') from $url"
    curl -fL --retry 3 --retry-delay 5 -o "$dest_file" "$url" || {
        log_info "Download of sonic-vs.img.gz from sonic.software failed."
        return 1
    }
}

# Downloads sonic-vs.img.gz for $tag from the Azure Pipelines "vs" build
# (pipeline 142 on https://sonic-build.azurewebsites.net/, guide §3.3) into
# $dest_file, reproducing the manual browser steps:
#   1. GET .../ui/sonic/pipelines/142/builds?branchName=<tag> - a plain
#      server-rendered HTML table (no JS) - and take the BuildId of the
#      newest row with Result=succeeded ("choose the latest build that has
#      succeeded").
#   2. GET .../api/sonic/artifacts?...&BuildId=<id> - this 302s to a signed
#      artprodcus3.artifacts.visualstudio.com "content?format=zip" URL; this
#      is what clicking that build's single "sonic-buildimage.vs" artifact
#      resolves to.
#   3. Swap that URL's query for format=file&subPath=/target/sonic-vs.img.gz
#      to fetch just that one file (this is what clicking "target/sonic-vs.img.gz"
#      inside the artifact does) instead of the full multi-GB artifact zip.
# Reports failure via return code rather than die() so 'auto' mode can fall
# back to sonic.software instead of aborting.
_download_sonic_vs_from_azure() {
    local tag="$1" dest_file="$2"
    local definition_id=142
    local artifact_name="sonic-buildimage.vs"

    log_info "Looking up the latest succeeded Azure Pipelines build for branch '$tag' (pipeline $definition_id)"
    local builds_html build_id
    builds_html="$(curl -fsSL --max-time 30 -G "https://sonic-build.azurewebsites.net/ui/sonic/pipelines/${definition_id}/builds" \
        --data-urlencode "branchName=${tag}")" || {
        log_info "Failed to fetch the Azure Pipelines build list for branch '$tag' - check network access."
        return 1
    }
    # Simple <tr>/<td> regex scrape - the page is a plain, non-nested HTML
    # table (see the raw response), not JS-rendered like sonic.software's UI.
    build_id="$(printf '%s' "$builds_html" | python3 -c '
import re, sys
html = sys.stdin.read()
for row in re.findall(r"<tr>(.*?)</tr>", html, re.S):
    cells = re.findall(r"<td>(.*?)</td>", row, re.S)
    if len(cells) >= 5 and cells[4].strip() == "succeeded":
        print(cells[0].strip())
        break
')"
    if [[ -z "$build_id" ]]; then
        log_info "No succeeded Azure Pipelines build found for branch '$tag' (pipeline $definition_id)."
        return 1
    fi
    log_info "Using Azure Pipelines build $build_id for branch '$tag'"

    local headers artifact_url
    headers="$(curl -fsS --max-time 30 -D - -o /dev/null -G "https://sonic-build.azurewebsites.net/api/sonic/artifacts" \
        --data-urlencode "branchName=${tag}" \
        --data-urlencode "artifactName=${artifact_name}" \
        --data-urlencode "definitionId=${definition_id}" \
        --data-urlencode "BuildId=${build_id}")" || {
        log_info "Failed to resolve the Azure '${artifact_name}' artifact for build $build_id."
        return 1
    }
    artifact_url="$(printf '%s' "$headers" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | tail -1)"
    if [[ -z "$artifact_url" ]]; then
        log_info "Azure artifact lookup for build $build_id did not return a download location."
        return 1
    fi

    local file_url="${artifact_url%%\?*}?format=file&subPath=%2Ftarget%2Fsonic-vs.img.gz"
    log_info "Downloading sonic-vs.img.gz ('$tag') from Azure Pipelines build $build_id"
    curl -fL --retry 3 --retry-delay 5 -o "$dest_file" "$file_url" || {
        log_info "Download of sonic-vs.img.gz from Azure Pipelines build $build_id failed."
        return 1
    }
}

# Clones vrnetlab into the images cache on first use, reused as-is on later
# runs. Always tracks whatever is HEAD at first clone; there is no version
# pin here since vrnetlab's sonic/Makefile behavior (what actually matters)
# has been stable.
_ensure_vrnetlab_repo() {
    local dir="$1"
    if [[ -d "$dir/.git" ]]; then
        log_info "Reusing cached vrnetlab checkout at $dir"
        return
    fi
    [[ -e "$dir" ]] && die "Expected a git checkout at $dir but it exists without a .git directory - remove it or fix it manually."
    log_info "Cloning vrnetlab (https://github.com/srl-labs/vrnetlab) into $dir"
    _git_net clone --quiet https://github.com/srl-labs/vrnetlab "$dir" \
        || die "git clone of https://github.com/srl-labs/vrnetlab failed or timed out after 60s - check network access."

    # Tracks that THIS tool actually created this checkout, so --destroy only
    # ever considers removing it when dut.keep_dut_artifacts=false - see
    # phase_destroy.
    state_set "$STATE_FILE" OWN_DUT_ARTIFACTS 1
}

# _extract_stc_tgz_from_zip <zip_path>
# Unpacks the stc_<version>.tgz VIAVI's zip distribution contains and sets
# STC_IMAGE_FILE to its path. Called directly from the MAIN shell (never via
# command substitution) so die() actually stops the script - see the note on
# phase_check_artifacts.
_extract_stc_tgz_from_zip() {
    local zip="$1"
    require_cmd unzip || die "unzip is required to extract the STC image from $(basename "$zip") - install it (apt-get install -y unzip) and re-run."

    local entry
    entry="$(unzip -Z1 "$zip" 2>/dev/null | grep -i '^stc_.*\.tgz$' | head -1)"
    [[ -n "$entry" ]] || die "No stc_*.tgz found inside $(basename "$zip") - unexpected VIAVI package layout."

    local extracted="$IMAGES_DIR/$(basename "$entry")"
    if [[ -f "$extracted" ]]; then
        log_ok "STC image tgz already extracted from $(basename "$zip") at $(basename "$extracted")"
    else
        log_info "Extracting $(basename "$extracted") from $(basename "$zip")"
        unzip -o -j "$zip" "$entry" -d "$IMAGES_DIR" >/dev/null || die "Failed to extract $entry from $(basename "$zip")"
        [[ -f "$extracted" ]] || die "Extraction of $(basename "$zip") did not produce $extracted"
        log_ok "Extracted $(basename "$extracted") from $(basename "$zip")"
    fi
    STC_IMAGE_FILE="$extracted"
}

# _die_on_artifact_rc <rc> <description> <expected_exact_filename>
# Runs in the MAIN shell (never inside a subshell) so die() actually stops
# the script.
_die_on_artifact_rc() {
    local rc="$1" desc="$2" exact="$3"
    case "$rc" in
        0) : ;;
        3) die "Ambiguous artifact match for $desc under $IMAGES_DIR (see the file list logged above). Pin an exact version in config.yaml so exactly one file matches." ;;
        *) die "$desc not found under $IMAGES_DIR (expected '$exact') and no equivalent already imported into docker. Obtain it from VIAVI support and place it there, or import it into docker/containerd first." ;;
    esac
}

# _find_exact_artifact <exact_name> <glob_patterns> [optional]
# Tries the exact filename first (fastest, least ambiguous path). If absent,
# falls back to the glob(s) purely to produce a helpful zero/multiple-match
# diagnostic - it never silently substitutes a "close enough" file.
# Exit status: 0 = found (path on stdout), 1 = not found and optional=true,
# 2 = not found and required, 3 = ambiguous (multiple matches, logged to
# stderr). NEVER calls die()/exit - see the note on phase_check_artifacts.
_find_exact_artifact() {
    local exact="$1"; shift
    local patterns="$1"; shift || true
    local optional="${1:-false}"

    if [[ -n "$exact" && -f "$IMAGES_DIR/$exact" ]]; then
        printf '%s' "$IMAGES_DIR/$exact"
        return 0
    fi

    local matches=()
    for pat in $patterns; do
        while IFS= read -r -d '' f; do matches+=("$f"); done \
            < <(find "$IMAGES_DIR" -maxdepth 1 -iname "$pat" -print0 2>/dev/null)
    done
    # de-duplicate
    if [[ ${#matches[@]} -gt 0 ]]; then
        mapfile -t matches < <(printf '%s\n' "${matches[@]}" | sort -u)
    fi

    if [[ ${#matches[@]} -eq 0 ]]; then
        [[ "$optional" == "true" ]] && return 1
        return 2
    fi
    if [[ ${#matches[@]} -gt 1 ]]; then
        log_err "Ambiguous artifact match for '${exact:-$patterns}' under $IMAGES_DIR: ${matches[*]}"
        return 3
    fi
    printf '%s' "${matches[0]}"
    return 0
}
