#!/usr/bin/env python3
"""
config_loader.py <config.yaml>

Loads and strictly validates run_snappi_test.sh's config.yaml, then emits it
on stdout as shell-safe `CFG_*` variable assignments for `eval` by bash.
Any schema violation aborts with a non-zero exit and a human-readable error
list on stderr - nothing is emitted on failure.
"""
import sys
import os
import shlex

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "ERROR: PyYAML is not installed. Install it first (e.g. `python3 -m pip install --user pyyaml`) "
        "or re-run run_snappi_test.sh without --skip-env-check so it can install it.\n"
    )
    sys.exit(2)

errors = []


def err(msg):
    errors.append(msg)


def require(d, path, typ=None, allow_empty=True):
    """Walk a dotted path in nested dicts, returning the value or None (and recording an error)."""
    cur = d
    parts = path.split(".")
    for p in parts:
        if not isinstance(cur, dict) or p not in cur:
            err(f"missing required key: {path}")
            return None
        cur = cur[p]
    if typ is not None and not isinstance(cur, typ):
        err(f"{path} must be of type {typ.__name__}, got {type(cur).__name__}")
        return None
    if not allow_empty and isinstance(cur, str) and cur.strip() == "":
        err(f"{path} must not be empty")
    return cur


PLACEHOLDER_LICENSE_SERVER = "@license-server.example.com"


