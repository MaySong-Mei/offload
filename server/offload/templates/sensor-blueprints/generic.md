# Sensor Construction — Agent SOP

You are building a sensor that collects external signals for a project.
The human has described what they want to observe. Your job is to build the collection pipeline.

## Discovery

1. Understand what the human wants to monitor
2. Determine how to access the data (API, webhook, scraping, local command)
3. If credentials or configuration are needed, ask the human via feedback requests
4. Do NOT guess or fabricate access credentials

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

Adjust the schedule based on the data source:
- High-frequency monitoring: `*/5 * * * *` (every 5 min)
- Standard: `*/30 * * * *` (every 30 min)
- Low-frequency: `0 */6 * * *` (every 6 hours)

### 2. `run.sh`
A shell script that:
- Collects data from the source
- Outputs a JSON array to stdout:

```json
[
  {
    "severity": "info|warning|critical",
    "title": "Short description of the signal",
    "detail": "Longer explanation if available",
    "count": 1,
    "source": "name-of-data-source",
    "metadata": {}
  }
]
```

Rules:
- Output `[]` for no new signals — never error on empty results
- Keep `run.sh` under 60 seconds execution time
- Handle network errors gracefully (exit non-zero, stderr gets captured)
- Use only standard tools (curl, jq, python3) — no pip installs

### 3. Credentials
If credentials are needed, store them in `.env` in the sensor directory.
`run.sh` should `source .env` at the top.

## Validation

Before marking complete:
- [ ] `run.sh` runs without errors
- [ ] Output is valid JSON array with correct schema
- [ ] Run 3 times consecutively — all succeed
- [ ] Credentials separated from script
