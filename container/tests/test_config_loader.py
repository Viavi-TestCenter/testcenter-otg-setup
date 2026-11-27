#!/usr/bin/env python3
"""Tests for lib/config_loader.py (two-section config layout, proposal Option B).

Run:  python3 -m unittest discover -s container/tests -v

The loader is exercised as a subprocess, exactly as config.sh calls it.
SNAPPI_HOST_IP_OVERRIDE is the loader's test hook for `hostname -I`:
set to an address -> that address is "detected"; set to "" -> detection fails.
"""
import copy
import os
import shlex
import subprocess
import sys
import tempfile
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
LOADER = os.path.join(HERE, "..", "lib", "config_loader.py")
HOST = "10.9.8.7"


class Result:
    def __init__(self, rc, out, err):
        self.rc = rc
        self.stderr = err
        self.vars = {}
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                parts = shlex.split(v)
                self.vars[k] = parts[0] if parts else ""


def fixture(name):
    with open(os.path.join(FIX, name)) as f:
        return yaml.safe_load(f)


def run(cfg, scope=None, host=HOST, extra=()):
    """cfg is a fixture file name or a dict. host=None removes the override."""
    with tempfile.TemporaryDirectory() as d:
        if isinstance(cfg, str):
            path = os.path.join(FIX, cfg)
        else:
            path = os.path.join(d, "config.yaml")
            with open(path, "w") as f:
                yaml.safe_dump(cfg, f)
        cmd = [sys.executable, LOADER, path]
        if scope:
            cmd += ["--scope", scope]
        cmd += list(extra)
        env = dict(os.environ)
        env.pop("SNAPPI_HOST_IP_OVERRIDE", None)
        if host is not None:
            env["SNAPPI_HOST_IP_OVERRIDE"] = host
        p = subprocess.run(cmd, capture_output=True, text=True, env=env)
        return Result(p.returncode, p.stdout, p.stderr)


def mutated(name, fn):
    cfg = copy.deepcopy(fixture(name))
    fn(cfg)
    return cfg


class ShippedConfig(unittest.TestCase):
    SHIPPED = os.path.join(HERE, "..", "config.yaml")

    def test_shipped_config_is_valid_for_every_scope(self):
        for scope in ("deploy", "access", "full", "show"):
            with self.subTest(scope=scope):
                r = run(os.path.abspath(self.SHIPPED), scope)
                self.assertEqual(r.rc, 0, r.stderr)

class FlatLayoutRejected(unittest.TestCase):
    def test_old_flat_layout_is_rejected_not_migrated(self):
        r = run({"images": {"dir": "./images"}, "testcenter": {"mode": "virtual"}, "dut": {"mode": "virtual"}})
        self.assertEqual(r.rc, 1)
        self.assertIn("unknown top-level key: images", r.stderr)
        self.assertIn("missing required key: deployment", r.stderr)


class Scopes(unittest.TestCase):
    def test_deploy_only_config_passes_deploy_scope_but_not_full(self):
        self.assertEqual(run("virtual_deploy_only.yaml", "deploy").rc, 0)
        r = run("virtual_deploy_only.yaml", "full")
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.dut.iface_speed", r.stderr)

    def test_default_scope_is_full(self):
        r = run("virtual_deploy_only.yaml")
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.dut.iface_speed", r.stderr)

    def test_unknown_scope_is_a_usage_error(self):
        r = run("virtual_full.yaml", "bogus")
        self.assertEqual(r.rc, 2)
        self.assertIn("scope", r.stderr)
        self.assertIn("bogus", r.stderr)

    def test_example1_deploy_scope_needs_no_testbed(self):
        r = run(mutated("physical_ex1.yaml", lambda c: c.pop("testbed")), "deploy")
        self.assertEqual(r.rc, 0, r.stderr)

    def test_access_scope_requires_chassis_and_dut_keys_for_physical(self):
        r = run(mutated("physical_ex1.yaml", lambda c: c.pop("testbed")), "access")
        self.assertEqual(r.rc, 1)
        for key in ("testbed.endpoints.stc_chassis_ip", "testbed.dut.mgmt_ip",
                    "testbed.dut.credentials.user", "testbed.dut.credentials.password"):
            self.assertIn(key, r.stderr)

    def test_minimal_testbed_passes_access_and_fails_full_naming_missing_keys(self):
        self.assertEqual(run("physical_ex1.yaml", "access").rc, 0)
        r = run("physical_ex1.yaml", "full")
        self.assertEqual(r.rc, 1)
        for key in ("testbed.dut.hostname", "testbed.dut.hwsku", "testbed.dut.iface_speed"):
            self.assertIn(key, r.stderr)

    def test_full_physical_example_passes_full_scope(self):
        r = run("physical_ex1_full.yaml", "full")
        self.assertEqual(r.rc, 0, r.stderr)

    def test_show_scope_demotes_testbed_errors_to_warnings(self):
        r = run("physical_ex1.yaml", "show")
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertIn("testbed.dut.hostname", r.stderr)

    def test_show_scope_lists_all_missing_testbed_keys_on_one_line(self):
        r = run("physical_ex1.yaml", "show")
        lines = [ln for ln in r.stderr.splitlines() if "not valid for the test stages" in ln]
        self.assertEqual(len(lines), 1, r.stderr)
        for key in ("testbed.dut.hostname", "testbed.otg.credentials.user", "testbed.topology.vlan.mac"):
            self.assertIn(key, lines[0])

    def test_show_scope_still_fails_on_deployment_errors(self):
        r = run(mutated("physical_ex1.yaml", lambda c: c["deployment"].pop("target")), "show")
        self.assertEqual(r.rc, 1)
        self.assertIn("deployment.target", r.stderr)


