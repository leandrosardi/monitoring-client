# monitoring-client

Lightweight Ruby client to collect system metrics on Ubuntu 22.04 and push node status to a SaaS monitoring backend.

## Overview

`monitoring-client` gathers node-level metrics (RAM, CPU, disk usage) and reports them to your SaaS platform via its super-user API. It is designed to run on Ubuntu 22.04 with no external dependencies beyond standard Ruby.

## Features

* Collects:

  * Total RAM (GB) and current RAM usage (%)
  * Total disk (GB) and disk usage (%)
  * CPU usage (%) sampled over a short interval
* Sends a heartbeat to the SaaS endpoint, merging by caller IP
* Safe upsert logic so existing nodes are updated and new ones created with required defaults
* Transparent configuration via `config.rb`

## Requirements

* Ruby (system Ruby on Ubuntu 22.04 is sufficient)
* Internet connectivity to the SaaS endpoint
* Super-user API key for your SaaS node tracking access point

## Installation

1. Clone or create the project directory.
2. Install dependencies (optional if using standard Ruby):

```bash
bundle install
```

## Configuration

Copy the example config and edit:

```bash
cp config.rb.example config.rb
```

Edit `config.rb` with your SaaS endpoint, port, API key and other metadata:

```ruby
MONITORING_SAAS_URL   = 'http://your-saas-domain'
MONITORING_SAAS_PORT  = 3000
MONITORING_API_KEY    = 'super_user_api_key'
MONITORING_NODE_PATH  = '/api2.0/node/track.json'
MICRO_SERVICE_NAME    = 'worker-rpa'
SLOTS_QUOTA           = 5
```

**Important:** `config.rb` is ignored by Git via `.gitignore` so secrets are not committed.

## Usage

Run the monitor script once:

```bash
ruby bin/monitor.rb
```

Sample output:

```json
{
  "code": 200,
  "body": {
    "status": "success",
    "action": "updated",
    "node_id": "..."
  }
}
```

## Metrics Sent

The payload includes:

* `total_ram_gb`, `current_ram_usage`
* `total_disk_gb`, `current_disk_usage`
* `current_cpu_usage`
* `micro_service`, `slots_quota`, `slots_used`
* Heartbeat fields like `last_start_time`, `last_start_success`, `last_start_description`

## Example: curl-style request

```bash
curl -X POST http://127.0.0.1:3000/api2.0/node/track.json \
  -H 'Content-Type: application/json' \
  -d '{
    "api_key":"SUPER_USER_API_KEY",
    "slots_quota":10,
    "slots_used":2,
    "total_ram_gb":8.0,
    "total_disk_gb":100.0,
    "current_ram_usage":55.2,
    "current_disk_usage":40.1,
    "current_cpu_usage":12.3,
    "max_ram_usage":90.0,
    "max_disk_usage":90.0,
    "max_cpu_usage":90.0
  }'
```

## Scheduling

You can run the script regularly using cron or wrap it in a loop to send periodic heartbeats. Example cron entry (every minute):

```cron
* * * * * cd /path/to/monitoring-client && /usr/bin/env ruby bin/monitor.rb >> monitor.log 2>&1
```

## Extensibility

You can adapt the payload or endpoint (`node/upsert.json`, etc.) if your backend evolves. The logic merges by IP, so existing node records are updated rather than duplicated.

## Troubleshooting

* Ensure `config.rb` exists and contains valid values.
* Check network connectivity to the SaaS URL/port.
* Inspect logs from `bin/monitor.rb` or your wrapper for errors.

## License

MIT License
