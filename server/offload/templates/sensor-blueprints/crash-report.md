# Crash Report Sensor — Agent SOP

You are building a sensor that collects crash reports for a project.
The sensor must produce a `run.sh` script and a `manifest.yaml` that conform to the Offload sensor contract.

## What you need from the human

1. **Crash reporting service** — Which service does this project use? (Sentry, Crashlytics, Firebase Crashlytics, BugSnag, custom)
2. **API credentials** — Guide the human to create an API token with read access. Tell them exactly where to go in the service's dashboard.
3. **Project/app identifier** — Which project or app within the service to monitor.
4. **Severity threshold** — What counts as critical vs warning? (e.g. >10 occurrences = critical)

Ask for these via feedback requests. Do not guess credentials.

## What you must build

All files go in `.offload/sensors/<sensor-name>/`:

### 1. `manifest.yaml`
```yaml
name: <descriptive-name>
description: <what this sensor monitors>
schedule: "*/30 * * * *"
created_by: <your-topic-id>
status: active
```

### 2. `run.sh`
A shell script that:
- Calls the crash reporting API
- Parses the response
- Outputs a JSON array to stdout in this exact format:

```json
[
  {
    "severity": "critical",
    "title": "EXC_BAD_ACCESS in ViewController.swift:42",
    "detail": "Null pointer dereference in main thread",
    "count": 15,
    "source": "sentry",
    "metadata": {"issue_id": "PROJ-123", "first_seen": "2026-04-10", "affected_users": 45}
  }
]
```

Severity must be one of: `info`, `warning`, `critical`.
Output `[]` (empty array) if there are no new signals — do NOT error on zero results.

### 3. (Optional) `.env` or config file for credentials
Store API tokens in a `.env` file in the sensor directory. `run.sh` should source it.
Never hardcode credentials in the script.

## Validation checklist

Before marking this topic as complete:

- [ ] `run.sh` executes without errors
- [ ] Output is valid JSON matching the signal schema
- [ ] Run it 3 times — should succeed every time
- [ ] Credentials are in `.env`, not in the script
- [ ] `manifest.yaml` is valid and has correct schedule