class VersionAndLicense(unittest.TestCase):
    def test_stc_version_required_when_a_labserver_is_deployed(self):
        r = run(mutated("physical_ex1.yaml", lambda c: c["deployment"]["stc"].pop("version")), "deploy")
        self.assertEqual(r.rc, 1)
        self.assertIn("deployment.stc.version", r.stderr)

    def test_license_server_value_is_a_run_mode_rule_not_a_loader_requirement(self):
        # proposal §4 item 5: the license check "stays in run_snappi_test.sh as today, gated by run
        # mode" (tests/test_license_gate.sh). The loader must not block --destroy, --pretest,
        # --access-check, ... of a config that simply has no license_server.
        for fixture_name, scope in (("physical_ex1.yaml", "deploy"), ("virtual_full.yaml", "full")):
            with self.subTest(fixture=fixture_name):
                cfg = mutated(fixture_name, lambda c: c["deployment"]["stc"].pop("license_server"))
                r = run(cfg, scope)
                self.assertEqual(r.rc, 0, r.stderr)
                self.assertEqual(r.vars["CFG_TC_LICENSE_SERVER"], "")

    def test_license_server_must_be_a_string_when_present(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["deployment"]["stc"].update(license_server=12345))
        r = run(cfg)
        self.assertEqual(r.rc, 1)
        self.assertIn("deployment.stc.license_server", r.stderr)

    def test_license_server_not_required_for_provisioned_labserver_on_physical(self):
        r = run("physical_ex2.yaml", "access")
        self.assertEqual(r.rc, 0, r.stderr)

    def test_example3_needs_no_stc_block(self):
        r = run("physical_ex3.yaml", "access")
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_TC_VERSION"], "")

    def test_otg_version_is_the_major_minor_of_the_stc_version(self):
        r = run("physical_ex1.yaml", "access")
        self.assertEqual(r.vars["CFG_TC_VERSION"], "5.62.0766")
        self.assertEqual(r.vars["CFG_TC_LABSERVER_VERSION"], "5.62.0766")
        self.assertEqual(r.vars["CFG_TC_OTGSERVICE_VERSION"], "5.62")


