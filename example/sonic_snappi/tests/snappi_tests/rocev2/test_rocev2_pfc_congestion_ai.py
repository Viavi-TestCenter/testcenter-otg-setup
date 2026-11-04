# flake8: noqa: F403, F401, F405
"""
PFC congestion (incast) - all scenarios in one parametrized test.

Bidirectional 3:1 incast: 3 Tx ports send to a single Rx port at 100% line rate
(no compute_tx_rates_single_rx), oversubscribing the Rx egress to trigger
PFC on the lossless queues. Two Txs drive the lossless queues defined by the
scenario (entries cycled across them: Q3 and Q4); the last Tx (last_tx) drives
the lossy queues (0/1). ACK/NAK ride the common ACK queue (Q6) for all flows;
CNP -> Q5.

Scenarios (each lossless entry goes to its own Tx; the lossy Tx is separate):
    q3_single  - lossless Txs on Q3, 128KB                [TC2 Step 4]
    q3q4_same  - lossless Txs on Q3 and Q4, both 128KB    [TC2 Step 6]
    q3q4_mixed - lossless Txs on Q3 128KB and Q4 4KB      [TC2 Step 8]

Every queue is bidirectional: for each sender queue (QP) the Rx port also sends
a QP on the SAME queue/DSCP/message size back to that sender (BIDIRECTIONAL below;
set it False for the old one-way incast). Only the sender->Rx direction is
congested; the return direction (Rx -> sender) is uncongested and must be loss-free.

All plumbing lives in files/helper.py; this file carries only the
queue/priority intent, the (incast) topology, and the checks.
"""
import pytest
import logging

from snappi_tests.rocev2.files.helper import *   # lib + re-exported fixtures

logger = logging.getLogger(__name__)

pytestmark = [pytest.mark.topology('multidut-tgen', 'tgen')]

TRAFFIC_DURATION = 20      # seconds
LOSSY_QUEUES = [0, 1]
ACK_QUEUE = 6              # common queue carrying ACK/NAK for all (lossless + lossy) flows
CNP_QUEUE = 5              # CNP control queue; its DSCP comes from the DUT DSCP->TC map
LINE_RATE_PCT = 100       # % - each Tx sends at full rate to create the incast
BIDIRECTIONAL = True      # Rx sends every sender's queues back to it (return flows)
# Fixed DSCP per lossless queue instead of a random pick from the TC's DSCPs. The STC
# sender only paused for PFC priority 3 when the stream used DSCP 26 (it kept line
# rate with DSCP 3), so pin the lossless queues to a DSCP whose top 3 bits equal the
# queue: Q3 -> DSCP 26, Q4 -> DSCP 34 (DSCP 26 maps to TC3, 34 to TC4 on the DUT).
LOSSLESS_DSCP = {3: 26, 4: 34}
RATE_TOLERANCE_PCT = 5

# Addressing confirmed working end-to-end via the STC UI for this 4-port (1 Rx +
# 3 Tx) incast: each port is its own /31 point-to-point link (tester_ip,
# dut_gateway_ip), one subnet per port - same convention as
# repro_rocev2_peer_cap.py's RX_IP_CFG/TX_IP_CFGS. Overridden here because
# tests/common/snappi_tests/snappi_fixtures.py's auto IP assignment (minigraph
# read-back, or a single dut_ip_start/snappi_ip_start pool keyed by the port's
# position in the *whole* testbed port list) has no notion of this topology's
# 3-subnet scheme and will not reliably reproduce it. Which port ends up as Rx
# vs Tx is still decided at random by build_incast_topology - these IPs are
# keyed by the DUT port each tester port is cabled to (peer_port), so they
# always match the address configured on that DUT interface, not by port_id order.
PORT_IP_OVERRIDES = {
    "Ethernet0": ("50.1.1.1", "50.1.1.0"),
    "Ethernet8": ("50.1.1.3", "50.1.1.2"),
    "Ethernet16": ("50.1.1.5", "50.1.1.4"),
    "Ethernet24": ("50.1.1.7", "50.1.1.6"),
}
PORT_IP_PREFIX = 31


