#!/usr/bin/env bash
# versions.sh — --list-versions: reports which TestCenter (STC) versions are
# currently deliverable/testable, by inspecting both the artifact files
# cached under images.dir AND whatever is already loaded into 'docker images'
# (an stc:<version> or *labserver*:<version> tag needs no artifact file at
# all - same reuse rule phase_check_artifacts/deploy.sh apply). Read-only,
# like --show-config: no lock, no log dir, no phases run, nothing
# extracted/downloaded/mutated.
#
# A version is "ready to test" when both its STC artifact (stc_<version>.tgz,
# a Spirent_TestCenter_Docker_<version>.zip, or an already-imported
# stc:<version> docker image) and its labserver (labserver-<version>.tar.xz,
# or an already-imported *labserver*:<version> docker image) are present.
# OTG service installers only need to match a version's leading major.minor
# (otgservice.<major.minor>.*.sh) - see config.yaml's testcenter.version
# comment and config_loader.py's derivation of CFG_TC_OTGSERVICE_VERSION.
phase_list_versions() {
    log_step "Scanning $IMAGES_DIR for deliverable/testable TestCenter (STC) versions"
    [[ -d "$IMAGES_DIR" ]] || die "Images directory does not exist: $IMAGES_DIR (see images.dir in config.yaml)"

    local -A stc_file labserver_file otg_files
    local f base ver v

    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        if [[ "$base" =~ ^stc_([0-9][0-9A-Za-z.]*)\.tgz$ ]]; then
            stc_file["${BASH_REMATCH[1]}"]="$base"
        elif [[ "$base" =~ ^Spirent_TestCenter_Docker_([0-9][0-9A-Za-z.]*)\.zip$ ]]; then
            ver="${BASH_REMATCH[1]}"
            # A plain tgz for the same version, if present, is what
            # phase_check_artifacts actually reuses as-is - only fall back to
            # the zip in the report when no tgz for that version exists.
            [[ -n "${stc_file[$ver]:-}" ]] || stc_file["$ver"]="$base (zip, auto-extracted on first use)"
        elif [[ "$base" =~ ^labserver-([0-9][0-9A-Za-z.]*)\.tar\.xz$ ]]; then
            labserver_file["${BASH_REMATCH[1]}"]="$base"
        elif [[ "$base" =~ ^otgservice\.([0-9]+\.[0-9]+)\..*\.sh$ ]]; then
            ver="${BASH_REMATCH[1]}"
            otg_files["$ver"]="${otg_files[$ver]:+${otg_files[$ver]}, }$base"
        fi
    done < <(find "$IMAGES_DIR" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)

    # A version already imported into 'docker images' needs no artifact file
    # at all (same reuse rule phase_check_artifacts/deploy.sh apply) - fold
    # those in too, without requiring docker_bootstrap_sudo (docker-group
    # membership is assumed here exactly as it is everywhere else this
    # script calls docker).
    local img repo tag
    while IFS= read -r img; do
        ver="${img#stc:}"
        [[ -n "$ver" && -z "${stc_file[$ver]:-}" ]] && stc_file["$ver"]="<already imported into docker images: $img>"
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^stc:' || true)

    # Labserver's tag isn't fixed to a single repository name (deploy.sh loads
    # whatever 'docker load'/the VIAVI archive reports, e.g. "labserver:X" or
    # "registry.oriontest.net/labserver:X") - match any repository containing
    # "labserver" (phase_check_artifacts' own loose match), and only accept
    # dotted-numeric tags as a version (skips "latest", etc.).
    while IFS= read -r img; do
        repo="${img%:*}"; tag="${img##*:}"
        [[ "$repo" =~ [Ll][Aa][Bb][Ss][Ee][Rr][Vv][Ee][Rr] ]] || continue
        [[ "$tag" =~ ^[0-9]+(\.[0-9]+)+$ ]] || continue
        [[ -n "${labserver_file[$tag]:-}" ]] || labserver_file["$tag"]="<already imported into docker images: $img>"
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)

    local -A all_versions=()
    for v in "${!stc_file[@]}"; do all_versions["$v"]=1; done
    for v in "${!labserver_file[@]}"; do all_versions["$v"]=1; done

    echo "=============== SUPPORTED/DELIVERABLE STC VERSIONS (from $IMAGES_DIR) ==============="
    if [[ ${#all_versions[@]} -eq 0 ]]; then
        log_warn "No STC or labserver artifacts found under $IMAGES_DIR - nothing deliverable yet."
    else
        printf '%-16s %-6s %-6s %-8s %s\n' "VERSION" "STC" "LABSRV" "READY" "OTG SERVICE (major.minor match)"
        for v in $(printf '%s\n' "${!all_versions[@]}" | sort -V); do
            local otg_key="${v%.*}" otg_status="-" mark_stc="-" mark_lab="-" ready="no"
            [[ -n "${otg_files[$otg_key]:-}" ]] && otg_status="${otg_files[$otg_key]}"
            if [[ -n "${stc_file[$v]:-}" ]]; then mark_stc="yes"; fi
            if [[ -n "${labserver_file[$v]:-}" ]]; then mark_lab="yes"; fi
            [[ "$mark_stc" == "yes" && "$mark_lab" == "yes" ]] && ready="yes"
            printf '%-16s %-6s %-6s %-8s %s\n' "$v" "$mark_stc" "$mark_lab" "$ready" "$otg_status"
        done
    fi
    echo "======================================================================================"
    row "Currently configured (testcenter.version)" "$CFG_TC_VERSION"
    if [[ -n "${stc_file[$CFG_TC_VERSION]:-}" && -n "${labserver_file[$CFG_TC_VERSION]:-}" ]]; then
        row "  Status" "READY - STC (${stc_file[$CFG_TC_VERSION]}) and labserver (${labserver_file[$CFG_TC_VERSION]}) both present"
    else
        row "  Status" "NOT READY - missing $( [[ -z "${stc_file[$CFG_TC_VERSION]:-}" ]] && echo -n "STC artifact "; [[ -z "${labserver_file[$CFG_TC_VERSION]:-}" ]] && echo -n "labserver artifact")"
    fi
    if [[ -z "${otg_files[$CFG_TC_OTGSERVICE_VERSION]:-}" ]]; then
        row "  OTG service" "no otgservice.${CFG_TC_OTGSERVICE_VERSION}.*.sh under $IMAGES_DIR (only required if the OTG service isn't already reachable/running)"
    else
        row "  OTG service" "${otg_files[$CFG_TC_OTGSERVICE_VERSION]}"
    fi

    # Final rollup: every version with both STC and labserver available right
    # now (file or already-loaded docker image, either counts) - i.e. every
    # "READY = yes" row above, regardless of what's currently configured.
    local ready_versions=()
    for v in $(printf '%s\n' "${!all_versions[@]}" | sort -V); do
        [[ -n "${stc_file[$v]:-}" && -n "${labserver_file[$v]:-}" ]] && ready_versions+=("$v")
    done
    if [[ ${#ready_versions[@]} -gt 0 ]]; then
        row "Fully ready to test now (STC + labserver both available)" "${ready_versions[*]}"
    else
        row "Fully ready to test now (STC + labserver both available)" "none"
    fi
}
