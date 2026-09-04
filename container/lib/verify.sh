#!/usr/bin/env bash
# verify.sh — phase 6: lightweight health/connectivity checks plus
# ansible-inventory verification. Used both after a full deploy and,
# non-destructively, by --test-only.

phase_verify() {
    log_step "Verifying connectivity and inventory"
    _verify_connectivity
    _verify_inventory
    log_ok "Verification passed"
}

_verify_connectivity() {
    log_info "Checking DUT/STC/OTG/labserver reachability"

    wait_for_tcp "$CFG_DUT_MGMT_IP" 22 10 \
        || die "DUT ${CFG_DUT_MGMT_IP} is not reachable on port 22 (SSH)"
    log_ok "DUT ${CFG_DUT_MGMT_IP}:22 reachable"

    wait_for_tcp "$CFG_STC_CHASSIS_IP" 80 10 \
        || log_warn "STC chassis ${CFG_STC_CHASSIS_IP}:80 not reachable (may still be booting)"

    local code; code=$(http_code "http://${CFG_LABSERVER_IP}/stcapi/sessions")
    [[ "$code" == "000" ]] && die "Labserver ${CFG_LABSERVER_IP} not reachable"
    log_ok "Labserver ${CFG_LABSERVER_IP} reachable (HTTP $code)"

    wait_for_tcp "$CFG_OTG_SERVICE_IP" "$CFG_OTG_SERVICE_PORT" 10 \
        || die "OTG service ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} not reachable"
    log_ok "OTG service ${CFG_OTG_SERVICE_IP}:${CFG_OTG_SERVICE_PORT} reachable"

    if docker exec "$SONIC_MGMT_CONTAINER" bash -c "echo > /dev/tcp/${CFG_DUT_MGMT_IP}/22" 2>/dev/null; then
        docker exec --user "$(sonic_mgmt_user)" "$SONIC_MGMT_CONTAINER" \
            ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${CFG_DUT_USER}@${CFG_DUT_MGMT_IP}" true \
            || die "SSH key auth from sonic-mgmt container to DUT is broken - re-run without --test-only to re-install it, or check ~/.ssh on the DUT."
        log_ok "sonic-mgmt -> DUT SSH key auth OK"
    else
        die "sonic-mgmt container cannot reach DUT ${CFG_DUT_MGMT_IP}:22"
    fi
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
