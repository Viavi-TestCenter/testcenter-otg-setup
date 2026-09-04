#!/usr/bin/env bash
# gen_config.sh — phase 4: render the ansible/testbed/topology files that wire
# sonic-mgmt to this lab's IPs, credentials, and cabling, driven entirely by
# config.yaml. Files that are wholly ours are regenerated from scratch; files
# shared with the rest of the sonic-mgmt repo (testbed.yaml, the inv_name.yml
# group_vars file) are patched in place, leaving unrelated content untouched.

phase_generate_ansible_config() {
    log_step "Generating ansible/testbed/topology configuration"

    local ansible_dir="$SONIC_MGMT_DIR/ansible"
    [[ -d "$ansible_dir" ]] || die "ansible/ not found under sonic-mgmt checkout: $ansible_dir"

    _gen_devices_csv "$ansible_dir"
    _gen_links_csv "$ansible_dir"
    _gen_inventory "$ansible_dir"
    _patch_testbed_yaml "$ansible_dir"
    _gen_secrets_yml "$ansible_dir"
    _patch_group_vars_snappi_yml "$ansible_dir"
    _gen_topo_yml "$ansible_dir"
    _gen_password_file "$ansible_dir"
    _gen_clab_topology

    log_ok "Ansible/testbed/topology configuration generated"
}

_otg_ip() { printf '%s' "$CFG_OTG_SERVICE_IP"; }

_gen_devices_csv() {
    local f="$1/files/sonic_${CFG_TESTBED_INV_NAME}_devices.csv"
    mkdir -p "$(dirname "$f")"
    {
        echo "Hostname,ManagementIp,HwSku,Type"
        echo "${CFG_DUT_HOSTNAME},${CFG_DUT_MGMT_IP}/24,${CFG_DUT_HWSKU},DevSonic"
        echo "snappi-sonic-stc,${CFG_STC_CHASSIS_IP}/24,SNAPPI-tester,DevSnappiChassis"
        echo "snappi-sonic-api-serv,$(_otg_ip)/24,SNAPPI-tester,DevSnappiApiServ"
    } > "$f"
    log_info "wrote $f"
}

_gen_links_csv() {
    local f="$1/files/sonic_${CFG_TESTBED_INV_NAME}_links.csv"
    mkdir -p "$(dirname "$f")"
    {
        echo "StartDevice,StartPort,EndDevice,EndPort,BandWidth,VlanID,VlanMode"
        local i
        for (( i=0; i<CFG_DUT_LINKS_COUNT; i++ )); do
            dp_var="CFG_DUT_LINK_${i}_DUT_PORT"; sp_var="CFG_DUT_LINK_${i}_STC_PORT"
            bw_var="CFG_DUT_LINK_${i}_BANDWIDTH"; vid_var="CFG_DUT_LINK_${i}_VLAN_ID"
            echo "${CFG_DUT_HOSTNAME},${!dp_var},snappi-sonic-stc,${!sp_var},${!bw_var},${!vid_var},Access"
        done
    } > "$f"
    log_info "wrote $f"
}

_gen_inventory() {
    local f="$1/${CFG_TESTBED_INV_NAME}"
    local ptf_user_suffix=""
    [[ -n "$CFG_OTG_SSH_USER" ]] && ptf_user_suffix="  ansible_user=${CFG_OTG_SSH_USER}"
    cat > "$f" <<EOF
[${CFG_TESTBED_DUT_GROUP}]
${CFG_DUT_HOSTNAME}     ansible_host=${CFG_DUT_MGMT_IP}

[${CFG_TESTBED_DUT_GROUP}:vars]
hwsku="${CFG_DUT_HWSKU}"
iface_speed='${CFG_DUT_IFACE_SPEED}'

[${CFG_TESTBED_SERVER_GROUP}]
snappi-sonic-stc     ansible_host=${CFG_STC_CHASSIS_IP}   os=snappi

[sonic:children]
${CFG_TESTBED_DUT_GROUP}

[sonic:vars]
mgmt_subnet_mask_length='23'

[${CFG_TESTBED_INV_NAME}:children]
sonic

[ptf]
snappi-sonic-ptf     ansible_host='$(_otg_ip)'${ptf_user_suffix}
EOF
    log_info "wrote $f"
}

