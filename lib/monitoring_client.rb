require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'open3'
require 'socket'  # if not already present (needed for provider_code if you use it)
require 'fileutils'

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
    def initialize(base_url:, port:, api_key:, node_path:, micro_service:, slots_quota:, services: [], log_files: [])
        @base_url      = base_url.chomp('/')
        @port          = port
        @api_key       = api_key
        @node_path     = node_path
        @micro_service = micro_service
        @slots_quota   = slots_quota
        @services      = services                # array of systemd unit names
        @log_files     = log_files               # array of hashes: { name:, path:, pattern:, tail_lines: }
        @alert_path    = '/api2.0/node_alert/upsert.json'
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

        node_resp = post_json(request_url, body)
        node_id = node_resp.dig(:body, 'node_id') || node_resp.dig(:body, 'id')

        if node_id
            check_services.each do |svc|
                upsert_service_alert(node_id, svc[:name], svc[:description], solved: svc[:active])
            end
            process_logfiles(node_id)
        end
    end

    private

    def normalized_services
        @normalized_services ||= @services.map do |s|
            if s.is_a?(String)
                { name: s.sub(/\.service$/, ''), unit: s }
            elsif s.is_a?(Hash)
                unit = s[:systemd_unit] || s['systemd_unit'] || s[:unit] || s['unit']
            next if unit.nil? || unit.to_s.strip.empty?
                name = s[:name] || unit.to_s.sub(/\.service$/, '')
                { name: name, unit: unit }
            else
                nil
            end
        end.compact
    end


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

    def check_services
        alerts = []
        normalized_services.each do |svc|
            unit = svc[:unit]
            active = service_active?(unit)
            if active
                alerts << { name: svc[:name], unit: unit, active: true, description: "Service '#{unit}' is active." }
                next
            end

            status_summary = capture_command("systemctl status #{unit} --no-pager 2>&1")
            recent_logs    = capture_command("journalctl -u #{unit} -n 20 --no-pager 2>&1")
            description = +"Service '#{unit}' is not active.\n"
            description << "Status summary: #{extract_last_lines(status_summary, 5)}\n"
            description << "Recent logs: #{extract_last_lines(recent_logs, 10)}"
            alerts << { name: svc[:name], unit: unit, active: false, description: description.strip }
        end
        alerts
    end

    def service_active?(unit)
        return false if unit.to_s.strip.empty?
        out, _ = Open3.capture2("systemctl is-active #{unit}")
        out.strip == 'active'
    rescue
        false
    end

    def capture_command(cmd)
        out, _ = Open3.capture2e(cmd)
        out.to_s
    rescue => e
        "Failed to run #{cmd}: #{e.message}"
    end

    def extract_last_lines(text, n)
        return '' unless text
        lines = text.lines.map(&:chomp)
        lines.last(n).join(' | ')
    end

    def alert_url
        "#{@base_url}:#{@port}#{@alert_path}"
    end

    def upsert_service_alert(node_id, service_name, description, solved:)
        payload = {
            api_key:        @api_key,
            id_node:        node_id,
            type:           "SERVICE_FAILED:#{service_name}",
            description:    description,
            screenshot_url: nil,
            solved:         solved
        }
        post_json(alert_url, payload)
    end

    def upsert_log_alert(node_id, log_name, description, solved:)
        payload = {
            api_key:        @api_key,
            id_node:        node_id,
            type:           "LOG_ISSUE:#{log_name}",
            description:    description,
            screenshot_url: nil,
            solved:         solved
        }
        post_json(alert_url, payload)
    end

    def log_state_dir
        dir = File.expand_path('~/.monitoring_client/log_state')
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
        dir
    end

    def state_file_path(log_name)
        File.join(log_state_dir, "#{sanitize_name(log_name)}.json")
    end

    def sanitize_name(name)
        name.gsub(/[^a-zA-Z0-9_\-]/, '_')
    end

    def load_log_state(log_name)
        path = state_file_path(log_name)
        return {} unless File.exist?(path)
        JSON.parse(File.read(path)) rescue {}
    end

    def save_log_state(log_name, state)
        path = state_file_path(log_name)
        File.write(path, JSON.pretty_generate(state))
    end

    def file_identity(path)
        st = File.stat(path)
        { ino: st.ino, dev: st.dev }
    rescue
        nil
    end

    def identity_changed?(old_id, new_id)
        return true if old_id.nil? || new_id.nil?
        old_id['ino'].to_i != new_id[:ino].to_i || old_id['dev'].to_i != new_id[:dev].to_i
    end

    def process_logfiles(node_id)
#binding.pry
        return unless @log_files.is_a?(Array)
        @log_files.each do |lf|
            name = lf[:name]
            path = lf[:path]
            pattern = lf[:pattern] || /(ERROR|FATAL|PANIC|WARNING)/i
            tail_lines = lf[:tail_lines] || 100

            state = load_log_state(name)
            previous_identity = state['file_id']
            previous_offset = state['offset'] || 0

            if !File.exist?(path)
                # file missing -> upsert missing alert
                upsert_log_alert(node_id, name, "Logfile #{path} does not exist.", solved: false)
                next
            end

            current_identity = file_identity(path)
            reset = identity_changed?(previous_identity, current_identity)
            offset = reset ? 0 : previous_offset.to_i

            matches = []
            begin
                File.open(path, 'r') do |f|
                    f.seek(offset, IO::SEEK_SET) if offset > 0
                    f.each_line do |line|
                        if line.match?(pattern)
                            matches << line.chomp
                        end
                    end
                    new_offset = f.pos
                    # save state with updated identity and offset
                    new_state = {
                        'file_id' => { 'ino' => current_identity[:ino], 'dev' => current_identity[:dev] },
                        'offset'  => new_offset
                    }
                    save_log_state(name, new_state)
                end
            rescue => e
                upsert_log_alert(node_id, name, "Failed reading logfile #{path}: #{e.message}", solved: false)
                next
            end

            # If the file was missing previously and now exists, mark previous missing alert as solved
            if state['file_id'].nil? && File.exist?(path)
                upsert_log_alert(node_id, name, "Logfile #{path} recovered.", solved: true)
            end

            # If matches found, report an alert (include last few)
            unless matches.empty?
                sample = matches.last([matches.size, tail_lines].min).join(" | ")
                description = "Detected patterns in #{path}: #{sample}"
                upsert_log_alert(node_id, name, description, solved: false)
            end
        end
    end

  end
end
