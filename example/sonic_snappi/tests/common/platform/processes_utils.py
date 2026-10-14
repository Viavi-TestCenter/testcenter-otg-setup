"""
Helper script for checking status of critical processes

This script contains re-usable functions for checking status of critical services.
"""
import logging
import time
import re

from tests.common.helpers.assertions import pytest_assert
from tests.common.utilities import wait_until, get_plt_reboot_ctrl

logger = logging.getLogger(__name__)

# Processes that run under supervisord with autorestart=true and are known to
# bounce transiently (e.g. right after a reboot) without indicating a real
# regression. Mirrors the same exemption already applied in
# tests/process_monitoring/test_critical_process_monitoring.py.
KNOWN_AUTO_RESTART_PROCESSES = ['syseepromd', 'thermalctld', 'sensord']


def check_pmon_uptime_minutes(duthost, minimal_runtime=6):
    """
    @summary: This function checks if pmon uptime is at least the minimal_runtime
    @return: True pmon has been running at least the minimal_runtime, False for otherwise
    """
    result = duthost.command("docker ps | grep pmon", _uses_shell=True)
    if result["stdout"]:
        match = re.search(r'Up (\d+) (minutes|hours)', result["stdout"])
        if match:
            if match.group(2) == "hours":
                return int(match.group(1))*60 >= minimal_runtime
            else:
                return int(match.group(1)) >= minimal_runtime
        match = re.search(r'Up About an hour', result["stdout"])
        if match:
            return 60 >= minimal_runtime
    return False


def reset_timeout(duthost):
    """
    return: if timeout is specified in inventory file for this dut, return new timeout
            if not specified, return 300 sec as default timeout
    e.g.
        processes_utils.py:
          timeout: 400
          wait: 60
    """
    reset_timeout = 300
    plt_reboot_ctrl = get_plt_reboot_ctrl(duthost, 'processes_utils.py', 'cold')
    if plt_reboot_ctrl:
        reset_timeout = plt_reboot_ctrl.get('timeout', 300)
    return reset_timeout


def get_critical_processes_status(dut, exclude_processes=None):
    """
    @summary: Check the health status of all critical processes.
    @param dut: The AnsibleHost object of DUT. For interacting with DUT.
    @param exclude_processes: iterable of process names to ignore if found not
        running (see KNOWN_AUTO_RESTART_PROCESSES for an example use).
    """
    exclude_processes = set(exclude_processes or [])
    processes_status = dut.all_critical_process_status()
    for container_name, processes in list(processes_status.items()):
        exited = processes['exited_critical_process']
        if exclude_processes and exited:
            ignored = [p for p in exited if p in exclude_processes]
            remaining = [p for p in exited if p not in exclude_processes]
            if ignored:
                logger.info("Ignoring known auto-restart process(es) {} that exited in "
                            "container '{}'".format(ignored, container_name))
                processes['exited_critical_process'] = remaining
                if not remaining:
                    # every offending process for this container was excluded
                    processes['status'] = True
                exited = remaining

        if processes['status'] is False or len(processes['exited_critical_process']) > 0:
            logger.info("The status of checking process in container '{}' is: {}"
                        .format(container_name, processes["status"]))
            logger.info("The processes not running in container '{}' are: '{}'"
                        .format(container_name, processes["exited_critical_process"]))
            return False, processes_status

    return True, processes_status


def _all_critical_processes_healthy(dut, exclude_processes=None):
    logging.info("Check critical processes status")
    status, _ = get_critical_processes_status(dut, exclude_processes=exclude_processes)
    return status


def check_critical_processes(dut, watch_secs=0, exclude_processes=None):
    """
    @summary: check all critical processes. They should be all running.
              keep on checking every 5 seconds until watch_secs drops below 0.
    @param dut: The AnsibleHost object of DUT. For interacting with DUT.
    @param watch_secs: all processes should remain healthy for watch_secs seconds.
    @param exclude_processes: iterable of process names to ignore if found not running.
    """
    logging.info("Check all critical processes are healthy for {} seconds".format(watch_secs))
    while watch_secs >= 0:
        status, details = get_critical_processes_status(dut, exclude_processes=exclude_processes)
        pytest_assert(status, "Not all critical processes are healthy: {}".format(details))
        if watch_secs > 0:
            time.sleep(min(5, watch_secs))
        watch_secs = watch_secs - 5


def wait_critical_processes(dut, timeout=None, exclude_processes=None):
    """
    @summary: wait until all critical processes are healthy.
    @param dut: The AnsibleHost object of DUT. For interacting with DUT.
    @param timeout: customized timeout value in seconds. If specified, it overwrites the value from inventory file.
    @param exclude_processes: iterable of process names to ignore if found not running, e.g.
        KNOWN_AUTO_RESTART_PROCESSES for daemons that are configured to autorestart and can
        bounce transiently (for example right after a reboot) without indicating a real
        regression.
    """
    if timeout is None:
        timeout = reset_timeout(dut)
        # No matter what we set in inventory file, we always set sup timeout to 900
        # because most SUPs have 10+ dockers that need to come up
        if dut.is_supervisor_node():
            timeout = 900
        elif dut.get_facts().get("modular_chassis"):
            # Modular chassis linecards initialise many port/buffer objects after a
            # config reload; 300s is not always enough (same 600s bump already used
            # for modular chassis elsewhere, e.g. config_reload.py).
            timeout = max(timeout, 600)
    logging.info("Wait until all critical processes are healthy in {} sec"
                 .format(timeout))
    if not wait_until(timeout, 20, 0, _all_critical_processes_healthy, dut, exclude_processes):
        # Collect a final snapshot so the assertion message names the offenders
        _, processes_status = get_critical_processes_status(dut, exclude_processes=exclude_processes)
        unhealthy = {
            svc: {
                'status': info['status'],
                'exited': info['exited_critical_process']
            }
            for svc, info in processes_status.items()
            if not info['status'] or info['exited_critical_process']
        }
        pytest_assert(False, "Not all critical processes are healthy: {}".format(unhealthy))