def check_license_server(cfg):
    """testcenter.license_server gets its own dedicated, non-aggregated error:
    it's the #1 public-release stumbling block, so it's worth a message that
    stands on its own instead of a one-line bullet buried in the generic list."""
    value = cfg.get("testcenter", {}).get("license_server")
    if isinstance(value, str) and value.strip() and value.strip() != PLACEHOLDER_LICENSE_SERVER:
        return
    sys.stderr.write(
        "Invalid configuration: 'testcenter.license_server'.\n\n"
        f"The value cannot be empty and must not be the default placeholder '{PLACEHOLDER_LICENSE_SERVER}'. "
        "Configure a valid STC license server (for example, '@hostname' or 'host:port').\n\n"
        "For licensing assistance, contact VIAVI Support:\n"
        "https://www.viavisolutions.com/support\n"
    )
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: config_loader.py <config.yaml>\n")
        sys.exit(2)

    cfg_path = sys.argv[1]
    if not os.path.isfile(cfg_path):
        sys.stderr.write(f"ERROR: config file not found: {cfg_path}\n")
        sys.exit(2)

    with open(cfg_path) as f:
        try:
            cfg = yaml.safe_load(f) or {}
        except yaml.YAMLError as e:
            sys.stderr.write(f"ERROR: failed to parse YAML: {e}\n")
            sys.exit(2)

    if not isinstance(cfg, dict):
        sys.stderr.write("ERROR: top-level config must be a mapping\n")
        sys.exit(2)

    # ---- images ----
    require(cfg, "images.dir", str, allow_empty=False)

    # ---- testcenter ----
    # labserver_version and otgservice_version are no longer separate config
    # keys - both are derived from testcenter.version at emit() time (see
    # there for exactly how).
    require(cfg, "testcenter.version", str, allow_empty=False)
    check_license_server(cfg)

    # ---- deployment ----
    mode = require(cfg, "deployment.mode", str, allow_empty=False)
    if mode is not None and mode not in ("standalone", "provisioned", "docker-compose"):
        err("deployment.mode must be 'standalone', 'provisioned', or 'docker-compose'")
    # Optional, default kept out of require() so existing config.yaml files
    # from before docker-compose mode existed keep validating.
    dc_keep_build_image = cfg.get("deployment", {}).get("docker_compose", {}).get("keep_build_image", True)
    if not isinstance(dc_keep_build_image, bool):
        err("deployment.docker_compose.keep_build_image must be a boolean")
    require(cfg, "deployment.labserver.ip", str, allow_empty=False)
    require(cfg, "deployment.otg_service.ip", str, allow_empty=False)
    require(cfg, "deployment.otg_service.port", int)
    require(cfg, "deployment.stc_chassis.ip", str, allow_empty=False)

    # ---- dut ----
    dut_mode = require(cfg, "dut.mode", str, allow_empty=False)
    if dut_mode is not None and dut_mode not in ("virtual", "physical"):
        err("dut.mode must be 'virtual' or 'physical'")
    require(cfg, "dut.hostname", str, allow_empty=False)
    require(cfg, "dut.mgmt_ip", str, allow_empty=False)
    require(cfg, "dut.hwsku", str, allow_empty=False)
    require(cfg, "dut.iface_speed", str, allow_empty=False)
    total_ports = require(cfg, "dut.total_ports", int)
    if isinstance(total_ports, int) and total_ports < 1:
        err("dut.total_ports must be >= 1")
    require(cfg, "dut.credentials.user", str, allow_empty=False)
    require(cfg, "dut.credentials.password", str, allow_empty=False)

    if dut_mode == "virtual":
        require(cfg, "dut.image", str, allow_empty=False)
    # Optional, defaults to True - kept out of require() so existing
    # config.yaml files from before this option existed keep validating.
    build_sonic_vs = cfg.get("dut", {}).get("build_sonic_vs", True)
    if not isinstance(build_sonic_vs, bool):
        err("dut.build_sonic_vs must be a boolean")
    # Optional, default "auto" - kept out of require() so existing config.yaml
    # files from before this option existed keep validating.
    download_source = cfg.get("dut", {}).get("download_source", "auto")
    if download_source not in ("auto", "azure", "sonic.software"):
        err("dut.download_source must be 'auto', 'azure', or 'sonic.software'")
    # Optional, both default to True - kept out of require() so existing
    # config.yaml files from before these options existed keep validating.
    keep_dut_artifacts = cfg.get("dut", {}).get("keep_dut_artifacts", True)
    if not isinstance(keep_dut_artifacts, bool):
        err("dut.keep_dut_artifacts must be a boolean")
    keep_dut_image = cfg.get("dut", {}).get("keep_dut_image", True)
    if not isinstance(keep_dut_image, bool):
        err("dut.keep_dut_image must be a boolean")

    links = require(cfg, "dut.links", list)
    if isinstance(links, list):
        if len(links) < 2:
            err("dut.links must contain at least 2 entries (the smoke test requires >= 2 ports)")
        for i, link in enumerate(links):
            if not isinstance(link, dict):
                err(f"dut.links[{i}] must be a mapping")
                continue
            for k in ("dut_port", "stc_port"):
                v = link.get(k, "")
                if not isinstance(v, str) or not v.strip():
                    err(f"dut.links[{i}].{k} must be a non-empty string")
            for k in ("bandwidth", "vlan_id"):
                if not isinstance(link.get(k), int):
                    err(f"dut.links[{i}].{k} must be an integer")
            if dut_mode == "physical":
                hi = link.get("host_interface", "")
                if not isinstance(hi, str) or not hi.strip():
                    err(
                        f"dut.links[{i}].host_interface is required when dut.mode is 'physical' "
                        "(the host NIC cabled to this STC port, e.g. enp1s0f0)"
                    )

    # ---- otg ----
    require(cfg, "otg.credentials.user", str, allow_empty=False)
    require(cfg, "otg.credentials.password", str, allow_empty=False)
    require(cfg, "otg.rest_port", int)

    # ---- sonic_mgmt ----
    source_dir = cfg.get("sonic_mgmt", {}).get("source_dir", "")
    if not isinstance(source_dir, str):
        err("sonic_mgmt.source_dir must be a string")
        source_dir = ""
    if source_dir.strip() == "":
        require(cfg, "sonic_mgmt.repo", str, allow_empty=False)
        require(cfg, "sonic_mgmt.branch", str, allow_empty=False)
    require(cfg, "sonic_mgmt.baseline_commit", str, allow_empty=False)
    patch_apply = require(cfg, "sonic_mgmt.patch.apply", bool)
    if patch_apply:
        require(cfg, "sonic_mgmt.patch.file", str, allow_empty=False)
    # Optional, defaults to False - kept out of require() so existing
    # config.yaml files from before this option existed keep validating.
    keep_sonic_mgmt_src = cfg.get("sonic_mgmt", {}).get("keep_sonic_mgmt_src", False)
    if not isinstance(keep_sonic_mgmt_src, bool):
        err("sonic_mgmt.keep_sonic_mgmt_src must be a boolean")

    # ---- cleanup ----
    require(cfg, "cleanup.env_on_failure", bool)
    # Optional, defaults to True - kept out of require() so existing
    # config.yaml files from before this option existed keep validating.
    replace_on_version_change = cfg.get("cleanup", {}).get("replace_on_version_change", True)
    if not isinstance(replace_on_version_change, bool):
        err("cleanup.replace_on_version_change must be a boolean")

    # ---- logging ----
    log_dir = cfg.get("logging", {}).get("dir", "")
    if not isinstance(log_dir, str):
        err("logging.dir must be a string")

    # ---- allure ----
    allure_enabled = require(cfg, "allure.enabled", bool)
    if allure_enabled:
        require(cfg, "allure.ui_port", int)
        require(cfg, "allure.api_port", int)
        require(cfg, "allure.project_id", str, allow_empty=False)

    # ---- testbed ----
    require(cfg, "testbed.conf_name", str, allow_empty=False)
    require(cfg, "testbed.inv_name", str, allow_empty=False)
    require(cfg, "testbed.dut_group_name", str, allow_empty=False)
    require(cfg, "testbed.server_group", str, allow_empty=False)

    # ---- topology ----
    require(cfg, "topology.name", str, allow_empty=False)
    require(cfg, "topology.dut_type", str, allow_empty=False)
    require(cfg, "topology.vlan.id", int)
    require(cfg, "topology.vlan.prefix", str, allow_empty=False)
    require(cfg, "topology.vlan.prefix_v6", str, allow_empty=False)
    require(cfg, "topology.vlan.tag", int)
    require(cfg, "topology.vlan.mac", str, allow_empty=False)

    if errors:
        sys.stderr.write("Config validation failed (%s):\n" % cfg_path)
        for e in errors:
            sys.stderr.write(f"  - {e}\n")
        sys.exit(1)

    emit(cfg)