class OwnersAndAddresses(unittest.TestCase):
    def test_example1_modes_owners_and_addresses(self):
        v = run("physical_ex1.yaml", "access").vars
        self.assertEqual((v["CFG_TARGET"], v["CFG_TC_MODE"], v["CFG_DUT_MODE"]),
                         ("physical", "physical", "physical"))
        self.assertEqual((v["CFG_LABSERVER_MODE"], v["CFG_OTG_MODE"]),
                         ("docker-compose", "docker-compose"))
        self.assertEqual(v["CFG_STC_CHASSIS_OWNER"], "testbed")
        self.assertEqual(v["CFG_DUT_OWNER"], "testbed")
        self.assertEqual(v["CFG_LABSERVER_OWNER"], "deployment")
        self.assertEqual(v["CFG_OTG_SERVICE_OWNER"], "deployment")
        self.assertEqual(v["CFG_STC_CHASSIS_IP"], "10.0.0.20")
        self.assertEqual(v["CFG_DUT_MGMT_IP"], "10.0.0.30")
        self.assertEqual(v["CFG_LABSERVER_IP"], HOST)
        self.assertEqual(v["CFG_OTG_SERVICE_IP"], HOST)
        self.assertEqual(v["CFG_OTG_SERVICE_PORT"], "50051")
        self.assertEqual(v["CFG_OTG_REST_PORT"], "50051")

    def test_example2_standalone_otg_against_provisioned_labserver(self):
        v = run("physical_ex2.yaml", "access").vars
        self.assertEqual((v["CFG_LABSERVER_MODE"], v["CFG_OTG_MODE"]), ("provisioned", "standalone"))
        self.assertEqual(v["CFG_LABSERVER_IP"], "10.0.0.21")
        self.assertEqual(v["CFG_LABSERVER_OWNER"], "testbed")
        self.assertEqual(v["CFG_OTG_SERVICE_IP"], HOST)
        self.assertEqual(v["CFG_OTG_SERVICE_OWNER"], "deployment")

    def test_example2_deploy_scope_reads_labserver_ip_from_testbed(self):
        self.assertEqual(run("physical_ex2.yaml", "deploy").rc, 0)
        no_ip = mutated("physical_ex2.yaml", lambda c: c["testbed"]["endpoints"].pop("labserver_ip"))
        r = run(no_ip, "deploy")
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.endpoints.labserver_ip", r.stderr)
        r = run(mutated("physical_ex2.yaml", lambda c: c.pop("testbed")), "deploy")
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.endpoints.labserver_ip", r.stderr)

    def test_example3_provisioned_otg_port_drives_both_port_variables(self):
        v = run("physical_ex3.yaml", "access").vars
        self.assertEqual((v["CFG_LABSERVER_MODE"], v["CFG_OTG_MODE"]), ("provisioned", "provisioned"))
        self.assertEqual(v["CFG_OTG_SERVICE_IP"], "10.0.0.22")
        self.assertEqual(v["CFG_OTG_SERVICE_PORT"], "50051")
        cfg = mutated("physical_ex3.yaml", lambda c: c["testbed"]["endpoints"]["otg_service"].update(port=50052))
        v = run(cfg, "access").vars
        self.assertEqual((v["CFG_OTG_SERVICE_PORT"], v["CFG_OTG_REST_PORT"]), ("50052", "50052"))

    def test_provisioned_otg_requires_an_ip_from_access_scope(self):
        cfg = mutated("physical_ex3.yaml", lambda c: c["testbed"]["endpoints"].pop("otg_service"))
        r = run(cfg, "access")
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.endpoints.otg_service.ip", r.stderr)

    def test_virtual_chassis_conflict_is_an_error_but_equal_value_is_fine(self):
        def conflict(c):
            c["testbed"]["endpoints"] = {"stc_chassis_ip": "10.1.1.1"}
        r = run(mutated("virtual_full.yaml", conflict))
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.endpoints.stc_chassis_ip", r.stderr)
        self.assertIn("deployment.stc.mgmt_ip", r.stderr)

        def same(c):
            c["testbed"]["endpoints"] = {"stc_chassis_ip": "192.168.1.2"}
        self.assertEqual(run(mutated("virtual_full.yaml", same)).rc, 0)

    def test_virtual_dut_values_in_testbed_must_match_deployment(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["testbed"]["dut"].update(hostname="other-dut"))
        r = run(cfg)
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.dut.hostname", r.stderr)

    def test_deployed_service_address_in_testbed_conflicts_with_host_ip(self):
        def f(c):
            c["testbed"]["endpoints"]["labserver_ip"] = "10.5.5.5"
        r = run(mutated("physical_ex1.yaml", f), "access")
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.endpoints.labserver_ip", r.stderr)


class HostIp(unittest.TestCase):
    def test_loopback_and_empty_host_ip_resolve_to_the_detected_address(self):
        for value in ("127.0.0.1", "localhost", ""):
            with self.subTest(host_ip=value):
                cfg = mutated("virtual_full.yaml", lambda c: c["deployment"]["otg_labserver"].update(host_ip=value))
                v = run(cfg).vars
                self.assertEqual(v["CFG_LABSERVER_IP"], HOST)
                self.assertEqual(v["CFG_OTG_SERVICE_IP"], HOST)

    def test_explicit_loopback_logs_an_info_line(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["deployment"]["otg_labserver"].update(host_ip="127.0.0.1"))
        self.assertIn("loopback", run(cfg).stderr)

    def test_explicit_host_ip_is_used_as_is(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["deployment"]["otg_labserver"].update(host_ip="10.1.2.3"))
        self.assertEqual(run(cfg).vars["CFG_LABSERVER_IP"], "10.1.2.3")

    def test_failed_detection_warns_and_keeps_loopback(self):
        r = run("virtual_full.yaml", host="")
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_LABSERVER_IP"], "127.0.0.1")
        self.assertIn("could not be auto-detected", r.stderr)
        self.assertIn("deployment.otg_labserver.host_ip", r.stderr)


