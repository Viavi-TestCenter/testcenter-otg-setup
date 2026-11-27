#!/usr/bin/env bash
# shellcheck disable=SC2312  # pipelines/command substitutions in tests are best-effort
# test_compose_conflict.sh - a config that enables docker-compose AND marks a service provisioned is
# rejected by the real run_snappi_test.sh before anything happens: no docker call, no work
# directory / state file, no log directory, no lock - in every mode.
#
#   bash container/tests/test_compose_conflict.sh
#
# The script runs for real, in a scratch directory, with a `docker` that only records that it was
# called and `sudo` that must never be reached.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../run_snappi_test.sh"
fails=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="${TMP}/bin"; mkdir -p "${BIN}"
for tool in docker sudo; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/tool-calls"\nexit 1\n' "${tool}" "${TMP}" > "${BIN}/${tool}"
    chmod +x "${BIN}/${tool}"
done

check() {
    if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: $3"; echo "       got : $2"; fails=$((fails + 1)); fi
}
contains() {
    if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       missing: $3"; echo "       in     : $2"; fails=$((fails + 1)); fi
}

# conflicting_config <dir> <labserver-mode|-> <otg-mode|-> : the shipped config.yaml with compose enabled
# and the given (explicit) service modes
conflicting_config() {
    python3 - "${HERE}/../config.yaml" "$1/config.yaml" "$2" "$3" <<'EOF'
import sys, yaml
src, dst, lab, otg = sys.argv[1:5]
cfg = yaml.safe_load(open(src))
og = cfg["deployment"]["otg_labserver"]
og["docker_compose"]["enabled"] = True
if lab != "-":
    og["labserver"]["mode"] = lab
if otg != "-":
    og["otg_service"]["mode"] = otg
yaml.safe_dump(cfg, open(dst, "w"))
EOF
}

# attempt <label> <lab> <otg> <option...>: runs the script from a fresh scratch dir
attempt() {
    local label="$1" lab="$2" otg="$3"; shift 3
    local d="${TMP}/run.$$.${RANDOM}"
    mkdir -p "${d}"
    conflicting_config "${d}" "${lab}" "${otg}"
    rm -f "${TMP}/tool-calls"
    local out rc
    out="$(cd "${d}" && PATH="${BIN}:${PATH}" bash "${SCRIPT}" -c "${d}/config.yaml" "$@" 2>&1)"; rc=$?
    check "${label}: exits 1" "${rc}" "1"
    contains "${label}: names the setting that is true" "${out}" "deployment.otg_labserver.docker_compose.enabled is true"
    check "${label}: docker/sudo never called" "$(cat "${TMP}/tool-calls" 2>/dev/null || true)" ""
    check "${label}: no work directory or state file created" "$(ls -A "${d}")" "config.yaml"
    LAST_OUT="${out}"
}

for opt in --deploy-only --pretest --smoke-test --test-only --access-check --gen-config --deploy-mg --destroy --validate --show-config --list-versions; do
    attempt "provisioned Labserver, ${opt}" provisioned - "${opt}"
    contains "provisioned Labserver, ${opt}: names the Labserver mode" "${LAST_OUT}" 'deployment.otg_labserver.labserver.mode is "provisioned"'
done
attempt "full run (no option), provisioned OTG" - provisioned
contains "provisioned OTG: names the OTG mode" "${LAST_OUT}" 'deployment.otg_labserver.otg_service.mode is "provisioned"'
contains "provisioned OTG: says how to fix it" "${LAST_OUT}" "Set docker_compose.enabled to false to use a provisioned OTG service."
attempt "full run (no option), both provisioned" provisioned provisioned
contains "both provisioned: names the Labserver mode" "${LAST_OUT}" 'deployment.otg_labserver.labserver.mode is "provisioned"'
contains "both provisioned: names the OTG mode" "${LAST_OUT}" 'deployment.otg_labserver.otg_service.mode is "provisioned"'

# The shipped default (compose, modes standalone but inactive) still gets past config loading.
d="${TMP}/default"; mkdir -p "${d}"; cp "${HERE}/../config.yaml" "${d}/config.yaml"
out="$(cd "${d}" && PATH="${BIN}:${PATH}" bash "${SCRIPT}" -c "${d}/config.yaml" --validate 2>&1)"; rc=$?
check "shipped default config: --validate passes" "${rc}" "0"
contains "shipped default config: no conflict reported" "${out}" "config.yaml is valid"

echo
if [[ ${fails} -eq 0 ]]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