def q(v):
    return shlex.quote(str(v))


def emit(cfg):
    out = []

    def scalar(name, value):
        out.append(f"{name}={q(value)}")

    def get(path, default=""):
        cur = cfg
        for p in path.split("."):
            if not isinstance(cur, dict) or p not in cur:
                return default
            cur = cur[p]
        return cur

    scalar("CFG_IMAGES_DIR", get("images.dir"))
    scalar("CFG_CLEANUP_ENV_ON_FAILURE", "1" if get("cleanup.env_on_failure") else "0")
    scalar("CFG_REPLACE_ENV_ON_VERSION_CHANGE", "1" if get("cleanup.replace_on_version_change", True) else "0")
    scalar("CFG_LOG_DIR", get("logging.dir"))

    # Labserver expects an exact filename match on the STC version
    # (labserver-<version>.tar.xz), so it just reuses testcenter.version
    # as-is. OTG service installers are versioned independently of STC
    # (different patch/build numbering), but are still built and qualified
    # per STC release - so pin only the leading major.minor component (e.g.
    # "5.62" out of "5.62.0766") and let env_check.sh glob-match any
    # otgservice.<major.minor>.*.sh under images.dir.
    tc_version = get("testcenter.version")
    otg_version_prefix = ".".join(str(tc_version).split(".")[:2])

    scalar("CFG_TC_VERSION", tc_version)
    scalar("CFG_TC_LABSERVER_VERSION", tc_version)
    scalar("CFG_TC_OTGSERVICE_VERSION", otg_version_prefix)
    scalar("CFG_TC_LICENSE_SERVER", get("testcenter.license_server"))

    scalar("CFG_DEPLOY_MODE", get("deployment.mode"))
    scalar("CFG_DOCKER_COMPOSE_KEEP_BUILD_IMAGE", "1" if get("deployment.docker_compose.keep_build_image", True) else "0")
    scalar("CFG_LABSERVER_IP", get("deployment.labserver.ip"))
    scalar("CFG_OTG_SERVICE_IP", get("deployment.otg_service.ip"))
    scalar("CFG_OTG_SERVICE_PORT", get("deployment.otg_service.port"))
    scalar("CFG_STC_CHASSIS_IP", get("deployment.stc_chassis.ip"))

    scalar("CFG_DUT_MODE", get("dut.mode"))
    scalar("CFG_DUT_HOSTNAME", get("dut.hostname"))
    scalar("CFG_DUT_MGMT_IP", get("dut.mgmt_ip"))
    scalar("CFG_DUT_HWSKU", get("dut.hwsku"))
    scalar("CFG_DUT_IFACE_SPEED", get("dut.iface_speed"))
    scalar("CFG_DUT_TOTAL_PORTS", get("dut.total_ports"))
    scalar("CFG_DUT_IMAGE", get("dut.image"))
    scalar("CFG_DUT_IMAGE_ARCHIVE", get("dut.image_archive"))
    scalar("CFG_DUT_BUILD_SONIC_VS", "1" if get("dut.build_sonic_vs", True) else "0")
    scalar("CFG_DUT_DOWNLOAD_SOURCE", get("dut.download_source", "auto"))
    scalar("CFG_DUT_KEEP_ARTIFACTS", "1" if get("dut.keep_dut_artifacts", True) else "0")
    scalar("CFG_DUT_KEEP_IMAGE", "1" if get("dut.keep_dut_image", True) else "0")
    scalar("CFG_DUT_USER", get("dut.credentials.user"))
    scalar("CFG_DUT_PASSWORD", get("dut.credentials.password"))

    links = get("dut.links", [])
    scalar("CFG_DUT_LINKS_COUNT", len(links))
    for i, link in enumerate(links):
        scalar(f"CFG_DUT_LINK_{i}_DUT_PORT", link.get("dut_port", ""))
        scalar(f"CFG_DUT_LINK_{i}_STC_PORT", link.get("stc_port", ""))
        scalar(f"CFG_DUT_LINK_{i}_BANDWIDTH", link.get("bandwidth", ""))
        scalar(f"CFG_DUT_LINK_{i}_VLAN_ID", link.get("vlan_id", ""))
        scalar(f"CFG_DUT_LINK_{i}_HOST_IF", link.get("host_interface", ""))

    scalar("CFG_OTG_USER", get("otg.credentials.user"))
    scalar("CFG_OTG_PASSWORD", get("otg.credentials.password"))
    scalar("CFG_OTG_REST_PORT", get("otg.rest_port"))
    scalar("CFG_OTG_SSH_USER", get("otg.ssh_user"))

    scalar("CFG_SONIC_MGMT_SOURCE_DIR", get("sonic_mgmt.source_dir"))
    scalar("CFG_SONIC_MGMT_REPO", get("sonic_mgmt.repo"))
    scalar("CFG_SONIC_MGMT_BRANCH", get("sonic_mgmt.branch"))
    scalar("CFG_SONIC_MGMT_BASELINE_COMMIT", get("sonic_mgmt.baseline_commit"))
    scalar("CFG_SONIC_MGMT_PATCH_APPLY", "1" if get("sonic_mgmt.patch.apply") else "0")
    scalar("CFG_SONIC_MGMT_PATCH_FILE", get("sonic_mgmt.patch.file"))
    scalar("CFG_SONIC_MGMT_KEEP_SRC", "1" if get("sonic_mgmt.keep_sonic_mgmt_src", False) else "0")

    scalar("CFG_ALLURE_ENABLED", "1" if get("allure.enabled") else "0")
    scalar("CFG_ALLURE_HOST", get("allure.host"))
    scalar("CFG_ALLURE_UI_PORT", get("allure.ui_port"))
    scalar("CFG_ALLURE_API_PORT", get("allure.api_port"))
    scalar("CFG_ALLURE_PROJECT_ID", get("allure.project_id"))

    scalar("CFG_TESTBED_CONF_NAME", get("testbed.conf_name"))
    scalar("CFG_TESTBED_INV_NAME", get("testbed.inv_name"))
    scalar("CFG_TESTBED_DUT_GROUP", get("testbed.dut_group_name"))
    scalar("CFG_TESTBED_SERVER_GROUP", get("testbed.server_group"))

    scalar("CFG_TOPO_NAME", get("topology.name"))
    scalar("CFG_TOPO_DUT_TYPE", get("topology.dut_type"))
    scalar("CFG_TOPO_VLAN_ID", get("topology.vlan.id"))
    scalar("CFG_TOPO_VLAN_PREFIX", get("topology.vlan.prefix"))
    scalar("CFG_TOPO_VLAN_PREFIX_V6", get("topology.vlan.prefix_v6"))
    scalar("CFG_TOPO_VLAN_TAG", get("topology.vlan.tag"))
    scalar("CFG_TOPO_VLAN_MAC", get("topology.vlan.mac"))

    print("\n".join(out))


if __name__ == "__main__":
    main()