class LoopbackServices(unittest.TestCase):
    """Review I1/M7: the base resolved a loopback Labserver/OTG address in EVERY mode (the sonic-mgmt
    container and otgctl cannot reach this host through loopback); an external (provisioned) service
    written as 127.0.0.1/localhost must still get this host's real address."""

    def test_provisioned_loopback_services_resolve_to_this_host(self):
        def f(c):
            c["testbed"]["endpoints"]["labserver_ip"] = "localhost"
            c["testbed"]["endpoints"]["otg_service"]["ip"] = "127.0.1.1"
        r = run(mutated("physical_ex3.yaml", f), "access")
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_LABSERVER_IP"], HOST)
        self.assertEqual(r.vars["CFG_OTG_SERVICE_IP"], HOST)

    def test_every_loopback_spelling_is_recognised(self):
        for value in ("LOCALHOST", "Localhost", "127.0.1.1", "127.1.2.3", "::1"):
            with self.subTest(host_ip=value):
                cfg = mutated("virtual_full.yaml", lambda c: c["deployment"]["otg_labserver"].update(host_ip=value))
                self.assertEqual(run(cfg).vars["CFG_LABSERVER_IP"], HOST)

    def test_a_real_provisioned_address_is_used_as_is(self):
        self.assertEqual(run("physical_ex3.yaml", "access").vars["CFG_LABSERVER_IP"], "10.0.0.21")

    def test_failed_detection_keeps_a_provisioned_loopback_and_warns(self):
        cfg = mutated("physical_ex3.yaml", lambda c: c["testbed"]["endpoints"].update(labserver_ip="127.0.0.1"))
        r = run(cfg, "access", host="")
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_LABSERVER_IP"], "127.0.0.1")
        self.assertIn("could not be auto-detected", r.stderr)

    def test_chassis_and_dut_addresses_are_never_rewritten(self):
        cfg = mutated("physical_ex3.yaml", lambda c: c["testbed"]["endpoints"].update(stc_chassis_ip="127.0.0.1"))
        self.assertEqual(run(cfg, "access").vars["CFG_STC_CHASSIS_IP"], "127.0.0.1")


class UnknownKeys(unittest.TestCase):
    """Review M10: a typo under a known section must not be silently ignored (it falls back to a
    default, e.g. docker_compose.enabled: true would deploy a Labserver next to a provisioned one)."""

    def test_shipped_config_and_every_new_layout_fixture_have_no_unknown_key_warnings(self):
        names = ["virtual_full.yaml", "virtual_deploy_only.yaml", "physical_ex1.yaml", "physical_ex1_full.yaml",
                 "physical_ex2.yaml", "physical_ex3.yaml", os.path.abspath(os.path.join(HERE, "..", "config.yaml"))]
        for name in names:
            with self.subTest(file=os.path.basename(name)):
                self.assertNotIn("unknown key", run(name, "show").stderr)

    def test_typo_under_docker_compose_is_warned_with_a_suggestion(self):
        cfg = mutated("virtual_full.yaml",
                      lambda c: c["deployment"]["otg_labserver"].update(docker_compose={"enable": False}))
        r = run(cfg)
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertIn("unknown key deployment.otg_labserver.docker_compose.enable", r.stderr)
        self.assertIn("did you mean 'enabled'", r.stderr)

    def test_typo_in_testbed_is_warned(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["testbed"]["dut"].update(iface_spead="40000"))
        self.assertIn("unknown key testbed.dut.iface_spead", run(cfg).stderr)

    def test_unknown_key_in_a_link_entry_is_warned(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["testbed"]["dut"]["links"][0].update(host_interface=""))
        self.assertIn("unknown key testbed.dut.links[0].host_interface", run(cfg).stderr)

    def test_unknown_keys_are_warnings_never_errors(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["deployment"].update(not_a_key=1))
        self.assertEqual(run(cfg).rc, 0)


