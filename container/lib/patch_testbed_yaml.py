#!/usr/bin/env python3
"""
patch_testbed_yaml.py <testbed.yaml> <conf-name>

Reads a new testbed entry (as YAML) from stdin and inserts/replaces the entry
with a matching `conf-name` inside the target testbed.yaml list, leaving every
other entry untouched. testbed.yaml holds many unrelated testbeds already
defined by the sonic-mgmt repo - this must never clobber them.
"""
import sys
import yaml


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: patch_testbed_yaml.py <testbed.yaml> <conf-name>\n")
        sys.exit(2)

    path, conf_name = sys.argv[1], sys.argv[2]
    new_entry = yaml.safe_load(sys.stdin.read())

    with open(path) as f:
        data = yaml.safe_load(f) or []

    if not isinstance(data, list):
        sys.stderr.write(f"ERROR: {path} does not contain a YAML list at the top level\n")
        sys.exit(1)

    found = False
    for i, item in enumerate(data):
        if isinstance(item, dict) and item.get("conf-name") == conf_name:
            data[i] = new_entry
            found = True
            break
    if not found:
        data.append(new_entry)

    with open(path, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)

    sys.stderr.write(f"{'updated' if found else 'appended'} conf-name={conf_name} in {path}\n")


if __name__ == "__main__":
    main()
