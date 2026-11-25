#!/usr/bin/env python3
"""
config_loader.py <config.yaml> [--scope deploy|access|full|show]

Loads and strictly validates run_snappi_test.sh's config.yaml, then emits it
on stdout as shell-safe `CFG_*` variable assignments for `eval` by bash.

config.yaml has exactly two top-level sections:

  deployment:  what this tool stands up (images, STC/DUT/Labserver/OTG,
               sonic-mgmt, report server, cleanup, logging)      -> README §3
  testbed:     how the lab looks to sonic-mgmt and the tests     -> README §4

The loader resolves one effective address per component (STC chassis,
Labserver, OTG service, DUT) and which section owns it: a component this tool
deploys has its address in deployment:, an external one (physical,
provisioned) has it in testbed:. The same value set in both places with
different values is an error.

--scope selects how much of the file is validated (the stages of README §5):
  deploy  deployment: only                       (--deploy-only, --destroy, --list-versions)
  access  + testbed.endpoints.* and, for a physical DUT, mgmt_ip/credentials  (--access-check)
  full    + all of testbed:                      (every test stage; default)
  show    like full, but testbed: problems are warnings (--show-config)

A file in the previous flat layout (images:/testcenter:/dut:/... at the top
level) is detected by schema and migrated in memory with a deprecation
warning. Warnings go to stderr as "WARN: ..." / "INFO: ..." lines; any
schema violation aborts with a non-zero exit and an error list on stderr -
nothing is emitted on stdout on failure.

Test hook: SNAPPI_HOST_IP_OVERRIDE replaces `hostname -I` (an empty value
simulates a failed detection).
"""
import copy
import os
import shlex
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "ERROR: PyYAML is not installed. Install it first (e.g. `python3 -m pip install --user pyyaml`) "
        "or re-run run_snappi_test.sh without --skip-env-check so it can install it.\n"
    )
    sys.exit(2)

USAGE = "usage: config_loader.py <config.yaml> [--scope deploy|access|full|show]\n"
SCOPE_LEVEL = {"deploy": 0, "access": 1, "full": 2, "show": 2}

# Keys that only exist in the previous flat layout.
LEGACY_TOP_KEYS = ("images", "testcenter", "dut", "otg", "sonic_mgmt", "cleanup", "logging", "allure", "topology")
LEGACY_DEPLOYMENT_KEYS = ("mode", "labserver", "otg_service", "stc_chassis", "docker_compose")
LEGACY_TESTBED_KEYS = ("conf_name", "inv_name", "dut_group_name", "server_group")

LOOPBACK = ("127.0.0.1", "localhost")
OTG_DEPLOYED_PORT = 50051  # hard-coded in otg-compose.yaml and the otgctl default
PLACEHOLDER_NOTE = (
    "(config.yaml uses the legacy layout, so key names above are those of the new layout - "
    "run --show-config on a file that loads to print the migrated layout)"
)


# --------------------------------------------------------------------- helpers
class Report:
    """Errors carry the scope level that first needs the key (0 deploy, 1 access, 2 full)."""

    def __init__(self):
        self.errors = []   # (level, message)
        self.notes = []    # (kind, message), kind WARN | INFO

    def err(self, msg, level=0):
        self.errors.append((level, msg))

    def warn(self, msg):
        self.notes.append(("WARN", msg))

    def info(self, msg):
        self.notes.append(("INFO", msg))


def get(d, path, default=None):
    cur = d
    for p in path.split("."):
        if not isinstance(cur, dict) or p not in cur:
            return default
        cur = cur[p]
    return default if cur is None else cur


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def req(rep, d, path, typ=None, nonempty=False, level=0):
    """Walk a dotted path in nested dicts, returning the value or None (and recording an error)."""
    cur = d
    for p in path.split("."):
        if not isinstance(cur, dict) or p not in cur or cur[p] is None:
            rep.err(f"missing required key: {path}", level)
            return None
        cur = cur[p]
    if typ is not None:
        ok = isinstance(cur, typ) and not (typ is int and isinstance(cur, bool))
        if not ok:
            rep.err(f"{path} must be of type {typ.__name__}, got {type(cur).__name__}", level)
            return None
    if nonempty and isinstance(cur, str) and cur.strip() == "":
        rep.err(f"{path} must not be empty", level)
    return cur


def opt(rep, d, path, typ, default, level=0):
    """Optional key: default when absent, type-checked when present."""
    cur = get(d, path)
    if cur is None:
        return default
    ok = isinstance(cur, typ) and not (typ is int and isinstance(cur, bool))
    if not ok:
        rep.err(f"{path} must be of type {typ.__name__}, got {type(cur).__name__}", level)
        return default
    return cur


