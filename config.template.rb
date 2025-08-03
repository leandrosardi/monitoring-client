# config.rb.example -- template configuration for monitoring-client.
# Copy to config.rb and fill in real values. config.rb is gitignored.

# === SaaS / backend target ===
MONITORING_SAAS_URL   = 'http://127.0.0.1'            # base URL of your SaaS
MONITORING_SAAS_PORT  = 3000                         # port
MONITORING_API_KEY    = 'SUPER_USER_API_KEY_HERE'     # super-user API key
MONITORING_NODE_PATH  = '/api2.0/node/track.json'    # endpoint to receive node heartbeats

# === Node metadata ===
MICRO_SERVICE_NAME    = 'worker-rpa'                 # descriptive label for this node
SLOTS_QUOTA           = 5                            # capacity quota

# === Logfiles to monitor ===
# Each entry is a hash with:
#  :name        -> logical name used in reporting
#  :path        -> full path to the logfile
#  :pattern     -> (optional) regex to filter / highlight lines
#  :tail_lines  -> how many lines to include when fetching recent context
LOG_FILES = [
  {
    name:       'application',
    path:       '/var/log/myapp/app.log',
    pattern:    nil,           # e.g. /ERROR|WARN/
    tail_lines: 100
  },
  {
    name:       'system',
    path:       '/var/log/syslog',
    pattern:    /error/i,
    tail_lines: 50
  }
  # add more as needed
]

# === Services / daemons to monitor ===
# Each entry can define a systemd unit or custom check.
# Supported keys:
#  :name         -> logical name
#  :systemd_unit -> name of systemd service (preferred)
#  :cmd_check    -> alternative shell command that exits 0 when healthy
#  :expect_count -> for custom processes, expected minimum number of matching processes
SERVICES = [
  {
    name:          'puma',
    systemd_unit:  'puma.service'
  },
  {
    name:          'redis',
    systemd_unit:  'redis.service'
  },
  {
    name:          'custom_worker',
    cmd_check:     'pgrep -f worker-process-name', # exits 0 if found
    expect_count:  1
  }
  # add more services/daemons here
]

# === Polling / heartbeat interval (seconds) ===
HEARTBEAT_INTERVAL = 10

# === Notes ===
# - You can extend this file with credentials, overrides, tags, etc.
# - Avoid committing the real config.rb; keep secrets local only.
