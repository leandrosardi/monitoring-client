# config.rb.example -- template configuration for monitoring-client.
# Copy to config.rb and fill in real values. config.rb is gitignored.

# === SaaS / backend target ===
MONITORING_SAAS_URL   = '!!monitoring_saas_url'             # base URL of your SaaS
MONITORING_SAAS_PORT  = !!monitoring_saas_port              # port
MONITORING_API_KEY    = '!!monitoring_saas_su_api_key'      # super-user API key
MONITORING_NODE_PATH  = '/api2.0/node/track.json'           # endpoint to receive node heartbeats

# === Node metadata ===
MICRO_SERVICE_NAME    = '!!monitoring_micro_service_name'   # descriptive label for this node
SLOTS_QUOTA           = !!monitoring_micro_service_slots    # capacity quota

# === Logfiles to monitor ===
# Each entry is a hash with:
#  :name        -> logical name used in reporting
#  :path        -> full path to the logfile
#  :pattern     -> (optional) regex to filter / highlight lines
#  :tail_lines  -> how many lines to include when fetching recent context
LOG_FILES = !!monitoring_logfiles

# === Services / daemons to monitor ===
# Each entry can define a systemd unit or custom check.
# Supported keys:
#  :name         -> logical name
#  :systemd_unit -> name of systemd service (preferred)
#  :cmd_check    -> alternative shell command that exits 0 when healthy
#  :expect_count -> for custom processes, expected minimum number of matching processes
SERVICES = !!monitoring_services

# === Websites to monitor ===
# Each entry:
#   :name             -> logical label
#   :protocol         -> "http" or "https"
#   :host             -> domain or IP
#   :port             -> port number
#   :path             -> URL path to check (default "/")
#   :check_ssl_expiry -> only for https, whether to warn on expiring certs
WEBSITES = !!monitoring_websites

# === SSL expiry thresholds (in days) ===
# If check_ssl_expiry is true, generate alerts when the cert expires within
# any of these windows.
SSL_EXPIRY_THRESHOLDS = !!monitoring_ssl_rules

# === Polling / heartbeat interval (seconds) ===
HEARTBEAT_INTERVAL = 10

# === Notes ===
# - You can extend this file with credentials, overrides, tags, etc.
# - Avoid committing the real config.rb; keep secrets local only.
