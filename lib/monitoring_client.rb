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

    # Return something like "Ubuntu 22.04"
    def os_version
        if File.exist?('/etc/os-release')
        info = {}
        File.read('/etc/os-release').each_line do |line|
            k, v = line.strip.split('=', 2)
            info[k] = v.delete_prefix('"').delete_suffix('"') if k && v
        end
        name = info['NAME']
        ver  = info['VERSION_ID']
        [name, ver].compact.join(' ')
        else
        # fallback to lsb_release if available
        `lsb_release -ds`.strip.delete_prefix('"').delete_suffix('"')
        end
    rescue
        nil
    end

    # Return the hostname
    def hostname
        `hostname`.strip
    end

  end # module SystemMetrics


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
            os_version:             SystemMetrics::os_version,
            name:                   SystemMetrics::hostname,
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
            check_websites(node_id)
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
        uri = URI.parse(url)
        req = Net::HTTP::Post.new(uri)
        req['Content-Type'] = 'application/json'
        req.body = payload.to_json

        http = Net::HTTP.new(uri.host, uri.port)
        # <<< add this line to enable SSL when your URL is https://
        http.use_ssl = (uri.scheme == 'https')
        # if your server uses a self-signed cert, you might also need:
        # http.verify_mode = OpenSSL::SSL::VERIFY_NONE

        res = http.start do |h|
            h.request(req)
        end

        # avoid crashing on non-JSON bodies
        begin
            resp_body = JSON.parse(res.body)
        rescue JSON::ParserError
            resp_body = { raw: res.body }
        end

        { code: res.code.to_i, body: resp_body }
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
            type:           "LOG_ISSUE",
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
        return unless @log_files.is_a?(Array)

        @log_files.each do |lf|
            base_name  = lf[:name]
            pattern    = lf[:path]
            tail_lines = lf[:tail_lines] || 100
            regex      = lf[:pattern] || /(ERROR|FATAL|PANIC|WARNING)/i

            paths = Dir.glob(pattern)
            if paths.empty?
                # no files matched at all → alert once on the pattern
                upsert_log_alert(node_id, base_name,
                    "No log files match pattern #{pattern}", solved: false)
                next
            end

            paths.each do |path|
                name = "#{base_name}:#{File.basename(path)}"
                state = load_log_state(name)
                prev_id = state['file_id']
                offset  = state['offset'] || 0

                if !File.exist?(path)
                    upsert_log_alert(node_id, name, "Logfile #{path} disappeared.", solved: false)
                    next
                end

                curr_id = file_identity(path)
                reset   = identity_changed?(prev_id, curr_id)
                offset  = reset ? 0 : offset.to_i

                matches = []
                begin
                    File.open(path, 'r') do |f|
                        f.seek(offset, IO::SEEK_SET) if offset > 0
                        f.each_line do |line|
                            matches << line.chomp if line.match?(regex)
                        end
                        new_state = {
                            'file_id' => { 'ino' => curr_id[:ino], 'dev' => curr_id[:dev] },
                            'offset'  => f.pos
                        }
                        save_log_state(name, new_state)
                    end
                rescue => e
                    upsert_log_alert(node_id, name,
                    "Failed reading logfile #{path}: #{e.message}", solved: false)
                    next
                end

                # recovered?
                if state['file_id'].nil?
                    upsert_log_alert(node_id, name, "Logfile #{path} recovered.", solved: true)
                end

                # new matches?
                unless matches.empty?
                    sample = matches.last([matches.size, tail_lines].min).join(" | ")
                    upsert_log_alert(node_id, name,
                    "Detected in #{path}: #{sample}", solved: false)
                end
            end
        end
    end # process_logfiles

    # helper to follow up to 3 redirects
    def head_and_follow(uri, limit = 3)
        raise "Too many redirects" if limit.zero?
        res = Net::HTTP.start(uri.host, uri.port,
                            use_ssl: uri.scheme == 'https',
                            open_timeout: 5, read_timeout: 5) do |http|
        http.head(uri.request_uri)
        end
        case res
        when Net::HTTPRedirection
        head_and_follow(URI(res['location']), limit - 1)
        else
        res
        end
    end

    # helper to grab SSL cert
    def fetch_ssl_cert(host, port)
        tcp = TCPSocket.new(host, port)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp)
        ssl.hostname = host
        ssl.connect
        cert = ssl.peer_cert
        ssl.sysclose; tcp.close
        cert
    end

    # full replacement for your check_websites
    def check_websites(node_id)
        Array(WEBSITES).each do |w|
        name       = w[:name]
        proto      = w[:protocol]
        host       = w[:host]
        port       = w[:port]
        path       = w[:path]           || '/'
        # pick per-site thresholds or fall back to global
        thresholds = w[:ssl_thresholds] || SSL_EXPIRY_THRESHOLDS

        url = "#{proto}://#{host}:#{port}#{path}"
        uri = URI.parse(url)

        # 1) HTTP(S) reachability
        begin
            res = head_and_follow(uri)
            ok  = res.code.to_i.between?(200,399)
            msg = "HTTP #{res.code}"
        rescue => e
            ok  = false
            msg = e.message
        end

        upsert_log_alert(
            node_id,
            name,
            ok ? "Website #{url} reachable (#{msg})"
            : "Website #{url} unreachable: #{msg}",
            solved: ok
        )

        # 1.1) Response-time check
        if (resp_thr = w[:response_threshold])
        begin
            start = Time.now
            head_and_follow(uri)  # re-use our redirect-following HEAD
            elapsed_ms = ((Time.now - start) * 1000).to_i

            if elapsed_ms > resp_thr
            upsert_log_alert(
                node_id,
                "#{name}-response",
                "Response time for #{url} is #{elapsed_ms}ms (threshold #{resp_thr}ms)",
                solved: false
            )
            else
            upsert_log_alert(
                node_id,
                "#{name}-response",
                "Response time for #{url} is #{elapsed_ms}ms",
                solved: true
            )
            end
        rescue => e
            upsert_log_alert(
            node_id,
            "#{name}-response",
            "Response-time check failed for #{url}: #{e.message}",
            solved: false
            )
        end
        end


        # 2) SSL expiration check (HTTPS only)
        next unless proto == 'https'
        begin
            cert      = fetch_ssl_cert(host, port)
            days_left = ((cert.not_after - Time.now) / 86_400).to_i

            level = if days_left < thresholds[:critical]
                    :critical
                    elsif days_left < thresholds[:warning]
                    :warning
                    elsif days_left < thresholds[:notice]
                    :notice
                    end

            if level
            upsert_log_alert(
                node_id,
                "#{name}-ssl",
                "SSL for #{url} expires in #{days_left} days (#{cert.not_after.strftime('%Y-%m-%d')})",
                solved: false
            )
            else
            upsert_log_alert(
                node_id,
                "#{name}-ssl",
                "SSL for #{url} healthy (#{days_left} days left)",
                solved: true
            )
            end
        rescue => e
            upsert_log_alert(
            node_id,
            "#{name}-ssl",
            "SSL check failed for #{url}: #{e.message}",
            solved: false
            )
        end
        end
    end

end
end