def _apply_port_ip_overrides(tconfig, plist, port_ids, overrides, prefix):
    """
    Force the snappi-side tester IP/gateway/prefix for `port_ids` to the
    `overrides` entry of the DUT port each one is cabled to, on both the SnappiPortConfig objects (plist, consumed by
    configure_rocev2_topology for peer destination_ip_address) and the matching
    device's IPv4 stack in `tconfig` (the actual address the port transmits
    from). Only touches the already-built snappi config/port objects - does not
    push anything to the DUT, since the DUT side is expected to already carry
    these addresses.
    """
    pc_by_id = {pc.id: pc for pc in plist}
    for port_id in port_ids:
        pc = pc_by_id[port_id]
        tester_ip, dut_ip = overrides[pc.peer_port]
        pc.ip = tester_ip
        pc.gateway = dut_ip
        pc.prefix_len = prefix
        device = next(d for d in tconfig.devices if d.name == f"Device Port {port_id}")
        ip_stack = device.ethernets[0].ipv4_addresses[0]
        ip_stack.address = tester_ip
        ip_stack.gateway = dut_ip
        ip_stack.prefix = prefix

def _add_return_flows(topology, rx, qp_num_base):
    """
    Make every sender <-> Rx pair bidirectional. For each sender port, the Rx port
    gets a peer back to it carrying one QP per sender QP, with the same dscp /
    message size / ecn (so the same queue) and its own unique qp_num:
    (rx_port_id+1)*100 + 10*(sender_port_id+1) + queue, where queue is recovered
    from the sender's qp_num = qp_num_base(sender, queue). Mutates and returns
    topology; the Rx entry keeps its port-level settings (mtu, cnp, connection_type).
    """
    senders = [p for p in topology if p != rx]
    peer_qp_configs = {}
    for s in senders:
        rev = []
        for qp in topology[s]["qp_configs"]:
            q = qp["qp_num"] - qp_num_base(s, 0)
            rev.append({**{k: v for k, v in qp.items() if k != "qp_num"},
                        "qp_num": (rx + 1) * 100 + 10 * (s + 1) + q})
        peer_qp_configs[s] = rev
    rx_entry = {k: v for k, v in topology[rx].items() if k != "qp_configs"}
    topology[rx] = {**rx_entry, "peers": senders, "peer_qp_configs": peer_qp_configs}
    return topology


# Each scenario = list of (lossless_queue, message_size_kb) entries, cycled
# across the lossless Tx ports (one entry per Tx). The last Tx always drives
# LOSSY_QUEUES. With 1 Rx + 3 Tx there are 2 lossless Txs, so the 2-entry
# scenarios put Q3 and Q4 on independent senders.
PFC_SCENARIOS = {
    "q3_single":  [(3, 128)],
    "q3q4_same":  [(3, 128), (4, 128)],
    "q3q4_mixed": [(3, 128), (4, 4)],
}


def _conn(ack_nak_q, priority_to_dscp):
    return {
        "choice": "reliable_connection",
        "reliable_connection": {
            "ack": {"ip_dscp": priority_to_dscp[ack_nak_q], "ecn_value": "non_ect"},
            "nak": {"ip_dscp": priority_to_dscp[ack_nak_q], "ecn_value": "non_ect"},
            "enable_retransmission_timeout": False,
            "retransmission_timeout_value": 5000,
            "retransmission_retry_count": 254
        },
    }