class DeployMinigraph(unittest.TestCase):
    def test_auto_is_push_for_virtual_and_never_for_physical(self):
        self.assertEqual(run("virtual_full.yaml").vars["CFG_DEPLOY_MINIGRAPH_EFFECTIVE"], "1")
        self.assertEqual(run("physical_ex1_full.yaml").vars["CFG_DEPLOY_MINIGRAPH_EFFECTIVE"], "0")

    def test_explicit_true_on_physical_is_honoured_with_a_warning(self):
        cfg = mutated("physical_ex1_full.yaml", lambda c: c["testbed"].update(deploy_minigraph=True))
        r = run(cfg)
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_DEPLOY_MINIGRAPH_EFFECTIVE"], "1")
        self.assertIn("overwrite", r.stderr.lower())

    def test_explicit_false_on_virtual_never_pushes(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["testbed"].update(deploy_minigraph=False))
        self.assertEqual(run(cfg).vars["CFG_DEPLOY_MINIGRAPH_EFFECTIVE"], "0")

    def test_invalid_value_is_rejected(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["testbed"].update(deploy_minigraph="maybe"))
        r = run(cfg)
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.deploy_minigraph", r.stderr)


class LinkCountAndAllure(unittest.TestCase):
    def test_link_count_is_derived_from_links_else_two(self):
        self.assertEqual(run("virtual_full.yaml").vars["CFG_CLAB_LINK_COUNT"], "2")
        self.assertEqual(run("virtual_full.yaml").vars["CFG_DUT_LINKS_COUNT"], "2")
        v = run("virtual_deploy_only.yaml", "deploy").vars
        self.assertEqual(v["CFG_CLAB_LINK_COUNT"], "2")
        self.assertEqual(v["CFG_DUT_LINKS_COUNT"], "0")

    def test_explicit_link_count_drives_deploy_only_and_must_match_links_in_full(self):
        cfg = mutated("virtual_deploy_only.yaml", lambda c: c["deployment"]["dut_vs"].update(link_count=3))
        self.assertEqual(run(cfg, "deploy").vars["CFG_CLAB_LINK_COUNT"], "3")
        cfg = mutated("virtual_full.yaml", lambda c: c["deployment"]["dut_vs"].update(link_count=3))
        r = run(cfg, "full")
        self.assertEqual(r.rc, 1)
        self.assertIn("link_count", r.stderr)

    def test_license_managed_externally_defaults_off_and_is_a_bool(self):
        self.assertEqual(run("virtual_full.yaml").vars["CFG_LICENSE_MANAGED_EXTERNALLY"], "0")
        cfg = mutated("virtual_full.yaml", lambda c: c["deployment"]["stc"].update(license_managed_externally=True))
        self.assertEqual(run(cfg).vars["CFG_LICENSE_MANAGED_EXTERNALLY"], "1")
        cfg = mutated("virtual_full.yaml", lambda c: c["deployment"]["stc"].update(license_managed_externally="yes"))
        r = run(cfg)
        self.assertEqual(r.rc, 1)
        self.assertIn("license_managed_externally", r.stderr)

    def test_allure_is_off_by_default(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["deployment"].update(allure={}))
        self.assertEqual(run(cfg).vars["CFG_ALLURE_ENABLED"], "0")

    def test_allure_project_id_is_required_in_testbed_when_enabled(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["testbed"].pop("reporting"))
        r = run(cfg, "full")
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.reporting.allure_project_id", r.stderr)


