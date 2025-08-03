require 'net/http'
require 'uri'
require 'json'
require 'time'

module MonitoringClient
  module SystemMetrics
    module_function

    def read_cpu
        line = File.readlines('/proc/stat').find { |l| l.start_with?('cpu ') }
        nums = line.split[1..].map(&:to_i)
        user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice = nums.values_at(0,1,2,3,4,5,6,7,8,9)
        idle_all = idle + iowait
        non_idle = user + nice + system + irq + softirq + steal
        total = idle_all + non_idle
        { total: total, idle: idle_all }
    end

    def total_ram_gb
        mem = File.read('/proc/meminfo')
        total_kb = mem[/MemTotal:\s+(\d+)/, 1].to_i
        (total_kb / 1024.0 / 1024.0).round(2)
    end

    def current_ram_usage_percent
        mem = File.read('/proc/meminfo')
        total_kb     = mem[/MemTotal:\s+(\d+)/,1].to_i
        available_kb = mem[/MemAvailable:\s+(\d+)/,1].to_i
        used_kb = total_kb - available_kb
        percent = used_kb * 100.0 / total_kb
        percent.round(2)
    end

    # CPU usage over a short interval
    def current_cpu_usage_percent(interval: 0.2)
        first = read_cpu
        sleep interval
        second = read_cpu

        totald = second[:total] - first[:total]
        idled  = second[:idle] - first[:idle]
        usage = if totald > 0
            ((totald - idled) * 100.0 / totald)
        else
            0.0
        end
        usage.round(2)
    end

    def total_disk_gb(mount_point = '/')
        # df -BG --output=size / | tail -1 | tr -dc '0-9'
        out = `df -BG --output=size #{mount_point} | tail -1`.strip
        if out =~ /(\d+)G/
            $1.to_i
        else
            0
        end
    end

    def current_disk_usage_percent(mount_point = '/')
        # df --output=pcent / | tail -1 -> e.g. " 42%"
        out = `df --output=pcent #{mount_point} | tail -1`.strip
        if out =~ /(\d+)%/
            $1.to_f
        else
            0.0
        end
    end

    def cpu_cores
          File.read('/proc/cpuinfo').scan(/^processor\s*:/).size
    end
  end

  class Client
    def initialize(base_url:, port:, api_key:, node_path:, micro_service:, slots_quota:)
        @base_url      = base_url.chomp('/')
        @port          = port
        @api_key       = api_key
        @node_path     = node_path
        @micro_service = micro_service
        @slots_quota   = slots_quota
    end

    def push_node_status
      metrics = gather_metrics
      body = {
        api_key:                @api_key,
        ssh_username:           nil,
        ssh_password:           nil,
        ssh_root_username:      nil,
        ssh_root_password:      nil,
        postgres_username:      nil,
        postgres_password:      nil,
        #provider_type:          'self-monitored',
        #provider_code:          Socket.gethostname,
        micro_service:          @micro_service,
        slots_quota:            @slots_quota,
        slots_used:             0,
        total_ram_gb:           metrics[:total_ram_gb],
        total_disk_gb:          metrics[:total_disk_gb],
        current_ram_usage:      metrics[:current_ram_usage],
        current_disk_usage:     metrics[:current_disk_usage],
        current_cpu_usage:      metrics[:current_cpu_usage],
        max_ram_usage:          90.0,
        max_disk_usage:         90.0,
        max_cpu_usage:          90.0,
        creation_time:          nil,
        creation_success:       nil,
        creation_error_description: nil,
        installation_time:           nil,
        installation_success:        nil,
        installation_error_description:nil,
        migrations_time:             nil,
        migrations_success:          nil,
        migrations_error_description:nil,
        last_start_time:             Time.now.iso8601,
        last_start_success:          true,
        last_start_description:      'heartbeat',
        last_stop_time:              nil,
        last_stop_success:          nil,
        last_stop_description:       nil
      }

      post_json(request_url, body)
    end

    private

    def gather_metrics
      {
        total_ram_gb:       SystemMetrics.total_ram_gb,
        current_ram_usage:  SystemMetrics.current_ram_usage_percent,
        current_cpu_usage:  SystemMetrics.current_cpu_usage_percent,
        total_disk_gb:      SystemMetrics.total_disk_gb,
        current_disk_usage: SystemMetrics.current_disk_usage_percent
      }
    end

    def request_url
      "#{@base_url}:#{@port}#{@node_path}"
    end

    def post_json(url, payload)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req.body = payload.to_json

      res = Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.request(req)
      end

      begin
        resp_body = JSON.parse(res.body)
      rescue
        resp_body = { raw: res.body }
      end

      { code: res.code.to_i, body: resp_body }
    rescue => e
      { error: e.message }
    end
  end
end
