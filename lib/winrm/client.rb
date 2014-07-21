require "readline"
require 'base64'

module WinRM
  class Client

    attr_reader :httpcli
    attr_reader :endpoint
    attr_reader :host
    attr_reader :opts 

    def initialize(endpoint, opts = {})
      default_opts = { port: 5985, ssl: false, env_vars: {} }
      opts = default_opts.merge(opts)
      @opts = opts
      @host = host

      setup_client
      setup_transport(endpoint)
      setup_authentication

    end

    def setup_authentication
      if opts[:user] and opts[:pass]
        setup_ntlm
      else
        setup_kerberos
      end
    end

    def setup_kerberos
      # TODO: Bring up code from 1.2.x branch
      WinRM.log.debug 'Setting up kerberos authentication...'
      auths = @httpcli.www_auth.instance_variable_get('@authenticator')
      auths.delete_if {|i| i.is_a?(HTTPClient::SSPINegotiateAuth)}
      service ||= 'HTTP'
      @service = "#{service}/#{@endpoint.host}@#{opts[:realm]}"
      init_krb
    end

    def setup_ntlm
      WinRM.log.debug 'Setting up NTLM authentication...'
      @httpcli.www_auth.instance_variable_set("@authenticator",[
        @httpcli.www_auth.negotiate_auth
      ])

      @httpcli.set_auth(@endpoint.to_s, opts[:user], opts[:pass])

      opts.delete(:user)
      opts.delete(:pass)
    end

    def setup_transport(endpoint)
      if opts[:ssl].eql?(true)
        transport = 'https'
        @httpcli.ssl_config.set_trust_ca(opts[:ca_file]) unless opts[:ca_file].nil?
      else
        transport = 'http'
      end
      @endpoint = URI("#{transport}://#{endpoint}:#{opts[:port]}/wsman")
      
      opts[:endpoint] = @endpoint
    end

    def setup_client
      @httpcli = HTTPClient.new
      @httpcli.debug_dev = STDOUT if WinRM.log.level == Logger::DEBUG

    end

    def ready?
      begin
        wql("Select * from Win32_Process")
        return true
      rescue HTTPClient::KeepAliveDisconnected
        return false
      end
    end

    def wql(query, wmi_namespace = nil)
      WinRM::Request::Wql.new(self, endpoint: endpoint, query: query, wmi_namespace: wmi_namespace).execute
    end
    
    def shell_id
      @shell_id ||= open_shell(env_vars: opts[:env_vars])
    end

    def cmd(command,arguments = '', opts= {}, &block)
      default_opts = { :relay => false}

      opts = default_opts.merge(opts)

      response_array = [] unless block_given?

      begin
        command_id = start_process(shell_id, command: command, arguments: arguments )
        result = read_streams(shell_id,command_id) do |stream,text|
          
          if(opts[:relay])  
            case stream
            when :stdout
              STDOUT.write text
            when :stderr
              STDERR.write text
            end
          end

          if block_given?
            yield stream, text
          else
            response_array << {stream => text}
          end

        end
        return result, response_array
      ensure
        begin 
          close_command(shell_id,command_id)
        rescue ; end
      end
    end

    def powershell(script,opts = {})
      script = script.kind_of?(IO) ? script.read : script
      script = script.chars.to_a.join("\x00").chomp
      script << "\x00" unless script[-1].eql? "\x00"
      script = script.encode('ASCII-8BIT')
      script = Base64.strict_encode64(script)

      response_array = [] unless block_given?

      result, _not_used = cmd("powershell", "-encodedCommand #{script}", opts) do |stream,text|
        if block_given?
          yield stream, text
        else
          response_array << { stream => text }
        end
      end
      return result, response_array
    end

    def disconnect
      close_shell(shell_id)
    end

    def shell(shell_name = :cmd)
      command = shell_command(shell_name)
      process = start_process(shell_id,:command => command, batch_mode: false, :arguments => [])
      pump_read_thread(process)
      receive_and_pump(process, shell_name)
    end

    def send_message(message)
      #TODO: modify headers for encrypted Kerberos traffic
      WinRM.logger.debug "Message: #{Nokogiri::XML(message).to_xml}"
      unless (@service) # NOT kerberos
        hdr = {'Content-Type' => 'application/soap+xml;charset=UTF-8', 'Content-Length' => message.length}
        handle_response(@httpcli.post(endpoint, message, hdr))
      else
        original_length = message.length
        pad_len, emsg = winrm_encrypt(message)
        hdr = {
          "Connection" => "Keep-Alive",
          "Content-Type" => "multipart/encrypted;protocol=\"application/HTTP-Kerberos-session-encrypted\";boundary=\"Encrypted Boundary\""
        }

        body = <<-EOF