class ComposeProvisionedConflict(unittest.TestCase):
    """docker_compose.enabled: true deploys BOTH services, so a service explicitly marked
    provisioned would be silently ignored while a local stack is deployed: rejected up front."""
    ENABLED = "deployment.otg_labserver.docker_compose.enabled is true"
    LAB = 'deployment.otg_labserver.labserver.mode is "provisioned"'
    OTG = 'deployment.otg_labserver.otg_service.mode is "provisioned"'

    @staticmethod
    def compose(**modes):
        def fn(c):
            og = c["deployment"]["otg_labserver"]
            og["docker_compose"] = {"enabled": True, "keep_build_image": True}
            for comp, mode in modes.items():
                og[comp] = {"mode": mode}
        return mutated("virtual_full.yaml", fn)

    def rejected(self, cfg, scope="full"):
        r = run(cfg, scope)
        self.assertEqual(r.rc, 1, r.stderr)
        self.assertEqual(r.vars, {}, "a rejected config must print no CFG_* assignments")
        return r.stderr

    def test_shipped_defaults_are_allowed(self):
        # the shipped file carries mode: standalone under compose; present but inactive is fine
        shipped = os.path.abspath(ShippedConfig.SHIPPED)
        for scope in ("deploy", "access", "full", "show"):
            with self.subTest(scope=scope):
                self.assertEqual(run(shipped, scope).rc, 0)
        with open(shipped) as f:
            cfg = yaml.safe_load(f)
        og = cfg["deployment"]["otg_labserver"]
        self.assertTrue(og["docker_compose"]["enabled"])
        self.assertEqual((og["labserver"]["mode"], og["otg_service"]["mode"]), ("standalone", "standalone"))

    def test_compose_with_no_mode_keys_is_allowed(self):
        self.assertEqual(run("virtual_full.yaml").rc, 0)

    def test_compose_with_standalone_modes_is_allowed(self):
        r = run(self.compose(labserver="standalone", otg_service="standalone"))
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual((r.vars["CFG_LABSERVER_MODE"], r.vars["CFG_OTG_MODE"]), ("docker-compose", "docker-compose"))

    def test_compose_with_provisioned_labserver_is_rejected(self):
        err = self.rejected(self.compose(labserver="provisioned"))
        self.assertIn(self.ENABLED, err)
        self.assertIn(self.LAB, err)
        self.assertNotIn(self.OTG, err)
        self.assertIn("Set docker_compose.enabled to false to use a provisioned Labserver.", err)

    def test_compose_with_provisioned_otg_is_rejected(self):
        err = self.rejected(self.compose(otg_service="provisioned"))
        self.assertIn(self.ENABLED, err)
        self.assertIn(self.OTG, err)
        self.assertNotIn(self.LAB, err)
        self.assertIn("Set docker_compose.enabled to false to use a provisioned OTG service.", err)

    def test_compose_with_both_provisioned_is_rejected_once_naming_both(self):
        err = self.rejected(self.compose(labserver="provisioned", otg_service="provisioned"))
        self.assertIn(self.ENABLED, err)
        self.assertIn(self.LAB, err)
        self.assertIn(self.OTG, err)
        self.assertIn("Set docker_compose.enabled to false to use provisioned services.", err)
        self.assertEqual(err.count("  - "), 1, err)

    def test_compose_default_on_is_named_as_the_default(self):
        # no docker_compose key at all: enabled defaults to true, so the conflict is just as real
        def fn(c):
            og = c["deployment"]["otg_labserver"]
            og.pop("docker_compose", None)
            og["labserver"] = {"mode": "provisioned"}
        err = self.rejected(mutated("virtual_full.yaml", fn))
        self.assertIn(self.ENABLED + " (default)", err)
        self.assertIn(self.LAB, err)

    def test_rejected_in_every_scope(self):
        cfg = self.compose(labserver="provisioned")
        for scope in ("deploy", "access", "full", "show"):
            with self.subTest(scope=scope):
                self.assertIn(self.LAB, self.rejected(cfg, scope))

    def test_mode_spelling_does_not_hide_the_conflict(self):
        self.assertIn(self.LAB, self.rejected(self.compose(labserver=" Provisioned ")))

    def test_the_conflict_is_the_only_error(self):
        # the config is otherwise valid: nothing else (e.g. missing testbed.endpoints addresses
        # for the "provisioned" service) is reported on top of it
        err = self.rejected(self.compose(labserver="provisioned", otg_service="provisioned"))
        self.assertNotIn("testbed.endpoints", err)
        self.assertEqual(err.count("  - "), 1, err)

    def test_compose_disabled_with_provisioned_services_is_allowed(self):
        for scope in ("deploy", "access"):   # the fixture has no full testbed: section
            with self.subTest(scope=scope):
                r = run("physical_ex3.yaml", scope)
                self.assertEqual(r.rc, 0, r.stderr)
        v = run("physical_ex3.yaml", "access").vars
        self.assertEqual((v["CFG_LABSERVER_MODE"], v["CFG_OTG_MODE"]), ("provisioned", "provisioned"))

    def test_compose_disabled_with_provisioned_services_on_a_virtual_lab_is_allowed(self):
        def fn(c):
            c["deployment"]["otg_labserver"] = {
                "docker_compose": {"enabled": False},
                "labserver": {"mode": "provisioned"},
                "otg_service": {"mode": "provisioned"},
            }
            c["testbed"]["endpoints"] = {"labserver_ip": "10.0.0.21", "otg_service": {"ip": "10.0.0.22", "port": 50051}}
        r = run(mutated("virtual_full.yaml", fn), "full")
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual((r.vars["CFG_LABSERVER_MODE"], r.vars["CFG_OTG_MODE"]), ("provisioned", "provisioned"))

    def test_compose_disabled_with_mixed_modes_is_allowed(self):
        self.assertEqual(run("physical_ex2.yaml", "access").rc, 0)


