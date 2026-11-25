#!/usr/bin/env bash
# verify.sh — the access step (stage 2, --access-check) and the inventory check.
#
# phase_access_check: is every component reachable, and can the sonic-mgmt
# container log in to the DUT? It needs none of the generated testbed files and
# writes no sonic-mgmt files. For a PHYSICAL DUT it also ensures the sonic-mgmt
# public key exists in the DUT admin user's authorized_keys (appended only if
# missing) - the one write this tool makes to a physical DUT; SONiC
# configuration is not modified and no minigraph is pushed. Runs inside the
# sonic-mgmt container's context, so the deploy stage must have run. Every test
# stage runs it first, so an unreachable chassis or DUT fails the run before any
# file is regenerated.
#
# _verify_inventory: the only check that needs the generated files (the
# ansible-inventory graph lists the DUT host); it runs at the end of stage 3
# (phase_gen_config in gen_config.sh).

phase_access_check() {
    log_step "Access check: reachability and DUT login"
    _access_reachability
    _access_dut_login
    log_ok "Access check passed"
}

_access_reachability() {
    log_info "Checking reachability (STC chassis: ${CFG_STC_CHASSIS_OWNER:-?}-owned, Labserver: ${CFG_LABSERVER_OWNER:-?}-owned, OTG service: ${CFG_OTG_SERVICE_OWNER:-?}-owned, DUT: ${CFG_DUT_OWNER:-?}-owned)"

    wait_for_tcp "$CFG_DUT_MGMT_IP" 22 10 \
        || die "DUT ${CFG_DUT_MGMT_IP} is not reachable on port 22 (SSH) - check the address ($([[ "$CFG_DUT_OWNER" == "testbed" ]] && echo testbed.dut.mgmt_ip || echo deployment.dut_vs.mgmt_ip)) and the DUT's network."
    log_ok "DUT ${CFG_DUT_MGMT_IP}:22 reachable"

    if [[ "$CFG_TC_MODE" == "physical" ]]; then
        # A physical chassis must be reachable: its address is testbed.endpoints.stc_chassis_ip.
        tcp_any_open "$CFG_STC_CHASSIS_IP" 10 80 443 22 \
            || die "STC chassis ${CFG_STC_CHASSIS_IP} is not reachable (tried TCP 80, 443, 22) - check testbed.endpoints.stc_chassis_ip and the chassis' network. (This check does not compare software versions.)"
        log_ok "STC chassis ${CFG_STC_CHASSIS_IP} reachable"
    else
        wait_for_tcp "$CFG_STC_CHASSIS_IP" 80 10 \
            || log_warn "STC chassis ${CFG_STC_CHASSIS_IP}:80 not reachable (may still be booting)"
    fi

    local code; code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions")
    [[ "$code" == "000" ]] && die "Labserver ${CFG_LABSERVER_IP} not reachable ($([[ "$CFG_LABSERVER_OWNER" == "testbed" ]] && echo "provisioned: testbed.endpoints.labserver_ip" || echo "deployed by this tool"))"
    log_ok "Labserver ${CFG_LABSERVER_IP} reachable (HTTP $code)"

    wait_for_tcp "$CFG_OTG_SERVICE_IP" "$CFG_OTG_SERVICE_PORT" 10 \
        || die "OTG service ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} not reachable ($([[ "$CFG_OTG_SERVICE_OWNER" == "testbed" ]] && echo "provisioned: testbed.endpoints.otg_service" || echo "deployed by this tool"))"
    log_ok "OTG service ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} reachable"
}

_access_dut_login() {
    docker exec "$SONIC_MGMT_CONTAINER" bash -c "echo > /dev/tcp/${CFG_DUT_MGMT_IP}/22" 2>/dev/null \
        || die "sonic-mgmt container cannot reach DUT ${CFG_DUT_MGMT_IP}:22"

    if [[ "$CFG_DUT_MODE" == "physical" ]]; then
        # Installs the key if it is missing, then confirms passwordless login.
        _install_dut_ssh_key
        return
    fi

    # Virtual DUT: its key was installed by the deploy stage (containerlab wipes it
    # on every redeploy); only verify here, write nothing.
    docker exec --user "$(sonic_mgmt_user)" "$SONIC_MGMT_CONTAINER" \
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${CFG_DUT_USER}@${CFG_DUT_MGMT_IP}" true \
        || die "SSH key auth from sonic-mgmt container to DUT is broken - re-run --deploy-only to re-install it, or check ~/.ssh on the DUT."
    log_ok "sonic-mgmt -> DUT SSH key auth OK"
}

_verify_inventory() {
    log_info "Verifying ansible-inventory graph"
    local out
    out="$(sonic_mgmt_exec ansible "ansible-inventory -i ${CFG_TESTBED_INV_NAME} --graph" 2>&1)" \
        || die "ansible-inventory failed:
$out"

    echo ""
    echo "$out"
    echo ""
    [[ -n "${RUN_LOG:-}" ]] && printf '%s\n' "$out" >> "$RUN_LOG"

    echo "$out" | grep -q "@${CFG_TESTBED_SERVER_GROUP}" \
        || die "ansible-inventory graph missing expected group @${CFG_TESTBED_SERVER_GROUP}:
$out"
    echo "$out" | grep -q -- "--${CFG_DUT_HOSTNAME}" \
        || die "ansible-inventory graph missing expected host ${CFG_DUT_HOSTNAME}:
$out"
    echo "$out" | grep -q '@ptf' \
        || die "ansible-inventory graph missing expected group @ptf:
$out"

    log_ok "ansible-inventory graph shape OK"
}