--Encrypted Boundary\r
Content-Type: application/HTTP-Kerberos-session-encrypted\r
OriginalContent: type=application/soap+xml;charset=UTF-8;Length=#{original_length + pad_len}\r
--Encrypted Boundary\r
Content-Type: application/octet-stream\r
#{emsg}--Encrypted Boundary\r
        EOF

        r = @httpcli.post(@endpoint, body, hdr)
        r.http_body = winrm_decrypt(r.http_body)
        handle_response(r)
      end
    end

    def open_shell(call_opts = {})
      call_opts = shell_opts(call_opts)
      WinRM::Request::OpenShell.new(self, call_opts).execute
    end

    def close_shell(shell_id, call_opts = {})
      call_opts = shell_opts(call_opts,shell_id)
      WinRM::Request::CloseShell.new(self,call_opts).execute
    end

    def start_process(shell_id, call_opts = {})
      call_opts = shell_opts(call_opts,shell_id)
      WinRM::Request::StartProcess.new(self,call_opts).execute
    end

    def close_command(shell_id,command_id)
      WinRM::Request::CloseCommand.new(self, shell_id: shell_id, command_id: command_id).execute
    end

    def read_streams(shell_id,command_id, &block)
      WinRM::Request::ReadOutputStreams.new(self, shell_id: shell_id, command_id: command_id).execute do |stream,text|
        yield stream,text
      end
    end

    def write_stdin(shell_id,command_id, text)
      WinRM::Request::WriteStdin.new(self, shell_id: shell_id, command_id: command_id, text: text ).execute
    end

    private
    def init_krb
      WinRM.logger.debug "Initializing Kerberos for #{@service}"
      @gsscli = GSSAPI::Simple.new(@endpoint.host, @service)
      token = @gsscli.init_context
      auth = Base64.strict_encode64 token

      hdr = {"Authorization" => "Kerberos #{auth}",
        "Connection" => "Keep-Alive",
        "Content-Type" => "application/soap+xml;charset=UTF-8"
      }
      WinRM.logger.debug "Sending HTTP POST for Kerberos Authentication"
      r = @httpcli.post(@endpoint, '', hdr)
      itok = r.header["WWW-Authenticate"].find { |h| h =~ /^Kerberos/}
      raise StandardError.new("Server did not respond with a Kerberos token, do you have login rights?") if itok !~ /^Kerberos \S+/
      #itok = r.header["WWW-Authenticate"].pop
      itok = itok.split.last
      itok = Base64.strict_decode64(itok)
      @gsscli.init_context(itok)
    end

    def shell_opts(call_opts, shell_id = nil)
      rtn_opts = opts.dup.merge(call_opts)
      rtn_opts[:shell_id] = shell_id unless shell_id.nil?
      rtn_opts
    end

    def pump_read_thread(process)
      @read_thread = Thread.new do
        read_streams(shell_id,process) do |s,t|
          case s
          when :stdout
            STDOUT.write t
          when :stderr
           STDERR.write t 
          end
        end
        close_command(shell_id,process)
        exit 0
      end

      Signal.trap("INT") do
        puts "Exiting..."
        exit 1
      end
    end

    def receive_and_pump(process, shell_name)
      if shell_name.eql? :powershell
        write_stdin(shell_id,process, "Write-Host -NoNewline \"PS $(pwd)> \"\r\n")
      end

      while buf = Readline.readline('', true)
        if buf =~ /^exit!$/
          close_command(shell_id,process)
          exit 0
        else
          write_stdin(shell_id,process,"#{buf}\r\n")
          if shell_name.eql? :powershell
            write_stdin(shell_id,process, "Write-Host -NoNewline \"PS $(pwd)> \"\r\n")
          end
        end
      end
    end

    def shell_command(shell_name)
      case shell_name
      when :cmd
        command = 'cmd'
      when :powershell
        command = "Powershell -Command ^-"
      else
        raise ArgumentError, "Invalid console type #{shell_name}"
      end
    end

    def handle_response(resp)
      if(resp.status == 200)
        WinRM.logger.debug "Response #{Nokogiri::XML(resp.body).to_xml}"
        return resp.http_body.content
      else
        WinRM.logger.debug resp.http_body.content
        raise WinRMHTTPTransportError.new("Bad HTTP response returned from server (#{resp.status}).", resp)
      end
    end

    # @return [String] the encrypted request string
    def winrm_encrypt(str)
      WinRM.logger.debug "Encrypting SOAP message:\n#{str}"
      iov_cnt = 3
      iov = FFI::MemoryPointer.new(GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * iov_cnt)

      iov0 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address))
      iov0[:type] = (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_HEADER | GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_FLAG_ALLOCATE)

      iov1 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address + (GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * 1)))
      iov1[:type] =  (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_DATA)
      iov1[:buffer].value = str

      iov2 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address + (GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * 2)))
      iov2[:type] = (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_PADDING | GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_FLAG_ALLOCATE)

      conf_state = FFI::MemoryPointer.new :uint32
      min_stat = FFI::MemoryPointer.new :uint32

      maj_stat = GSSAPI::LibGSSAPI.gss_wrap_iov(min_stat, @gsscli.context, 1, GSSAPI::LibGSSAPI::GSS_C_QOP_DEFAULT, conf_state, iov, iov_cnt)

      token = [iov0[:buffer].length].pack('L')
      token += iov0[:buffer].value
      token += iov1[:buffer].value
      pad_len = iov2[:buffer].length
      token += iov2[:buffer].value if pad_len > 0
      [pad_len, token]
    end


    # @return [String] the unencrypted response string
    def winrm_decrypt(str)
      WinRM.logger.debug "Decrypting SOAP message:\n#{str}"
      iov_cnt = 3
      iov = FFI::MemoryPointer.new(GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * iov_cnt)

      iov0 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address))
      iov0[:type] = (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_HEADER | GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_FLAG_ALLOCATE)

      iov1 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address + (GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * 1)))
      iov1[:type] =  (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_DATA)

      iov2 = GSSAPI::LibGSSAPI::GssIOVBufferDesc.new(FFI::Pointer.new(iov.address + (GSSAPI::LibGSSAPI::GssIOVBufferDesc.size * 2)))
      iov2[:type] =  (GSSAPI::LibGSSAPI::GSS_IOV_BUFFER_TYPE_DATA)

      str.force_encoding('BINARY')
      str.sub!(/^.*Content-Type: application\/octet-stream\r\n(.*)--Encrypted.*$/m, '\1')

      len = str.unpack("L").first
      iov_data = str.unpack("LA#{len}A*")
      iov0[:buffer].value = iov_data[1]
      iov1[:buffer].value = iov_data[2]

      min_stat = FFI::MemoryPointer.new :uint32
      conf_state = FFI::MemoryPointer.new :uint32
      conf_state.write_int(1)
      qop_state = FFI::MemoryPointer.new :uint32
      qop_state.write_int(0)

      maj_stat = GSSAPI::LibGSSAPI.gss_unwrap_iov(min_stat, @gsscli.context, conf_state, qop_state, iov, iov_cnt)

      WinRM.logger.debug "SOAP message decrypted (MAJ: #{maj_stat}, MIN: #{min_stat.read_int}):\n#{iov1[:buffer].value}"

      Nokogiri::XML(iov1[:buffer].value)
    end
  end
end