def detect_host_ip():
    """First address of `hostname -I` ('' when it cannot be determined)."""
    if "SNAPPI_HOST_IP_OVERRIDE" in os.environ:
        return os.environ["SNAPPI_HOST_IP_OVERRIDE"]
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5).stdout.split()
    except Exception:
        return ""
    return out[0] if out else ""


def q(v):
    return shlex.quote(str(v))


def flag(v):
    return "1" if v else "0"


# ---------------------------------------------------------------------- legacy
def legacy_evidence(cfg):
    """Names of keys that exist only in the previous flat layout."""
    found = [k for k in LEGACY_TOP_KEYS if k in cfg]
    dep = cfg.get("deployment")
    if isinstance(dep, dict):
        found += [f"deployment.{k}" for k in LEGACY_DEPLOYMENT_KEYS if k in dep]
    tb = cfg.get("testbed")
    if isinstance(tb, dict):
        found += [f"testbed.{k}" for k in LEGACY_TESTBED_KEYS if k in tb]
    return found


def detect_legacy(cfg):
    """True when the file is in the previous flat layout (decided by schema, not by the
    presence of deployment:/testbed:, which both layouts use)."""
    return bool(legacy_evidence(cfg))


def migrate_legacy(cfg, rep):
    """Map a previous-layout file to the new layout in memory (proposal §2)."""
    g = lambda path, default=None: get(cfg, path, default)  # noqa: E731
    D, T = {}, {}
    new = {"deployment": D, "testbed": T}

    rep.warn(
        "config.yaml uses the legacy flat layout (deprecated, still supported for one more release): "
        "it was migrated in memory to the deployment:/testbed: layout. "
        "Run --show-config to print the migrated layout and copy it into config.yaml."
    )

    # ---- target: testcenter.mode + dut.mode must always agree
    tc_mode = g("testcenter.mode", "virtual")
    dut_mode = g("dut.mode")
    if tc_mode not in ("virtual", "physical"):
        rep.err("testcenter.mode must be 'virtual' or 'physical'")
    if dut_mode is None:
        rep.err("missing required key: dut.mode")
    elif dut_mode not in ("virtual", "physical"):
        rep.err("dut.mode must be 'virtual' or 'physical'")
    if dut_mode in ("virtual", "physical") and tc_mode in ("virtual", "physical") and dut_mode != tc_mode:
        rep.err(
            f"testcenter.mode ({tc_mode!r}) and dut.mode ({dut_mode!r}) must match - "
            "mixed virtual/physical deployments (e.g. a containerized STC chassis cabled to a "
            "physical DUT) are not supported. Set both to 'virtual' or both to 'physical'."
        )
    target = dut_mode if dut_mode in ("virtual", "physical") else (tc_mode if tc_mode in ("virtual", "physical") else "virtual")
    D["target"] = target
    if target == "physical":
        rep.warn(
            "legacy physical lab: testbed.deploy_minigraph now defaults to 'auto', which never pushes a minigraph "
            "to a physical DUT (the legacy layout always pushed it). Set testbed.deploy_minigraph: true to keep "
            "the old behaviour - it OVERWRITES the DUT's running configuration."
        )

    # ---- images, stc
    if g("images.dir") is not None:
        D["images"] = {"dir": g("images.dir")}
    stc = {}
    for new_k, old_k in (("version", "testcenter.version"), ("license_server", "testcenter.license_server")):
        if g(old_k) is not None:
            stc[new_k] = g(old_k)
    D["stc"] = stc

    # ---- Labserver / OTG service
    mode = g("deployment.mode")
    ol = {}
    D["otg_labserver"] = ol
    endpoints = {}
    T["endpoints"] = endpoints
    if mode == "docker-compose":
        ol["docker_compose"] = {"enabled": True, "keep_build_image": g("deployment.docker_compose.keep_build_image", True)}
    elif mode in ("standalone", "provisioned"):
        ol["docker_compose"] = {"enabled": False}
        ol["labserver"] = {"mode": mode}
        ol["otg_service"] = {"mode": mode}
    elif mode is None:
        rep.err("missing required key: deployment.mode")
    else:
        rep.err("deployment.mode must be 'standalone', 'provisioned', or 'docker-compose'")

    lab_ip = g("deployment.labserver.ip", "")
    otg_ip = g("deployment.otg_service.ip", "")
    otg_port = g("deployment.otg_service.port", OTG_DEPLOYED_PORT)
    norm = lambda ip: "" if ip in LOOPBACK else ip  # noqa: E731
    if mode in ("docker-compose", "standalone"):
        a, b = norm(lab_ip), norm(otg_ip)
        if a and b and a != b:
            rep.warn(
                f"deployment.labserver.ip ({a}) and deployment.otg_service.ip ({b}) differ; the new layout has one "
                f"deployment.otg_labserver.host_ip for both - using {a}"
            )
        ol["host_ip"] = a or b
        if otg_port != OTG_DEPLOYED_PORT:
            rep.warn(
                f"deployment.otg_service.port ({otg_port}) ignored: a deployed OTG service always listens on {OTG_DEPLOYED_PORT}"
            )
    elif mode == "provisioned":
        endpoints["labserver_ip"] = lab_ip
        endpoints["otg_service"] = {"ip": otg_ip, "port": otg_port}
    rest_port = g("otg.rest_port")
    if rest_port is not None and rest_port != otg_port:
        rep.warn(
            f"otg.rest_port ({rest_port}) differs from deployment.otg_service.port ({otg_port}) - "
            f"using the service port ({otg_port}) for both"
        )

    # ---- STC chassis address: owned by whoever creates the chassis
    chassis = g("deployment.stc_chassis.ip")
    if chassis is not None:
        if target == "virtual":
            stc["mgmt_ip"] = chassis
        else:
            endpoints["stc_chassis_ip"] = chassis

    # ---- DUT
    dut = g("dut", {}) if isinstance(g("dut", {}), dict) else {}
    dut_vs, tb_dut = {}, {}
    D["dut_vs"] = dut_vs
    T["dut"] = tb_dut
    if target == "virtual":
        for k in ("image", "image_archive", "build_sonic_vs", "download_source", "keep_dut_artifacts", "keep_dut_image"):
            if k in dut:
                dut_vs[k] = dut[k]
    ident = dut_vs if target == "virtual" else tb_dut
    for k in ("hostname", "mgmt_ip", "hwsku", "credentials"):
        if k in dut:
            ident[k] = copy.deepcopy(dut[k])
    for k in ("iface_speed", "total_ports"):
        if k in dut:
            tb_dut[k] = dut[k]
    links = dut.get("links")
    if isinstance(links, list):
        out_links = []
        saw_host_interface = False
        for link in links:
            if isinstance(link, dict):
                link = dict(link)
                if "host_interface" in link:
                    saw_host_interface = True
                    del link["host_interface"]
            out_links.append(link)
        tb_dut["links"] = out_links
        if saw_host_interface:
            rep.warn("dut.links[].host_interface is deprecated and unused - dropped")
    elif "links" in dut:
        tb_dut["links"] = links

    # ---- otg, sonic_mgmt, cleanup, logging, allure, testbed, topology
    if isinstance(g("otg"), dict):
        T["otg"] = {k: copy.deepcopy(v) for k, v in g("otg").items() if k in ("credentials", "ssh_user")}
    for key in ("sonic_mgmt", "cleanup", "logging"):
        if g(key) is not None:
            D[key] = copy.deepcopy(g(key))
    if isinstance(g("allure"), dict):
        D["allure"] = {k: v for k, v in g("allure").items() if k in ("enabled", "host", "ui_port", "api_port")}
        if "project_id" in g("allure"):
            T["reporting"] = {"allure_project_id": g("allure.project_id")}
    if isinstance(g("testbed"), dict):
        T["definition"] = {k: v for k, v in g("testbed").items() if k in LEGACY_TESTBED_KEYS}
    if g("topology") is not None:
        T["topology"] = copy.deepcopy(g("topology"))
    return new