@pytest.mark.parametrize("scenario", list(PFC_SCENARIOS), ids=list(PFC_SCENARIOS))
def test_rocev2_pfc_congestion_ai(
                                    request,
                                    snappi_api,
                                    conn_graph_facts,
                                    fanout_graph_facts_multidut,
                                    get_snappi_ports,
                                    duthosts,
                                    prio_dscp_map,
                                    scenario,
                                ):
    """
    3:1 incast at 100% line rate. The lossless queue must be protected by PFC
    (no loss, no NAK, ACKs present, no ECN-CE/CNP, PFC pause observed); the
    last Tx's lossy queues are unprotected. DWRR weights govern the Rx-egress
    rate split between the senders.
    """
    snappi_port_list = get_snappi_ports
    pytest_require(len(snappi_port_list) >= 4, "Need minimum of 4 ports")

    tconfig, plist, sports = snappi_dut_base_config(duthosts, snappi_port_list, snappi_api)
    snappi_dut_port_map = snappi_dut_port_mapping(sports)
    # 1 Rx + the rest Tx (3 Tx on a 4-port rig).
    port_ids = [pc.id for pc in plist]
    _apply_port_ip_overrides(tconfig, plist, port_ids, PORT_IP_OVERRIDES, PORT_IP_PREFIX)
    # derive_priority_to_dscp returns a memoized dict shared across tests: copy before pinning.
    priority_to_dscp = dict(derive_priority_to_dscp(prio_dscp_map))
    for q, dscp in LOSSLESS_DSCP.items():
        pytest_assert(dscp in prio_dscp_map.get(q, []),
                      f"Lossless queue {q}: DSCP {dscp} is not mapped to TC{q} in the DUT DSCP_TO_TC_MAP "
                      f"(TC{q} DSCPs: {prio_dscp_map.get(q)})")
        priority_to_dscp[q] = dscp
    lossless_spec = PFC_SCENARIOS[scenario]

    port_cfg = {"transmit_type": "target_line_rate", "target_line_rate": LINE_RATE_PCT}
    cnp_dscp = priority_to_dscp[CNP_QUEUE]
    logger.info(f"CNP on queue {CNP_QUEUE} -> DSCP {cnp_dscp} (from DUT DSCP->TC map)")
    cnp_cfg = {"ip_dscp": cnp_dscp, "ecn_value": "non_ect"}

    # qp_num keys off BOTH the port and the queue: (port_id+1)*100 + q, e.g.
    # port0 -> 100s, port1 -> 200s, port2 -> 300s. Two different device/ports
    # must never end up with the same QP number even if they ever land on the
    # same queue (e.g. a 3rd sender cycling back onto an already-used
    # lossless_spec entry; the 3:1 topology can't trigger that since q in
    # {3,4} for lossless never overlaps q in {0,1} for lossy, but the formula
    # no longer relies on that). Room for more QPs per port later: add entries
    # to a port's qp_configs list with distinct q values - each still gets a
    # unique qp_num for free.
    def _qp_num(port_id, q):
        return (port_id + 1) * 100 + q

    def lossless_cfg(port_id, q, size_kb):
        return {
            "mtu": 9100,
            "ib_mtu": 4096,
            "qp_configs": [{"message_size_unit": "kb", "message_size": size_kb,
                            "dscp": priority_to_dscp[q], "qp_num": _qp_num(port_id, q)}],
            "cnp": cnp_cfg,
            "dcqcn_settings": {"enable_dcqcn": False},
            "connection_type": _conn(ACK_QUEUE, priority_to_dscp),   # ACK/NAK on the common ACK queue
            "rocev2_port_config": port_cfg,
        }

    def lossy_cfg(port_id):
        return {
            "mtu": 9100,
            "ib_mtu": 4096,
            "qp_configs": [{"message_size_unit": "kb", "message_size": 128,
                            "dscp": priority_to_dscp[q], "qp_num": _qp_num(port_id, q)} for q in LOSSY_QUEUES],
            "cnp": cnp_cfg,
            "dcqcn_settings": {"enable_dcqcn": False},
            "connection_type": _conn(ACK_QUEUE, priority_to_dscp),   # ACK/NAK on the common ACK queue
            "rocev2_port_config": port_cfg,
        }

    # 1 Rx, 3 Tx: the two lossless Txs use the scenario's (queue, size) entries;
    # the last Tx (last_tx) is always the lossy sender.
    topology, rx, last_tx, used = build_incast_topology(
        port_ids, lossless_cfg, lossless_spec, lossy_cfg)
    if BIDIRECTIONAL:
        topology = _add_return_flows(topology, rx, _qp_num)
    used_lossless = sorted({q for q, _ in used})
    logger.info(f"[{scenario}] incast rx={rx} last_tx={last_tx} lossless_qs={used_lossless} "
                f"bidirectional={BIDIRECTIONAL}\n{topology}")

    # Pure PFC test: WRED on the lossless queue DROPS non-ECT traffic before PFC
    # engages. Disable WRED on ALL test ports, for ONLY the queues this test uses,
    # so congestion drives PFC pause. Always restored in finally.
    queues_used = used_lossless + LOSSY_QUEUES + [ACK_QUEUE, CNP_QUEUE]
    wred_saved = {}   # bound before mutation so the finally can always restore
    try:
        wred_saved = disable_wred(snappi_dut_port_map, queues_used)
        # ---- run incast + collect DUT-side data (universal collector) ----------
        qids = [f"UC{q}" for q in queues_used]
        merged_df, _, _, _, _ = collect_flow_queue_stats(
            snappi_api=snappi_api, duthosts=duthosts, plist=plist, tconfig=tconfig,
            snappi_dut_port_map=snappi_dut_port_map, topology=topology,
            prio_dscp_map=prio_dscp_map, queue_ids=qids, traffic_duration=TRAFFIC_DURATION,
            config_name=request.node.name)

        # DWRR fairness per QUEUE (rate split between the lossless and lossy Tx).
        rate_check_df = build_rate_fairness_by_queue(merged_df)
        pytest_assert(not rate_check_df.empty,
                      "DWRR rate fairness: no flows have a scheduler weight/TC mapping on the Rx "
                      "egress port (check SCHEDULER/QUEUE config and DSCP_TO_TC_MAP on the DUT)")
        logger.info(f"DWRR rate fairness:\n{tabulate(rate_check_df, headers='keys', tablefmt='psql')}")

        lossless_dscps = [priority_to_dscp[q] for q in used_lossless]
        lossy_dscps = [priority_to_dscp[q] for q in LOSSY_QUEUES]

        # PFC pause expected on the lossless priority(ies). Measured from the DUT
        # Tx PFC counter (authoritative); the snappi Rx-pause port stat reads 0
        # even when PFC is demonstrably pacing the senders. One-row total across
        # the DUT interfaces so a single make_check asserts "PFC was generated".
        # Delta-safe: run_rocev2_step clears pfc/queue counters (sonic-clear
        # pfccounters) just before starting traffic, so these reflect only this run.
        pfc_df = pfc_counters(snappi_dut_port_map, direction="Tx")
        logger.info(f"DUT Tx PFC counters:\n{tabulate(pfc_df, headers='keys', tablefmt='psql')}")
        # Fail explicitly (not vacuously) if the DUT PFC counter surface is missing
        # the expected priority columns - otherwise the checks would pass/fail for
        # the wrong reason.
        pfc_cols = [f"PFC{q}" for q in used_lossless if f"PFC{q}" in pfc_df.columns]
        pytest_assert(len(pfc_cols) == len(used_lossless),
                      f"Missing DUT PFC counter column(s) for lossless priorities {used_lossless}; "
                      f"have {list(pfc_df.columns)}")
        pfc_totals = {c: int(pd.to_numeric(pfc_df[c], errors="coerce").fillna(0).sum()) for c in pfc_cols}
        pfc_sum_df = pd.DataFrame([pfc_totals])
        pfc_fail_expr = " or ".join(f"{c} == 0" for c in pfc_cols)

        # Lossy priorities are unprotected: the DUT must NOT generate PFC pause on
        # them (congestion drops them instead of pausing the sender).
        pfc_lossy_cols = [f"PFC{q}" for q in LOSSY_QUEUES if f"PFC{q}" in pfc_df.columns]
        pytest_assert(len(pfc_lossy_cols) == len(LOSSY_QUEUES),
                      f"Missing DUT PFC counter column(s) for lossy priorities {LOSSY_QUEUES}; "
                      f"have {list(pfc_df.columns)}")
        pfc_lossy_totals = {c: int(pd.to_numeric(pfc_df[c], errors="coerce").fillna(0).sum())
                            for c in pfc_lossy_cols}
        pfc_lossy_df = pd.DataFrame([pfc_lossy_totals])
        pfc_lossy_fail_expr = " or ".join(f"{c} != 0" for c in pfc_lossy_cols)

        # ---- checks --------------------------------------------------------
        # make_check(expr,...): expr is the FAILURE condition (any matching row fails).
        checks = [
            # Lossless queues must be PROTECTED by PFC: no loss ...
            make_check(f"ip_dscp in {lossless_dscps} and (message_fail != 0 or frame_delta != 0)",
                    ["flow_name", "port_tx", "port_rx", "ip_dscp", "message_fail", "frame_delta"],
                    "Lossless: no loss (PFC protected)",
                    f"message_fail=0 & frame_delta=0 required for lossless DSCPs {lossless_dscps}"),
            # ... no NAK / sequence errors ...
            make_check(f"ip_dscp in {lossless_dscps} and (nak_tx != 0 or nak_rx != 0 or frame_sequence_error != 0)",
                    ["flow_name", "port_tx", "port_rx", "ip_dscp", "nak_tx", "nak_rx", "frame_sequence_error"],
                    "Lossless: no NAK/sequence errors",
                    f"nak/seq must be 0 for lossless DSCPs {lossless_dscps}"),
            # ... ACKs present ...
            make_check(f"ip_dscp in {lossless_dscps} and ack_tx == 0",
                    ["flow_name", "port_tx", "port_rx", "ip_dscp", "ack_tx", "ack_rx"],
                    f"Lossless: ACKs present {lossless_dscps}",
                    f"ack_tx > 0 required for lossless DSCPs {lossless_dscps}"),
            # ... no ECN-CE (PFC, not ECN, protects here) ...
            make_check(f"ip_dscp in {lossless_dscps} and ecn_ce_rx != 0",
                    ["flow_name", "port_tx", "port_rx", "ip_dscp", "ecn_ce_rx"],
                    f"Lossless: no ECN-CE {lossless_dscps}",
                    f"ecn_ce_rx == 0 required for lossless DSCPs {lossless_dscps}"),
            # ... no CNP.
            make_check(f"ip_dscp in {lossless_dscps} and (cnp_tx != 0 or cnp_rx != 0)",
                    ["flow_name", "port_tx", "port_rx", "ip_dscp", "cnp_tx", "cnp_rx"],
                    f"Lossless: no CNP {lossless_dscps}",
                    f"cnp_tx == 0 and cnp_rx == 0 required for lossless DSCPs {lossless_dscps}"),
            # PFC pause must be generated by the DUT on EVERY lossless priority.
            make_check(pfc_fail_expr, list(pfc_sum_df.columns),
                    f"DUT generated PFC on every lossless priority {used_lossless}",
                    f"DUT Tx PFC expected on EVERY lossless priority {used_lossless} under incast congestion",
                    override_df=pfc_sum_df),
            # Lossy priorities are unprotected: no PFC should be generated for them.
            make_check(pfc_lossy_fail_expr, list(pfc_lossy_df.columns),
                    f"No PFC on lossy priorities {LOSSY_QUEUES}",
                    f"DUT must NOT generate PFC on lossy priorities {LOSSY_QUEUES} (unprotected)",
                    override_df=pfc_lossy_df),
            # Lossy priorities are unprotected: under incast they SHOULD show loss/
            # failure (contrast with the lossless 0-loss guarantee). Fail if a lossy
            # flow saw no loss AND no failure (i.e. it was effectively protected).
            # Precondition: each lossy Tx offers at 100% line rate into the
            # oversubscribed Rx egress, so loss is guaranteed; this would only
            # false-fail if a lossy flow were never offered (offered rate 0).
            # Only the sender -> Rx direction is congested; return flows (port_tx == Rx)
            # are excluded here and checked for NO loss below.
            make_check(f"ip_dscp in {lossy_dscps} and port_rx == 'Port {rx}' and message_fail == 0 and frame_delta == 0",
                    ["flow_name", "port_tx", "port_rx", "ip_dscp", "message_fail", "frame_delta", "data_frames_rx"],
                    f"Lossy: unprotected, shows loss {lossy_dscps}",
                    f"lossy DSCPs {lossy_dscps} expected to show loss/failure under incast (unprotected)"),
            # Return direction (Rx -> sender) is uncongested: every queue must be loss-free.
            make_check(f"port_tx == 'Port {rx}' and frame_delta != 0",
                    ["flow_name", "port_tx", "port_rx", "ip_dscp", "frame_delta"],
                    "Return flows (Rx -> sender): no loss",
                    "uncongested return direction must have frame_delta=0 on every queue"),
            # DWRR rate fairness at the Rx egress, per QUEUE (weight-proportional split).
            make_check(f"pct_err > {RATE_TOLERANCE_PCT}",
                    ["port_rx", "tc", "weight", "n_flows", "flows", "offered", "rx_rate", "expected_rate", "pct_err"],
                    "DWRR rate matches weight share (per queue)",
                    f"each queue's rate must be within {RATE_TOLERANCE_PCT}% of its weight-proportional expected rate",
                    override_df=rate_check_df),
        ]
        assert_queries(merged_df, checks)
        logger.info(f"*** PFC congestion incast [{scenario}] PASSED ***")
    finally:
        # restore_wred mutates DUT state and MUST run even if stopping traffic/
        # protocols throws, otherwise the lossless queues stay WRED-disabled for
        # every later test on this shared testbed.
        try:
            start_stop(snappi_api, operation="stop", op_type="traffic")
            start_stop(snappi_api, operation="stop", op_type="protocols")
        finally:
            restore_wred(wred_saved)
