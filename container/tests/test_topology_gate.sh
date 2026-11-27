#!/usr/bin/env bash
# shellcheck disable=SC2312  # pipelines/command substitutions in tests are best-effort
# test_topology_gate.sh - an invalid testbed topology (see config_loader.py: VLAN consistency, >= 2
# links, unique ports, tgen topology name) stops every mode that deploys-and-tests or runs the tests
# BEFORE docker is called, anything is deployed or created, or pytest could start.
#
#   bash container/tests/test_topology_gate.sh
#
# The real run_snappi_test.sh runs in a scratch directory with `docker`/`sudo` stubs that only record
# that they were called.
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

# bad_config <dir> <python statement on `tb` (the testbed: mapping)>
bad_config() {
    python3 - "${HERE}/../config.yaml" "$1/config.yaml" "$2" <<'PY'
import sys, yaml
src, dst, stmt = sys.argv[1:4]
cfg = yaml.safe_load(open(src))
tb = cfg["testbed"]
exec(stmt)
yaml.safe_dump(cfg, open(dst, "w"))
PY
}

attempt() {   # attempt <label> <statement> <expected text> <option...>
    local label="$1" stmt="$2" want="$3"; shift 3
    local d="${TMP}/run.$$.${RANDOM}"
    mkdir -p "${d}"
    bad_config "${d}" "${stmt}"
    rm -f "${TMP}/tool-calls"
    local out rc
    out="$(cd "${d}" && PATH="${BIN}:${PATH}" bash "${SCRIPT}" -c "${d}/config.yaml" "$@" 2>&1)"; rc=$?
    check "${label}: exits 1" "${rc}" "1"
    contains "${label}: explains the problem" "${out}" "${want}"
    check "${label}: docker/sudo never called" "$(cat "${TMP}/tool-calls" 2>/dev/null || true)" ""
    check "${label}: no work directory, state file or log directory created" "$(ls -A "${d}")" "config.yaml"
}

for opt in "" --pretest --smoke-test --test-only --gen-config --deploy-mg --validate; do
    attempt "one link, option '${opt:-none}'" 'tb["dut"]["links"] = tb["dut"]["links"][:1]' \
        "At least two testbed.dut.links entries are required by the smoke-test workflow" ${opt:+"${opt}"}
done
attempt "VLAN mismatch, --pretest" 'tb["topology"]["vlan"]["tag"] = 2000' "testbed.topology.vlan.tag = 2000" --pretest
attempt "duplicate DUT port, --smoke-test" 'tb["dut"]["links"][1]["dut_port"] = "Ethernet0"' "testbed.dut.links[1].dut_port" --smoke-test
attempt "duplicate STC port, --test-only" 'tb["dut"]["links"][1]["stc_port"] = "Card1/Port1"' "testbed.dut.links[1].stc_port" --test-only
attempt "topology name, full run" 'tb["topology"]["name"] = "ptf32"' "sonic-mgmt derives the topology type from this name"

echo
if [[ ${fails} -eq 0 ]]; then echo "ALL PASSED"; else echo "${fails} FAILED"; exit 1; fi