# ------------------------------------------------------- validate and resolve
def resolve(cfg, scope, rep):
    """Validate the new-layout dict `cfg` for `scope` and return the CFG_* values (ordered dict)."""
    maxlvl = SCOPE_LEVEL[scope]
    E = lambda msg, level=0: rep.err(msg, level)  # noqa: E731
    out = {}

    for k in cfg:
        if k not in ("deployment", "testbed"):
            E(f"unknown top-level key: {k} (config.yaml has only the two sections 'deployment' and 'testbed')")
    if not isinstance(cfg.get("deployment"), dict):
        E("missing required key: deployment")
    tb_raw = cfg.get("testbed")
    if tb_raw is not None and not isinstance(tb_raw, dict):
        E("testbed must be a mapping")
        cfg = dict(cfg, testbed={})
    tb = cfg.get("testbed") or {}

    # ---- deployment.target
    target = req(rep, cfg, "deployment.target", str, nonempty=True)
    if target is not None and target not in ("virtual", "physical"):
        E("deployment.target must be 'virtual' or 'physical'")
        target = None
    virtual = target != "physical"
    out["CFG_TARGET"] = target or ""
    out["CFG_TC_MODE"] = target or ""
    out["CFG_DUT_MODE"] = target or ""

    # ---- images / logging / cleanup
    out["CFG_IMAGES_DIR"] = req(rep, cfg, "deployment.images.dir", str, nonempty=True) or ""
    out["CFG_LOG_DIR"] = opt(rep, cfg, "deployment.logging.dir", str, "")
    out["CFG_CLEANUP_ENV_ON_FAILURE"] = flag(opt(rep, cfg, "deployment.cleanup.env_on_failure", bool, False))
    out["CFG_REPLACE_ENV_ON_VERSION_CHANGE"] = flag(opt(rep, cfg, "deployment.cleanup.replace_on_version_change", bool, True))

    # ---- otg_labserver: one switch for the combined stack, else one mode per component
    dc_enabled = opt(rep, cfg, "deployment.otg_labserver.docker_compose.enabled", bool, True)
    host_ip_cfg = opt(rep, cfg, "deployment.otg_labserver.host_ip", str, "")
    if dc_enabled:
        lab_mode = otg_mode = "docker-compose"
        keep = opt(rep, cfg, "deployment.otg_labserver.docker_compose.keep_build_image", bool, True)
        for comp in ("labserver", "otg_service"):
            if get(cfg, f"deployment.otg_labserver.{comp}.mode") is not None:
                rep.info(f"deployment.otg_labserver.{comp}.mode is set but ignored (docker_compose.enabled: true)")
    else:
        keep = True
        lab_mode = req(rep, cfg, "deployment.otg_labserver.labserver.mode", str, nonempty=True)
        otg_mode = req(rep, cfg, "deployment.otg_labserver.otg_service.mode", str, nonempty=True)
        for path, m in (("labserver", lab_mode), ("otg_service", otg_mode)):
            if m is not None and m not in ("standalone", "provisioned"):
                E(f"deployment.otg_labserver.{path}.mode must be 'standalone' or 'provisioned'")
        if get(cfg, "deployment.otg_labserver.docker_compose.keep_build_image") is not None:
            rep.info("deployment.otg_labserver.docker_compose.keep_build_image is set but ignored (docker_compose.enabled: false)")
        lab_mode = lab_mode if lab_mode in ("standalone", "provisioned") else "standalone"
        otg_mode = otg_mode if otg_mode in ("standalone", "provisioned") else "standalone"
    lab_deployed = lab_mode != "provisioned"
    otg_deployed = otg_mode != "provisioned"
    out["CFG_LABSERVER_MODE"] = lab_mode
    out["CFG_OTG_MODE"] = otg_mode
    out["CFG_DOCKER_COMPOSE_KEEP_BUILD_IMAGE"] = flag(keep)

    # ---- stc
    needs_version = virtual or lab_deployed or otg_deployed
    needs_license = virtual or lab_deployed
    version = req(rep, cfg, "deployment.stc.version", str, nonempty=True) if needs_version else get(cfg, "deployment.stc.version", "")
    version = version if isinstance(version, str) else ""
    license_server = req(rep, cfg, "deployment.stc.license_server", str, nonempty=True) if needs_license else get(cfg, "deployment.stc.license_server", "")
    out["CFG_TC_VERSION"] = version
    # Labserver expects an exact match on the STC version (labserver-<version>.tar.xz); OTG service
    # installers are versioned independently, so only the leading major.minor is pinned.
    out["CFG_TC_LABSERVER_VERSION"] = version
    out["CFG_TC_OTGSERVICE_VERSION"] = ".".join(version.split(".")[:2]) if version else ""
    out["CFG_TC_LICENSE_SERVER"] = license_server if isinstance(license_server, str) else ""

    # ---- host address of this machine: used for every component this tool deploys
    host_ip = ""
    if lab_deployed or otg_deployed:
        explicit = host_ip_cfg.strip()
        if explicit and explicit not in LOOPBACK:
            host_ip = explicit
        else:
            detected = detect_host_ip()
            if detected:
                if explicit in LOOPBACK:
                    rep.info(f"deployment.otg_labserver.host_ip is loopback ({explicit}) - resolving to this host's address ({detected})")
                host_ip = detected
            else:
                rep.warn(
                    "this host's address could not be auto-detected (hostname -I) - set "
                    "deployment.otg_labserver.host_ip in config.yaml; falling back to 127.0.0.1, which the "
                    "sonic-mgmt container cannot reach"
                )
                host_ip = "127.0.0.1"
    elif host_ip_cfg.strip():
        rep.info("deployment.otg_labserver.host_ip is set but ignored (Labserver and OTG service are not deployed by this tool)")

    # ---- testbed.endpoints: only for components this tool does not deploy
    ep = lambda path, default=None: get(tb, "endpoints." + path, default)  # noqa: E731

    def conflict(testbed_key, tb_value, dep_key, dep_value, what):
        E(
            f"testbed.{testbed_key} ({tb_value}) conflicts with {dep_key} ({dep_value}): {what} is deployed by this tool, "
            f"so its address is owned by deployment:. Remove the testbed value or make both equal.",
            1,
        )

    # STC chassis
    if virtual:
        chassis_ip = req(rep, cfg, "deployment.stc.mgmt_ip", str, nonempty=True) or ""
        chassis_owner = "deployment"
        v = ep("stc_chassis_ip", "")
        if v and chassis_ip and v != chassis_ip:
            conflict("endpoints.stc_chassis_ip", v, "deployment.stc.mgmt_ip", chassis_ip, "the STC chassis (target: virtual)")
    else:
        chassis_ip = req(rep, cfg, "testbed.endpoints.stc_chassis_ip", str, nonempty=True, level=1) or ""
        chassis_owner = "testbed"
    out["CFG_STC_CHASSIS_IP"] = chassis_ip
    out["CFG_STC_CHASSIS_OWNER"] = chassis_owner

    # Labserver
    if lab_deployed:
        lab_ip, lab_owner = host_ip, "deployment"
        v = ep("labserver_ip", "")
        if v and v != lab_ip:
            conflict("endpoints.labserver_ip", v, "deployment.otg_labserver.host_ip", lab_ip, "the Labserver")
    else:
        # a standalone OTG service is started against this address, so deploy-only needs it too
        lab_ip = req(rep, cfg, "testbed.endpoints.labserver_ip", str, nonempty=True, level=0 if otg_deployed else 1) or ""
        lab_owner = "testbed"
        if virtual:
            rep.warn(
                "target: virtual with a provisioned Labserver: the external Labserver must be able to reach the "
                "virtual STC chassis container address (deployment.stc.mgmt_ip)"
            )
    out["CFG_LABSERVER_IP"] = lab_ip
    out["CFG_LABSERVER_OWNER"] = lab_owner

    # OTG service
    if otg_deployed:
        otg_ip, otg_port, otg_owner = host_ip, OTG_DEPLOYED_PORT, "deployment"
        v = ep("otg_service.ip", "")
        if v and v != otg_ip:
            conflict("endpoints.otg_service.ip", v, "deployment.otg_labserver.host_ip", otg_ip, "the OTG service")
        p = ep("otg_service.port")
        if p is not None and p != OTG_DEPLOYED_PORT:
            E(f"testbed.endpoints.otg_service.port ({p}) conflicts with the fixed port of a deployed OTG service "
              f"({OTG_DEPLOYED_PORT}): remove it", 1)
    else:
        otg_ip = req(rep, cfg, "testbed.endpoints.otg_service.ip", str, nonempty=True, level=1) or ""
        otg_port = ep("otg_service.port", OTG_DEPLOYED_PORT)
        if not is_int(otg_port) or not 1 <= otg_port <= 65535:
            E("testbed.endpoints.otg_service.port must be an integer between 1 and 65535", 1)
            otg_port = OTG_DEPLOYED_PORT
        otg_owner = "testbed"
    out["CFG_OTG_SERVICE_IP"] = otg_ip
    out["CFG_OTG_SERVICE_PORT"] = otg_port
    out["CFG_OTG_REST_PORT"] = otg_port  # always equal to the effective OTG service port
    out["CFG_OTG_SERVICE_OWNER"] = otg_owner

    # ---- DUT: virtual -> deployment.dut_vs, physical -> testbed.dut
    link_count_cfg = None
    if virtual:
        dv = lambda k: get(cfg, "deployment.dut_vs." + k)  # noqa: E731
        req(rep, cfg, "deployment.dut_vs.image", str, nonempty=True)
        hostname = req(rep, cfg, "deployment.dut_vs.hostname", str, nonempty=True) or ""
        mgmt_ip = req(rep, cfg, "deployment.dut_vs.mgmt_ip", str, nonempty=True) or ""
        hwsku = req(rep, cfg, "deployment.dut_vs.hwsku", str, nonempty=True) or ""
        user = req(rep, cfg, "deployment.dut_vs.credentials.user", str, nonempty=True) or ""
        password = req(rep, cfg, "deployment.dut_vs.credentials.password", str, nonempty=True) or ""
        build_vs = opt(rep, cfg, "deployment.dut_vs.build_sonic_vs", bool, True)
        download = opt(rep, cfg, "deployment.dut_vs.download_source", str, "auto")
        if download not in ("auto", "azure", "sonic.software"):
            E("deployment.dut_vs.download_source must be 'auto', 'azure', or 'sonic.software'")
        keep_art = opt(rep, cfg, "deployment.dut_vs.keep_dut_artifacts", bool, True)
        keep_img = opt(rep, cfg, "deployment.dut_vs.keep_dut_image", bool, True)
        archive = opt(rep, cfg, "deployment.dut_vs.image_archive", str, "")
        link_count_cfg = opt(rep, cfg, "deployment.dut_vs.link_count", int, None)
        if link_count_cfg is not None and link_count_cfg < 1:
            E("deployment.dut_vs.link_count must be >= 1")
        dut_owner = "deployment"
        for key, mine in (("hostname", hostname), ("mgmt_ip", mgmt_ip), ("hwsku", hwsku)):
            v = get(tb, "dut." + key, "")
            if v and mine and v != mine:
                E(f"testbed.dut.{key} ({v}) differs from deployment.dut_vs.{key} ({mine}): with target: virtual the DUT "
                  f"is deployed by this tool and inherits these values - omit testbed.dut.{key}", 1)
        for key, mine in (("user", user), ("password", password)):
            v = get(tb, "dut.credentials." + key, "")
            if v and mine and v != mine:
                E(f"testbed.dut.credentials.{key} differs from deployment.dut_vs.credentials.{key}: with target: virtual "
                  f"the DUT inherits them - omit testbed.dut.credentials", 1)
        image, image_archive = dv("image") or "", archive
    else:
        hostname = req(rep, cfg, "testbed.dut.hostname", str, nonempty=True, level=2) or ""
        mgmt_ip = req(rep, cfg, "testbed.dut.mgmt_ip", str, nonempty=True, level=1) or ""
        hwsku = req(rep, cfg, "testbed.dut.hwsku", str, nonempty=True, level=2) or ""
        user = req(rep, cfg, "testbed.dut.credentials.user", str, nonempty=True, level=1) or ""
        password = req(rep, cfg, "testbed.dut.credentials.password", str, nonempty=True, level=1) or ""
        build_vs = download = keep_art = keep_img = None
        dut_owner = "testbed"
        image = image_archive = ""
        ignored = [k for k in ("deployment.dut_vs", "deployment.stc.mgmt_ip") if get(cfg, k) is not None]
        if ignored:
            rep.info(f"{' and '.join(ignored)} set but ignored (target: physical: the chassis and DUT are external; "
                     f"their addresses are testbed.endpoints.stc_chassis_ip / testbed.dut.mgmt_ip)")
    out["CFG_DUT_HOSTNAME"], out["CFG_DUT_MGMT_IP"], out["CFG_DUT_HWSKU"] = hostname, mgmt_ip, hwsku
    out["CFG_DUT_USER"], out["CFG_DUT_PASSWORD"] = user, password
    out["CFG_DUT_OWNER"] = dut_owner
    out["CFG_DUT_IMAGE"], out["CFG_DUT_IMAGE_ARCHIVE"] = image, image_archive
    out["CFG_DUT_BUILD_SONIC_VS"] = flag(build_vs if build_vs is not None else True)
    out["CFG_DUT_DOWNLOAD_SOURCE"] = download or "auto"
    out["CFG_DUT_KEEP_ARTIFACTS"] = flag(keep_art if keep_art is not None else True)
    out["CFG_DUT_KEEP_IMAGE"] = flag(keep_img if keep_img is not None else True)

    # ---- testbed.dut shared by both targets (read from the full scope on)
    out["CFG_DUT_IFACE_SPEED"] = req(rep, cfg, "testbed.dut.iface_speed", str, nonempty=True, level=2) or ""
    total_ports = req(rep, cfg, "testbed.dut.total_ports", int, level=2)
    if isinstance(total_ports, int) and total_ports < 1:
        E("testbed.dut.total_ports must be >= 1", 2)
    out["CFG_DUT_TOTAL_PORTS"] = total_ports if isinstance(total_ports, int) else ""
    links = req(rep, cfg, "testbed.dut.links", list, level=2)
    n_links = 0
    if isinstance(links, list):
        if len(links) < 2:
            E("testbed.dut.links must contain at least 2 entries (the smoke test requires >= 2 ports)", 2)
        for i, link in enumerate(links):
            if not isinstance(link, dict):
                E(f"testbed.dut.links[{i}] must be a mapping", 2)
                continue
            for k in ("dut_port", "stc_port"):
                v = link.get(k, "")
                if not isinstance(v, str) or not v.strip():
                    E(f"testbed.dut.links[{i}].{k} must be a non-empty string", 2)
            for k in ("bandwidth", "vlan_id"):
                if not is_int(link.get(k)):
                    E(f"testbed.dut.links[{i}].{k} must be an integer", 2)
            out[f"CFG_DUT_LINK_{i}_DUT_PORT"] = link.get("dut_port", "")
            out[f"CFG_DUT_LINK_{i}_STC_PORT"] = link.get("stc_port", "")
            out[f"CFG_DUT_LINK_{i}_BANDWIDTH"] = link.get("bandwidth", "")
            out[f"CFG_DUT_LINK_{i}_VLAN_ID"] = link.get("vlan_id", "")
        n_links = len(links)
    elif isinstance(get(tb, "dut.links"), list):
        n_links = len(get(tb, "dut.links"))
    out["CFG_DUT_LINKS_COUNT"] = n_links
    # veth pairs to the virtual chassis: explicit, else the cabling, else 2
    if link_count_cfg is not None and n_links and link_count_cfg != n_links:
        E(f"deployment.dut_vs.link_count ({link_count_cfg}) must equal len(testbed.dut.links) ({n_links}) - or omit link_count", 2)
    out["CFG_CLAB_LINK_COUNT"] = link_count_cfg if link_count_cfg is not None else (n_links or 2)

    # ---- testbed.otg
    out["CFG_OTG_USER"] = req(rep, cfg, "testbed.otg.credentials.user", str, nonempty=True, level=2) or ""
    out["CFG_OTG_PASSWORD"] = req(rep, cfg, "testbed.otg.credentials.password", str, nonempty=True, level=2) or ""
    out["CFG_OTG_SSH_USER"] = opt(rep, cfg, "testbed.otg.ssh_user", str, "", 2)

    # ---- deployment.sonic_mgmt
    source_dir = opt(rep, cfg, "deployment.sonic_mgmt.source_dir", str, "")
    if source_dir.strip() == "":
        req(rep, cfg, "deployment.sonic_mgmt.repo", str, nonempty=True)
        req(rep, cfg, "deployment.sonic_mgmt.branch", str, nonempty=True)
    req(rep, cfg, "deployment.sonic_mgmt.baseline_commit", str, nonempty=True)
    patch_apply = req(rep, cfg, "deployment.sonic_mgmt.patch.apply", bool)
    if patch_apply:
        req(rep, cfg, "deployment.sonic_mgmt.patch.file", str, nonempty=True)
    ct_overwrite = opt(rep, cfg, "deployment.sonic_mgmt.custom_tests.overwrite", bool, False)
    if ct_overwrite:
        req(rep, cfg, "deployment.sonic_mgmt.custom_tests.source_dir", str, nonempty=True)
    out["CFG_SONIC_MGMT_SOURCE_DIR"] = source_dir
    out["CFG_SONIC_MGMT_REPO"] = get(cfg, "deployment.sonic_mgmt.repo", "")
    out["CFG_SONIC_MGMT_BRANCH"] = get(cfg, "deployment.sonic_mgmt.branch", "")
    out["CFG_SONIC_MGMT_BASELINE_COMMIT"] = get(cfg, "deployment.sonic_mgmt.baseline_commit", "")
    out["CFG_SONIC_MGMT_PATCH_APPLY"] = flag(patch_apply)
    out["CFG_SONIC_MGMT_PATCH_FILE"] = get(cfg, "deployment.sonic_mgmt.patch.file", "")
    out["CFG_SONIC_MGMT_CUSTOM_TESTS_OVERWRITE"] = flag(ct_overwrite)
    out["CFG_SONIC_MGMT_CUSTOM_TESTS_DIR"] = get(cfg, "deployment.sonic_mgmt.custom_tests.source_dir", "")
    out["CFG_SONIC_MGMT_KEEP_SRC"] = flag(opt(rep, cfg, "deployment.sonic_mgmt.keep_sonic_mgmt_src", bool, False))

    # ---- allure: report server in deployment, project id in testbed
    allure_enabled = opt(rep, cfg, "deployment.allure.enabled", bool, False)
    if allure_enabled:
        req(rep, cfg, "deployment.allure.ui_port", int)
        req(rep, cfg, "deployment.allure.api_port", int)
        project_id = req(rep, cfg, "testbed.reporting.allure_project_id", str, nonempty=True, level=2) or ""
    else:
        project_id = get(cfg, "testbed.reporting.allure_project_id", "")
    out["CFG_ALLURE_ENABLED"] = flag(allure_enabled)
    out["CFG_ALLURE_HOST"] = opt(rep, cfg, "deployment.allure.host", str, "")
    out["CFG_ALLURE_UI_PORT"] = get(cfg, "deployment.allure.ui_port", "")
    out["CFG_ALLURE_API_PORT"] = get(cfg, "deployment.allure.api_port", "")
    out["CFG_ALLURE_PROJECT_ID"] = project_id if isinstance(project_id, str) else ""

    # ---- testbed.definition / topology
    out["CFG_TESTBED_CONF_NAME"] = req(rep, cfg, "testbed.definition.conf_name", str, nonempty=True, level=2) or ""
    out["CFG_TESTBED_INV_NAME"] = req(rep, cfg, "testbed.definition.inv_name", str, nonempty=True, level=2) or ""
    out["CFG_TESTBED_DUT_GROUP"] = req(rep, cfg, "testbed.definition.dut_group_name", str, nonempty=True, level=2) or ""
    out["CFG_TESTBED_SERVER_GROUP"] = req(rep, cfg, "testbed.definition.server_group", str, nonempty=True, level=2) or ""
    out["CFG_TOPO_NAME"] = req(rep, cfg, "testbed.topology.name", str, nonempty=True, level=2) or ""
    out["CFG_TOPO_DUT_TYPE"] = req(rep, cfg, "testbed.topology.dut_type", str, nonempty=True, level=2) or ""
    vlan_id = req(rep, cfg, "testbed.topology.vlan.id", int, level=2)
    out["CFG_TOPO_VLAN_ID"] = vlan_id if vlan_id is not None else ""
    out["CFG_TOPO_VLAN_PREFIX"] = req(rep, cfg, "testbed.topology.vlan.prefix", str, nonempty=True, level=2) or ""
    out["CFG_TOPO_VLAN_PREFIX_V6"] = req(rep, cfg, "testbed.topology.vlan.prefix_v6", str, nonempty=True, level=2) or ""
    tag = req(rep, cfg, "testbed.topology.vlan.tag", int, level=2)
    out["CFG_TOPO_VLAN_TAG"] = tag if tag is not None else ""
    out["CFG_TOPO_VLAN_MAC"] = req(rep, cfg, "testbed.topology.vlan.mac", str, nonempty=True, level=2) or ""

    # ---- testbed.deploy_minigraph: auto | true | false
    raw = get(tb, "deploy_minigraph", "auto")
    if isinstance(raw, bool):
        mg = "true" if raw else "false"
    elif isinstance(raw, str) and raw.strip().lower() in ("auto", "true", "false"):
        mg = raw.strip().lower()
    else:
        E("testbed.deploy_minigraph must be auto, true or false", 2)
        mg = "auto"
    effective = virtual if mg == "auto" else mg == "true"
    if mg == "true" and not virtual:
        rep.warn(
            f"testbed.deploy_minigraph: true on a physical DUT ({mgmt_ip or 'unset'}): deploy-mg will OVERWRITE its "
            "running configuration. Dedicated lab DUT only, back up its config first."
        )
    out["CFG_DEPLOY_MINIGRAPH"] = mg
    out["CFG_DEPLOY_MINIGRAPH_EFFECTIVE"] = flag(effective)
    return out