_patch_testbed_yaml() {
    local f="$1/testbed.yaml"
    [[ -f "$f" ]] || die "testbed.yaml not found: $f"
    python3 "$LIB_DIR/patch_testbed_yaml.py" "$f" "$CFG_TESTBED_CONF_NAME" <<EOF
conf-name: ${CFG_TESTBED_CONF_NAME}
group-name: vms6-1
topo: ${CFG_TOPO_NAME}
ptf_image_name: docker-stc-api-server
ptf: snappi-sonic-ptf
ptf_ip: $(_otg_ip)
ptf_ipv6:
server: ${CFG_TESTBED_SERVER_GROUP}
vm_base:
dut:
  - ${CFG_DUT_HOSTNAME}
inv_name: ${CFG_TESTBED_INV_NAME}
auto_recover: 'True'
comment: run_snappi_test.sh
EOF
    log_info "patched $f (conf-name: ${CFG_TESTBED_CONF_NAME})"
}

_gen_secrets_yml() {
    local dir="$1/group_vars/${CFG_TESTBED_INV_NAME}"
    mkdir -p "$dir"
    local f="$dir/secrets.yml"
    cat > "$f" <<EOF
ansible_ssh_pass: ${CFG_DUT_PASSWORD}
ansible_become_pass: ${CFG_DUT_PASSWORD}
sonicadmin_user: ${CFG_DUT_USER}
sonicadmin_password: ${CFG_DUT_PASSWORD}
sonicadmin_initial_password: ${CFG_DUT_PASSWORD}
EOF
    chmod 600 "$f"
    log_info "wrote $f (chmod 600)"
}

_patch_group_vars_snappi_yml() {
    local dir="$1/group_vars/${CFG_TESTBED_INV_NAME}"
    local f="$dir/${CFG_TESTBED_INV_NAME}.yml"
    local line="snappi_api_server: {user: ${CFG_OTG_USER}, password: ${CFG_OTG_PASSWORD}, rest_port: ${CFG_OTG_REST_PORT}, session_id: \"None\"}"

    if [[ ! -f "$f" ]]; then
        mkdir -p "$dir"
        printf '%s\n' "$line" > "$f"
        log_info "created $f with snappi_api_server"
        return
    fi

    if grep -q '^snappi_api_server:' "$f"; then
        sed -i "s|^snappi_api_server:.*|${line//\\/\\\\}|" "$f"
    else
        printf '\n%s\n' "$line" >> "$f"
    fi
    grep -q "^snappi_api_server: {user: ${CFG_OTG_USER}" "$f" \
        || die "Failed to patch snappi_api_server into $f - inspect it manually."
    log_info "patched $f (snappi_api_server)"
}

_gen_topo_yml() {
    local f="$1/vars/topo_${CFG_TOPO_NAME}.yml"
    mkdir -p "$(dirname "$f")"
    {
        echo "topology:"
        echo "  host_interfaces:"
        for (( i=0; i<CFG_DUT_TOTAL_PORTS; i++ )); do echo "    - $i"; done
        echo ""
        echo "  DUT:"
        echo "    vlan_configs:"
        echo "      default_vlan_config: one_vlan_a"
        echo "      one_vlan_a:"
        echo "        Vlan${CFG_TOPO_VLAN_ID}:"
        echo "          id: ${CFG_TOPO_VLAN_ID}"
        printf '          intfs: ['
        for (( i=0; i<CFG_DUT_TOTAL_PORTS; i++ )); do
            printf '%s' "$i"
            (( i < CFG_DUT_TOTAL_PORTS - 1 )) && printf ', '
        done
        printf ']\n'
        echo "          prefix: ${CFG_TOPO_VLAN_PREFIX}"
        echo "          prefix_v6: ${CFG_TOPO_VLAN_PREFIX_V6}"
        echo "          tag: ${CFG_TOPO_VLAN_TAG}"
        echo "          mac: ${CFG_TOPO_VLAN_MAC}"
        echo ""
        echo "configuration_properties:"
        echo "  common:"
        echo "    dut_type: ${CFG_TOPO_DUT_TYPE}"
    } > "$f"
    log_info "wrote $f"
}