class TopologyValidation(unittest.TestCase):
    """The few topology rules the supported pretest/smoke-test workflow depends on. Errors name the
    config path and value; they apply from --gen-config on (scope full), i.e. before pytest starts."""

    @staticmethod
    def cfg(fn=None):
        def apply(c):
            if fn:
                fn(c["testbed"])
        return mutated("virtual_full.yaml", apply)

    @staticmethod
    def links(*entries):
        def fn(tb):
            tb["dut"]["links"] = [dict(bandwidth=40000, **e) for e in entries]
        return fn

    def rejected(self, fn, scope="full"):
        r = run(self.cfg(fn), scope)
        self.assertEqual(r.rc, 1, r.stderr)
        self.assertEqual(r.vars, {}, "a rejected config must print no CFG_* assignments")
        return r.stderr

    def errors(self, err):
        return [line for line in err.splitlines() if line.startswith("  - ")]

    # ---- valid
    def test_valid_two_link_config_passes(self):
        r = run(self.cfg(), "full")
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_DUT_LINKS_COUNT"], "2")

    def test_more_than_two_unique_links_pass(self):
        fn = self.links(
            dict(dut_port="Ethernet0", stc_port="Card1/Port1", vlan_id=1000),
            dict(dut_port="Ethernet4", stc_port="Card1/Port2", vlan_id=1000),
            dict(dut_port="Ethernet8", stc_port="Card1/Port3", vlan_id=1000),
        )
        r = run(self.cfg(fn), "full")
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_DUT_LINKS_COUNT"], "3")

    def test_tgen_prefix_variants_pass(self):
        for name in ("tgen_ptf32", "tgen-t0-3", "tgen"):
            with self.subTest(name=name):
                r = run(self.cfg(lambda tb, n=name: tb["topology"].update(name=n)), "full")
                self.assertEqual(r.rc, 0, r.stderr)

    # ---- minimum link count
    def test_one_link_is_rejected(self):
        err = self.rejected(self.links(dict(dut_port="Ethernet0", stc_port="Card1/Port1", vlan_id=1000)))
        self.assertIn("At least two testbed.dut.links entries are required by the smoke-test workflow", err)
        self.assertIn("found 1", err)

    def test_no_links_is_rejected(self):
        err = self.rejected(self.links())
        self.assertIn("At least two testbed.dut.links entries are required by the smoke-test workflow", err)
        self.assertIn("found 0", err)

    # ---- VLAN consistency
    def test_vlan_tag_differing_from_id_is_rejected_with_both_paths_and_values(self):
        err = self.rejected(lambda tb: tb["topology"]["vlan"].update(tag=2000))
        self.assertIn("testbed.topology.vlan.id = 1000", err)
        self.assertIn("testbed.topology.vlan.tag = 2000", err)
        self.assertNotIn("testbed.dut.links[0].vlan_id", err)   # only the conflicting paths
        self.assertIn("one VLAN", err)

    def test_link_vlan_differing_from_topology_vlan_is_rejected(self):
        def fn(tb):
            tb["dut"]["links"][1]["vlan_id"] = 2000
        err = self.rejected(fn)
        self.assertIn("testbed.topology.vlan.id = 1000", err)
        self.assertIn("testbed.dut.links[1].vlan_id = 2000", err)
        self.assertNotIn("testbed.dut.links[0].vlan_id", err)

    def test_every_conflicting_path_is_listed_in_one_error(self):
        def fn(tb):
            tb["topology"]["vlan"]["tag"] = 2000
            tb["dut"]["links"][0]["vlan_id"] = 3000
        err = self.rejected(fn)
        for want in ("testbed.topology.vlan.id = 1000", "testbed.topology.vlan.tag = 2000", "testbed.dut.links[0].vlan_id = 3000"):
            self.assertIn(want, err)
        self.assertNotIn("testbed.dut.links[1].vlan_id", err)
        self.assertEqual(len(self.errors(err)), 1, err)

    def test_changing_the_vlan_everywhere_is_consistent(self):
        def fn(tb):
            tb["topology"]["vlan"].update(id=2000, tag=2000)
            for link in tb["dut"]["links"]:
                link["vlan_id"] = 2000
        self.assertEqual(run(self.cfg(fn), "full").rc, 0)

    def test_wrongly_typed_vlan_values_get_a_type_error_not_a_vlan_conflict(self):
        err = self.rejected(lambda tb: tb["topology"]["vlan"].update(tag="1000"))
        self.assertIn("testbed.topology.vlan.tag must be of type int", err)
        self.assertNotIn("one VLAN", err)

    # ---- duplicate ports
    def test_duplicate_dut_port_is_rejected(self):
        def fn(tb):
            tb["dut"]["links"][1]["dut_port"] = "Ethernet0"
        err = self.rejected(fn)
        self.assertIn('testbed.dut.links[1].dut_port ("Ethernet0") is also testbed.dut.links[0].dut_port', err)
        self.assertIn("each DUT port can be cabled to one STC port only", err)

    def test_duplicate_stc_port_is_rejected(self):
        def fn(tb):
            tb["dut"]["links"][1]["stc_port"] = "Card1/Port1"
        err = self.rejected(fn)
        self.assertIn('testbed.dut.links[1].stc_port ("Card1/Port1") is also testbed.dut.links[0].stc_port', err)
        self.assertIn("each STC port can be cabled to one DUT port only", err)

    def test_duplicates_are_found_among_more_than_two_links(self):
        fn = self.links(
            dict(dut_port="Ethernet0", stc_port="Card1/Port1", vlan_id=1000),
            dict(dut_port="Ethernet4", stc_port="Card1/Port2", vlan_id=1000),
            dict(dut_port=" Ethernet0 ", stc_port="Card1/Port3", vlan_id=1000),
        )
        self.assertIn('testbed.dut.links[2].dut_port ("Ethernet0") is also testbed.dut.links[0].dut_port', self.rejected(fn))

    def test_duplicate_detection_ignores_surrounding_spaces_on_either_entry(self):
        fn = self.links(
            dict(dut_port=" Ethernet0 ", stc_port="Card1/Port1", vlan_id=1000),
            dict(dut_port="Ethernet0", stc_port="Card1/Port2", vlan_id=1000),
        )
        self.assertIn('testbed.dut.links[1].dut_port ("Ethernet0") is also testbed.dut.links[0].dut_port', self.rejected(fn))

    def test_a_dut_port_and_an_stc_port_with_the_same_text_are_not_duplicates(self):
        fn = self.links(
            dict(dut_port="Ethernet0", stc_port="Ethernet4", vlan_id=1000),
            dict(dut_port="Ethernet4", stc_port="Ethernet0", vlan_id=1000),
        )
        self.assertEqual(run(self.cfg(fn), "full").rc, 0)

    # ---- topology name
    def test_topology_name_without_tgen_prefix_is_rejected(self):
        err = self.rejected(lambda tb: tb["topology"].update(name="ptf32_snappi"))
        self.assertIn('testbed.topology.name ("ptf32_snappi") must start with "tgen"', err)
        self.assertIn("sonic-mgmt derives the topology type from this name", err)

    def test_topology_name_prefix_is_case_sensitive(self):
        self.assertIn('testbed.topology.name ("Tgen_ptf32") must start with "tgen"',
                      self.rejected(lambda tb: tb["topology"].update(name="Tgen_ptf32")))

    # ---- scope: all of these are test-stage rules
    def test_not_enforced_by_deploy_only_or_access_check(self):
        def fn(tb):
            tb["topology"]["name"] = "ptf32"
            tb["topology"]["vlan"]["tag"] = 2000
            tb["dut"]["links"][1]["dut_port"] = "Ethernet0"
        for scope in ("deploy", "access"):
            with self.subTest(scope=scope):
                self.assertEqual(run(self.cfg(fn), scope).rc, 0)

    def test_show_config_reports_them_as_warnings(self):
        r = run(self.cfg(lambda tb: tb["topology"].update(name="ptf32")), "show")
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertIn("must start with", r.stderr)

    def test_all_problems_are_reported_together(self):
        def fn(tb):
            tb["topology"]["name"] = "ptf32"
            tb["topology"]["vlan"]["tag"] = 2000
            tb["dut"]["links"][1]["dut_port"] = "Ethernet0"
            tb["dut"]["links"][1]["stc_port"] = "Card1/Port1"
        err = self.rejected(fn)
        self.assertEqual(len(self.errors(err)), 4, err)

    # ---- what is deliberately NOT checked
    def test_port_naming_speed_and_inventory_are_not_validated(self):
        def fn(tb):
            tb["dut"]["iface_speed"] = "100000"          # not matched against link bandwidth
            tb["dut"]["total_ports"] = 4                 # not matched against the ports used
            tb["dut"]["links"] = [
                dict(dut_port="Ethernet1", stc_port="Card1/Port1", bandwidth=10000, vlan_id=1000),   # not Ethernet{4*i}
                dict(dut_port="Ethernet77", stc_port="Card9/Port9", bandwidth=25000, vlan_id=1000),
            ]
        r = run(self.cfg(fn), "full")
        self.assertEqual(r.rc, 0, r.stderr)

    def test_unusual_hwsku_is_not_validated(self):
        r = run(mutated("virtual_full.yaml", lambda c: c["deployment"]["dut_vs"].update(hwsku="Anything-X1")), "full")
        self.assertEqual(r.rc, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