# ------------------------------------------------------------------------ main
def usage_error(msg=None):
    if msg:
        sys.stderr.write(f"ERROR: {msg}\n")
    sys.stderr.write(USAGE)
    sys.exit(2)


def main():
    argv = sys.argv[1:]
    scope, path, i = "full", None, 0
    while i < len(argv):
        a = argv[i]
        if a == "--scope":
            if i + 1 >= len(argv):
                usage_error("--scope needs a value")
            scope, i = argv[i + 1], i + 2
        elif a.startswith("--scope="):
            scope, i = a.split("=", 1)[1], i + 1
        elif path is None and not a.startswith("-"):
            path, i = a, i + 1
        else:
            usage_error(f"unexpected argument: {a}")
    if path is None:
        usage_error()
    if scope not in SCOPE_LEVEL:
        usage_error(f"unknown --scope {scope!r} (expected deploy, access, full or show)")

    if not os.path.isfile(path):
        sys.stderr.write(f"ERROR: config file not found: {path}\n")
        sys.exit(2)
    with open(path) as f:
        try:
            cfg = yaml.safe_load(f) or {}
        except yaml.YAMLError as e:
            sys.stderr.write(f"ERROR: failed to parse YAML: {e}\n")
            sys.exit(2)
    if not isinstance(cfg, dict):
        sys.stderr.write("ERROR: top-level config must be a mapping\n")
        sys.exit(2)

    rep = Report()
    legacy = False
    evidence = legacy_evidence(cfg)
    has_target = isinstance(cfg.get("deployment"), dict) and "target" in cfg["deployment"]
    if evidence and has_target:
        # Both layouts use deployment: and testbed:, so a mixed file cannot be interpreted.
        rep.err(
            f"legacy key(s) {', '.join(evidence)} cannot be mixed with the new layout (deployment.target is set). "
            "Move every key to deployment:/testbed: (see the README key map) or remove deployment.target to keep "
            "the legacy layout."
        )
        values = {}
    else:
        if detect_legacy(cfg):
            legacy = True
            cfg = migrate_legacy(cfg, rep)
        values = resolve(cfg, scope, rep)

    maxlvl = SCOPE_LEVEL[scope]
    fatal = []
    demoted_missing = []
    for level, msg in rep.errors:
        if level == 0:
            fatal.append(msg)
        elif scope == "show":
            # --show-config must work on a deploy-only or minimal-access file: testbed:
            # problems are only reported. Missing keys are listed on a single line.
            if msg.startswith("missing required key: "):
                demoted_missing.append(msg.split(": ", 1)[1])
            else:
                rep.warn(f"not valid for the test stages: {msg}")
        elif level <= maxlvl:
            fatal.append(msg)
    if demoted_missing:
        rep.warn("not valid for the test stages - missing required key(s): " + ", ".join(demoted_missing))
    if fatal:
        sys.stderr.write("Config validation failed (%s):\n" % path)
        for msg in fatal:
            sys.stderr.write(f"  - {msg}\n")
        if legacy:
            sys.stderr.write(f"  {PLACEHOLDER_NOTE}\n")
        sys.exit(1)

    for kind, msg in rep.notes:
        sys.stderr.write(f"{kind}: {msg}\n")
    print("\n".join(f"{k}={q(v)}" for k, v in values.items()))


if __name__ == "__main__":
    main()
