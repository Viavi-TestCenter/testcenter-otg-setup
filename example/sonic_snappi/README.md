# Test Baseline

## Overview

The 45 test cases in this suite were validated against a specific upstream snapshot of `sonic-net/sonic-mgmt`. They have **not** been validated against the latest upstream `master`.

## Upstream Baseline

| Item | Value |
|------|-------|
| Repository | [sonic-net/sonic-mgmt](https://github.com/sonic-net/sonic-mgmt) |
| Commit | `67d1dda053ca0e728284fbb4a8860aa4383dc96c` |
| Upstream PR | [#26558](https://github.com/sonic-net/sonic-mgmt/pull/26558) — "[fanout]: Auto-configure console switch on SONiC console fanouts" |

## Notes

- Results are only guaranteed for the commit above.
- Behavior on newer upstream revisions may differ; re-validate the cases before rebasing onto a later commit.


## Limitations

The current OTG does not support some config fields. These fields must be skipped during validation.

To skip them, create a `limitation` folder under `asset` in the OTG service (`/asset/limitation`) and add a `skip_check.yaml` file with the content below.

**File:** `/asset/limitation/skip_check.yaml`

```yaml
skip:
  - config.options.port_options.location_preemption
  - config.flows.packet.ipv4.identification.choice
  - config.flows.packet.ipv4.identification.increment.count
  - config.flows.packet.ipv4.identification.increment.start
```

| Skipped field | Reason |
|---|---|
| `config.options.port_options.location_preemption` | Not supported by the current OTG. |
| `config.flows.packet.ipv4.identification.choice` | Not supported by the current OTG. |
| `config.flows.packet.ipv4.identification.increment.count` | Not supported by the current OTG. |
| `config.flows.packet.ipv4.identification.increment.start` | Not supported by the current OTG. |