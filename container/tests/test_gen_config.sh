#!/usr/bin/env bash
# test_gen_config.sh - gen_config.sh after the stage split (proposal §3b items 1-2):
#   - the deploy stage no longer generates ansible/testbed files (phase_generate_ansible_config is gone)
#   - the containerlab topology is generated for the deploy stage from CFG_CLAB_LINK_COUNT, with or
#     without a testbed: section (port comments only when links exist)
#
#   bash container/tests/test_gen_config.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/common.sh"
# shellcheck disable=SC1091
source "$HERE/../lib/gen_config.sh"
fails=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WORK_DIR="$TMP/work"; CLAB_TOPO_FILE="$WORK_DIR/snappi-topology.yml"

check() {
    if [[ "$2" == "1" ]]; then echo "ok   - $1"; else echo "FAIL - $1 ${3:+($3)}"; fails=$((fails + 1)); fi
}
count() { grep -c -- "$1" "$CLAB_TOPO_FILE"; }

setup_virtual() {
    CFG_TC_MODE=virtual; CFG_TC_VERSION=5.62.0766; CFG_STC_CHASSIS_IP=192.168.1.2
    CFG_DUT_HOSTNAME=sonic-s6100-dut1; CFG_DUT_MGMT_IP=192.168.1.3; CFG_DUT_IMAGE=vrnetlab/sonic_sonic-vs:master
    CFG_DUT_USER=admin; CFG_DUT_PASSWORD=admin; CFG_DUT_HWSKU=Force10-S6000
    rm -rf "$WORK_DIR"
}

check "phase_generate_ansible_config is gone (deploy no longer generates testbed files)" \
    "$(declare -F phase_generate_ansible_config >/dev/null && echo 0 || echo 1)"
check "phase_gen_config exists (stage 3)" "$(declare -F phase_gen_config >/dev/null && echo 1 || echo 0)"
check "_gen_clab_topology exists (called from the deploy phase)" "$(declare -F _gen_clab_topology >/dev/null && echo 1 || echo 0)"

# --- deploy-only virtual lab: no testbed section, so no links; link count comes from CFG_CLAB_LINK_COUNT
setup_virtual; CFG_DUT_LINKS_COUNT=0; CFG_CLAB_LINK_COUNT=2
_gen_clab_topology >/dev/null 2>&1
check "no testbed links: 2 veth links from CFG_CLAB_LINK_COUNT" "$([[ "$(count 'type: veth')" == "2" ]] && echo 1 || echo 0)" "$(count 'type: veth')"
check "no testbed links: interfaces eth1 and eth2 on both nodes" \
    "$([[ "$(count 'interface: eth1')" == "2" && "$(count 'interface: eth2')" == "2" ]] && echo 1 || echo 0)"
check "no testbed links: no stale port comments" "$([[ "$(count 'Card1/Port')" == "0" && "$(count '# Ethernet')" == "0" ]] && echo 1 || echo 0)"

# --- with cabling from testbed.dut.links the port names appear as comments
setup_virtual; CFG_DUT_LINKS_COUNT=2; CFG_CLAB_LINK_COUNT=2
CFG_DUT_LINK_0_DUT_PORT=Ethernet0; CFG_DUT_LINK_0_STC_PORT=Card1/Port1
CFG_DUT_LINK_1_DUT_PORT=Ethernet4; CFG_DUT_LINK_1_STC_PORT=Card1/Port2
_gen_clab_topology >/dev/null 2>&1
check "with links: STC and DUT port names kept as comments" \
    "$([[ "$(count '# Card1/Port1')" == "1" && "$(count '# Ethernet4')" == "1" ]] && echo 1 || echo 0)"

# --- explicit link_count larger than the cabling (deployment.dut_vs.link_count)
setup_virtual; CFG_DUT_LINKS_COUNT=0; CFG_CLAB_LINK_COUNT=3
_gen_clab_topology >/dev/null 2>&1
check "link_count 3: 3 veth links with macs :01 :02 :03" \
    "$([[ "$(count 'type: veth')" == "3" && "$(count 'mac: 02:00:00:00:01:03')" == "1" ]] && echo 1 || echo 0)"
check "topology names the chassis image and the DUT image" \
    "$([[ "$(count 'image: stc:5.62.0766')" == "1" && "$(count 'image: vrnetlab/sonic_sonic-vs:master')" == "1" ]] && echo 1 || echo 0)"

# --- physical target: nothing is generated (no containerlab)
setup_virtual; CFG_TC_MODE=physical; CFG_DUT_LINKS_COUNT=0; CFG_CLAB_LINK_COUNT=2
_gen_clab_topology >/dev/null 2>&1
check "physical target: no containerlab topology file" "$([[ ! -e "$CLAB_TOPO_FILE" ]] && echo 1 || echo 0)"

echo
if [[ "$fails" -eq 0 ]]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