_gen_password_file() {
    local f="$1/password.txt"
    [[ -f "$f" ]] || echo "abc" > "$f"
    chmod 600 "$f"
}

_gen_clab_topology() {
    mkdir -p "$WORK_DIR"
    if [[ "$CFG_DUT_MODE" == "virtual" ]]; then
        _gen_clab_topology_virtual
    else
        _gen_clab_topology_physical
    fi
    log_info "wrote $CLAB_TOPO_FILE (dut.mode=${CFG_DUT_MODE})"
}

_gen_clab_topology_virtual() {
    {
        echo "name: lab"
        echo ""
        echo "mgmt:"
        echo "  network: clab-snappi-sonic"
        echo "  ipv4-subnet: 192.168.1.0/24"
        echo ""
        echo "topology:"
        echo "  defaults:"
        echo "    env:"
        echo "      CLAB_MGMT_PASSTHROUGH: \"true\""
        echo ""
        echo "  nodes:"
        echo "    snappi-sonic-stc:"
        echo "      kind: linux"
        echo "      image: stc:${CFG_TC_VERSION}"
        echo "      mgmt-ipv4: ${CFG_STC_CHASSIS_IP}"
        echo ""
        echo "    ${CFG_DUT_HOSTNAME}:"
        echo "      kind: sonic-vm"
        echo "      image: ${CFG_DUT_IMAGE}"
        echo "      mgmt-ipv4: ${CFG_DUT_MGMT_IP}"
        echo "      env:"
        echo "        USERNAME: ${CFG_DUT_USER}"
        echo "        PASSWORD: ${CFG_DUT_PASSWORD}"
        echo "        HWSKU: ${CFG_DUT_HWSKU}"
        echo ""
        echo "  links:"
        local i
        for (( i=0; i<CFG_DUT_LINKS_COUNT; i++ )); do
            sp_var="CFG_DUT_LINK_${i}_STC_PORT"; dp_var="CFG_DUT_LINK_${i}_DUT_PORT"
            local eth=$((i + 1))
            echo "    - type: veth"
            echo "      endpoints:"
            echo "        - node: snappi-sonic-stc"
            echo "          interface: eth${eth}           # ${!sp_var}"
            echo "        - node: ${CFG_DUT_HOSTNAME}"
            echo "          interface: eth${eth}           # ${!dp_var}"
            printf '          mac: 02:00:00:00:01:%02x\n' "$((i + 1))"
        done
    } > "$CLAB_TOPO_FILE"
}

_gen_clab_topology_physical() {
    # Physical DUT: the STC container is the ONLY containerlab-managed node.
    # The physical DUT is never a clab resource and is never touched by
    # containerlab destroy/deploy - its front-panel ports are real cables,
    # represented here as "host" links binding the STC container's
    # interfaces directly to physical host NICs (dut.links[].host_interface).
    {
        echo "name: lab"
        echo ""
        echo "mgmt:"
        echo "  network: clab-snappi-sonic"
        echo "  ipv4-subnet: 192.168.1.0/24"
        echo ""
        echo "topology:"
        echo "  nodes:"
        echo "    snappi-sonic-stc:"
        echo "      kind: linux"
        echo "      image: stc:${CFG_TC_VERSION}"
        echo "      mgmt-ipv4: ${CFG_STC_CHASSIS_IP}"
        echo ""
        echo "  links:"
        local i
        for (( i=0; i<CFG_DUT_LINKS_COUNT; i++ )); do
            sp_var="CFG_DUT_LINK_${i}_STC_PORT"; hi_var="CFG_DUT_LINK_${i}_HOST_IF"
            local eth=$((i + 1))
            echo "    - type: host"
            echo "      endpoints:"
            echo "        - node: snappi-sonic-stc"
            echo "          interface: eth${eth}           # ${!sp_var}, cabled to physical DUT"
            echo "        - host-interface: ${!hi_var}"
        done
    } > "$CLAB_TOPO_FILE"
}
