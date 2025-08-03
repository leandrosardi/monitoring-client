#!/usr/bin/env ruby
require 'json'
require 'socket'
require 'pampa'
require 'simple_cloud_logging'
require 'simple_command_line_parser'
require_relative '../lib/monitoring_client'

# parse command line parameters
parser = BlackStack::SimpleCommandLineParser.new(
    :description => 'This command will run automation of one specific profile.',
    :configuration => [{
        :name=>'run-once',
        :mandatory=>false,
        :description=>"Avoid infinite loop. Default is false.",
        :type=>BlackStack::SimpleCommandLineParser::BOOL,
        :default=>false,
    }, {
        :name=>'delay',
        :mandatory=>false,
        :description=>'Minimum delay between loops. A minimum of 10 seconds is recommended, in order to don\'t hard the database server. Default is 30 seconds.',
        :type=>BlackStack::SimpleCommandLineParser::INT,
        :default=>10,
    }]
)

# load config (must exist)
begin
  require_relative '../config'
rescue LoadError
  STDERR.puts "Missing config.rb. Copy config.rb.example to config.rb and fill values."
  exit 1
end

# Build client
client = MonitoringClient::Client.new(
  base_url:      MONITORING_SAAS_URL,
  port:          MONITORING_SAAS_PORT,
  api_key:       MONITORING_API_KEY,
  node_path:     MONITORING_NODE_PATH,
  micro_service: defined?(MICRO_SERVICE_NAME) ? MICRO_SERVICE_NAME : 'unknown',
  slots_quota:   defined?(SLOTS_QUOTA) ? SLOTS_QUOTA : 1
)

BlackStack::Pampa.run_stand_alone({
    :log_filename => 'monitor.log',
    :delay => parser.value('delay'),
    :run_once => parser.value('run-once'),
    :function => Proc.new do |l, *args|

      l.logs 'Push data... '
      result = client.push_node_status
      l.done

    end
})

