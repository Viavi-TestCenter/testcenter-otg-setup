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


class LegacyAndLayout(unittest.TestCase):
    def test_legacy_file_matches_new_layout_twin(self):
        legacy, twin = run("legacy_main.yaml"), run("virtual_full.yaml")
        self.assertEqual(legacy.rc, 0, legacy.stderr)
        self.assertEqual(twin.rc, 0, twin.stderr)
        # CFG_CONFIG_LEGACY says which file format was read, not anything about the lab
        self.assertEqual((legacy.vars.pop("CFG_CONFIG_LEGACY"), twin.vars.pop("CFG_CONFIG_LEGACY")), ("1", "0"))
        self.assertEqual(legacy.vars, twin.vars)
        self.assertIn("deprecated", legacy.stderr.lower())
        self.assertIn("host_interface", legacy.stderr)
        self.assertNotIn("deprecated", twin.stderr.lower())

    def test_mixed_layout_is_rejected_naming_the_keys(self):
        r = run("mixed.yaml")
        self.assertEqual(r.rc, 1)
        for key in ("images", "dut", "deployment.target"):
            self.assertIn(key, r.stderr)

    def test_legacy_otg_rest_port_difference_warns_and_uses_service_port(self):
        cfg = mutated("legacy_main.yaml", lambda c: c["otg"].update(rest_port=50052))
        r = run(cfg)
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_OTG_REST_PORT"], "50051")
        self.assertIn("otg.rest_port", r.stderr)

    def test_legacy_physical_moves_addresses_to_testbed_and_never_pushes(self):
        def f(c):
            c["testcenter"]["mode"] = "physical"
            c["dut"]["mode"] = "physical"
            c["deployment"]["stc_chassis"]["ip"] = "10.0.0.20"
            c["dut"]["mgmt_ip"] = "10.0.0.30"
        r = run(mutated("legacy_main.yaml", f))
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_STC_CHASSIS_OWNER"], "testbed")
        self.assertEqual(r.vars["CFG_STC_CHASSIS_IP"], "10.0.0.20")
        self.assertEqual(r.vars["CFG_DUT_OWNER"], "testbed")
        self.assertEqual(r.vars["CFG_DUT_MGMT_IP"], "10.0.0.30")
        self.assertEqual(r.vars["CFG_DEPLOY_MINIGRAPH_EFFECTIVE"], "0")
        self.assertIn("deploy_minigraph", r.stderr)

    def test_legacy_provisioned_mode_moves_services_to_testbed(self):
        def f(c):
            c["deployment"]["mode"] = "provisioned"
            c["deployment"]["labserver"]["ip"] = "10.0.0.21"
            c["deployment"]["otg_service"]["ip"] = "10.0.0.22"
        r = run(mutated("legacy_main.yaml", f))
        self.assertEqual(r.rc, 0, r.stderr)
        self.assertEqual(r.vars["CFG_LABSERVER_MODE"], "provisioned")
        self.assertEqual(r.vars["CFG_OTG_MODE"], "provisioned")
        self.assertEqual(r.vars["CFG_LABSERVER_IP"], "10.0.0.21")
        self.assertEqual(r.vars["CFG_OTG_SERVICE_IP"], "10.0.0.22")
        self.assertEqual(r.vars["CFG_LABSERVER_OWNER"], "testbed")
        self.assertEqual(r.vars["CFG_OTG_SERVICE_OWNER"], "testbed")

    def test_legacy_mismatched_modes_are_rejected(self):
        def f(c):
            c["testcenter"]["mode"] = "virtual"
            c["dut"]["mode"] = "physical"
        r = run(mutated("legacy_main.yaml", f))
        self.assertEqual(r.rc, 1)
        self.assertIn("must match", r.stderr)


class ShippedConfig(unittest.TestCase):
    SHIPPED = os.path.join(HERE, "..", "config.yaml")

    def test_shipped_config_is_valid_for_every_scope(self):
        for scope in ("deploy", "access", "full", "show"):
            with self.subTest(scope=scope):
                r = run(os.path.abspath(self.SHIPPED), scope)
                self.assertEqual(r.rc, 0, r.stderr)

    def test_shipped_config_describes_the_same_lab_as_the_old_shipped_one(self):
        # The only intended difference: allure.enabled now defaults to false (it was true).
        old, new = run("legacy_main.yaml").vars, run(os.path.abspath(self.SHIPPED)).vars
        old.pop("CFG_CONFIG_LEGACY"), new.pop("CFG_CONFIG_LEGACY")
        self.assertEqual(old.pop("CFG_ALLURE_ENABLED"), "1")
        self.assertEqual(new.pop("CFG_ALLURE_ENABLED"), "0")
        self.assertEqual(old, new)


class PrintMigrated(unittest.TestCase):
    """Proposal §4.6: --show-config prints the migrated layout so users can copy it."""

    def migrated_yaml(self, name="legacy_main.yaml"):
        with tempfile.TemporaryDirectory() as d:
            p = subprocess.run([sys.executable, LOADER, os.path.join(FIX, name), "--print-migrated"],
                               capture_output=True, text=True,
                               env=dict(os.environ, SNAPPI_HOST_IP_OVERRIDE=HOST))
            return p.returncode, p.stdout, p.stderr

    def test_legacy_file_is_printed_as_a_valid_new_layout_file(self):
        rc, out, err = self.migrated_yaml()
        self.assertEqual(rc, 0, err)
        migrated = yaml.safe_load(out)
        self.assertEqual(sorted(migrated), ["deployment", "testbed"])
        self.assertEqual(migrated["deployment"]["target"], "virtual")
        self.assertNotIn("host_interface", out)

    def test_migrated_output_resolves_to_exactly_the_same_values_as_the_legacy_file(self):
        rc, out, err = self.migrated_yaml()
        self.assertEqual(rc, 0, err)
        legacy, again = run("legacy_main.yaml"), run(yaml.safe_load(out))
        self.assertEqual(again.rc, 0, again.stderr)
        again.vars.pop("CFG_CONFIG_LEGACY"), legacy.vars.pop("CFG_CONFIG_LEGACY")
        self.assertEqual(legacy.vars, again.vars)
        self.assertNotIn("deprecated", again.stderr.lower())

    def test_a_file_in_the_new_layout_has_nothing_to_migrate(self):
        rc, out, err = self.migrated_yaml("virtual_full.yaml")
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertIn("nothing to migrate", err)

    def test_layout_is_exported_for_the_shell(self):
        self.assertEqual(run("legacy_main.yaml").vars["CFG_CONFIG_LEGACY"], "1")
        self.assertEqual(run("virtual_full.yaml").vars["CFG_CONFIG_LEGACY"], "0")


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

    def test_allure_is_off_by_default(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["deployment"].update(allure={}))
        self.assertEqual(run(cfg).vars["CFG_ALLURE_ENABLED"], "0")

    def test_allure_project_id_is_required_in_testbed_when_enabled(self):
        cfg = mutated("virtual_full.yaml", lambda c: c["testbed"].pop("reporting"))
        r = run(cfg, "full")
        self.assertEqual(r.rc, 1)
        self.assertIn("testbed.reporting.allure_project_id", r.stderr)


if __name__ == "__main__":
    unittest.main()
