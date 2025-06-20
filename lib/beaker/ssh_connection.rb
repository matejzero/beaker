require 'socket'
require 'timeout'
require 'net/scp'

module Beaker
  class SshConnection
    attr_accessor :logger, :ip, :vmhostname, :hostname, :ssh_connection_preference

    SUPPORTED_CONNECTION_METHODS = %i[ip vmhostname hostname]

    RETRYABLE_EXCEPTIONS = [
      SocketError,
      Timeout::Error,
      Errno::ETIMEDOUT,
      Errno::EHOSTDOWN,
      Errno::EHOSTUNREACH,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::ENETUNREACH,
      Net::SSH::Exception,
      Net::SSH::Disconnect,
      Net::SSH::AuthenticationFailed,
      Net::SSH::ChannelRequestFailed,
      Net::SSH::ChannelOpenFailed,
      IOError,
    ]

    def initialize name_hash, user = nil, ssh_opts = {}, options = {}
      @vmhostname = name_hash[:vmhostname]
      @ip = name_hash[:ip]
      @hostname = name_hash[:hostname]
      @user = user
      @ssh_opts = ssh_opts
      @logger = options[:logger]
      @options = options
      @ssh_connection_preference = @options[:ssh_connection_preference]
    end

    def self.connect name_hash, user = 'root', ssh_opts = {}, options = {}
      connection = new name_hash, user, ssh_opts, options
      connection.connect
      connection
    end

    # Setup and return the ssh connection object
    #
    # @note For more information about Net::SSH library, check out these docs:
    #       - {https://net-ssh.github.io/net-ssh/ Base Net::SSH docs}
    #       - {http://net-ssh.github.io/net-ssh/Net/SSH.html#method-c-start Net::SSH.start method docs}
    #       - {https://net-ssh.github.io/net-ssh/Net/SSH/Connection/Session.html Net::SSH::Connection::Session class docs}
    #
    # @param [String] host hostname of the machine to connect to
    # @param [String] user username to login to the host as
    # @param [Hash{Symbol=>String}] ssh_opts Options hash passed directly to Net::SSH.start method
    # @param [Hash{Symbol=>String}] options Options hash to control method conditionals
    # @option options [Integer] :max_connection_tries Limit the number of connection start
    #                                                 tries to this number (default: 11)
    # @option options [Boolean] :silent Stops logging attempt failure messages if set to true
    #                                   (default: true)
    #
    # @return [Net::SSH::Connection::Session] session returned from Net::SSH.start method
    def connect_block host, user, ssh_opts, options
      try = 1
      last_wait = 2
      wait = 3
      max_connection_tries = options[:max_connection_tries] || 11
      begin
        @logger.debug "Attempting ssh connection to #{host}, user: #{user}, opts: #{ssh_opts}"

        # Work around net-ssh 6+ incompatibilities
        if ssh_opts.include?(:strict_host_key_checking) && (Net::SSH::Version::CURRENT.major > 5)
          strict_host_key_checking = ssh_opts.delete(:strict_host_key_checking)

          unless ssh_opts[:verify_host_key].is_a?(Symbol)
            ssh_opts[:verify_host_key] ||= strict_host_key_checking ? :always : :never
          end
        end

        Net::SSH.start(host, user, ssh_opts)
      rescue *RETRYABLE_EXCEPTIONS => e
        if try <= max_connection_tries
          @logger.warn "Try #{try} -- Host #{host} unreachable: #{e.class.name} - #{e.message}" unless options[:silent]
          @logger.warn "Trying again in #{wait} seconds" unless options[:silent]

          sleep wait
          (last_wait, wait) = wait, last_wait + wait
          try += 1

          retry
        else
          @logger.warn "Failed to connect to #{host}, after #{try} attempts" unless options[:silent]
          nil
        end
      end
    end

    # Connect to the host, creating a new connection if required
    #
    # @param [Hash{Symbol=>String}] options Options hash to control method conditionals
    # @option options [Integer] :max_connection_tries {#connect_block} option
    # @option options [Boolean] :silent {#connect_block} option
    def connect options = {}
      # Try three ways to connect to host (vmhostname, ip, hostname)
      # Try each method in turn until we succeed
      methods = @ssh_connection_preference.dup
      while (not @ssh) && (not methods.empty?)
        if instance_variable_get(:"@#{methods[0]}").nil?
          @logger.warn "Skipping #{methods[0]} method to ssh to host as its value is not set. Refer to https://github.com/puppetlabs/beaker/tree/master/docs/how_to/ssh_connection_preference.md to remove this warning"
        elsif SUPPORTED_CONNECTION_METHODS.include?(methods[0])
          @ssh = connect_block(instance_variable_get(:"@#{methods[0]}"), @user, @ssh_opts, options)
        else
          @logger.warn "Beaker does not support #{methods[0]} to SSH to host, trying next available method."
          @ssh_connection_preference.delete(methods[0])
        end
        methods.shift
      end
      unless @ssh
        @logger.error "Failed to connect to #{@hostname}, attempted #{@ssh_connection_preference.join(', ')}"
        raise RuntimeError, "Cannot connect to #{@hostname}"
      end
      @ssh
    end

    # closes this SshConnection
    def close
      begin
        if @ssh and not @ssh.closed?
          @ssh.close
        else
          @logger.warn("ssh.close: connection is already closed, no action needed")
        end
      rescue *RETRYABLE_EXCEPTIONS => e
        @logger.warn "Attemped ssh.close, (caught #{e.class.name} - #{e.message})."
      rescue => e
        @logger.warn "ssh.close threw unexpected Error: #{e.class.name} - #{e.message}.  Shutting down, and re-raising error below"
        @ssh.shutdown!
        raise e
      ensure
        @ssh = nil
        @logger.debug("ssh connection to #{@hostname} has been terminated")
      end
    end

    # Wait for the ssh connection to fail, returns true on connection failure and false otherwise
    # @param [Hash{Symbol=>String}] options Options hash to control method conditionals
    # @option options [Boolean] :pty Should we request a terminal when attempting
    #                                to send a command over this connection?
    # @option options [String] :stdin Any input to be sent along with the command
    # @param [IO] stdout_callback An IO stream to send connection stdout to, defaults to nil
    # @param [IO] stderr_callback An IO stream to send connection stderr to, defaults to nil
    # @return [Boolean] true if connection failed, false otherwise
    def wait_for_connection_failure options = {}, stdout_callback = nil, stderr_callback = stdout_callback
      try = 1
      last_wait = 2
      wait = 3
      command = 'echo echo' # can be run on all platforms (I'm looking at you, windows)
      while try < 11
        result = Result.new(@hostname, command)
        begin
          @logger.notify "Waiting for connection failure on #{@hostname} (attempt #{try}, try again in #{wait} second(s))"
          @logger.debug("\n#{@hostname} #{Time.new.strftime('%H:%M:%S')}$ #{command}")
          @ssh.open_channel do |channel|
            request_terminal_for(channel, command) if options[:pty]

            channel.exec(command) do |terminal, success|
              raise Net::SSH::Exception.new("FAILED: to execute command on a new channel on #{@hostname}") unless success

              register_stdout_for terminal, result, stdout_callback
              register_stderr_for terminal, result, stderr_callback
              register_exit_code_for terminal, result

              process_stdin_for(terminal, options[:stdin]) if options[:stdin]
            end
          end
          loop_tries = 0
          # loop is actually loop_forever, so let it try 3 times and then quit instead of endless blocking
          @ssh.loop { loop_tries += 1; loop_tries < 4 }
        rescue *RETRYABLE_EXCEPTIONS => e
          @logger.debug "Connection on #{@hostname} failed as expected (#{e.class.name} - #{e.message})"
          close # this connection is bad, shut it down
          return true
        end
        slept = 0
        stdout_callback.call("sleep #{wait} second(s): ")
        while slept < wait
          sleep slept
          stdout_callback.call('.')
          slept += 1
        end
        stdout_callback.call("\n")
        (last_wait, wait) = wait, last_wait + wait
        try += 1
      end
      false
    end

    def try_to_execute command, options = {}, stdout_callback = nil, stderr_callback = stdout_callback
      result = Result.new(@hostname, command)

      @ssh.open_channel do |channel|
        request_terminal_for(channel, command) if options[:pty]

        channel.exec(command) do |terminal, success|
          raise Net::SSH::Exception.new("FAILED: to execute command on a new channel on #{@hostname}") unless success

          register_stdout_for terminal, result, stdout_callback
          register_stderr_for terminal, result, stderr_callback
          register_exit_code_for terminal, result

          process_stdin_for(terminal, options[:stdin]) if options[:stdin]
        end
      end

      # Process SSH activity until we stop doing that - which is when our
      # channel is finished with...
      begin
        @ssh.loop
      rescue *RETRYABLE_EXCEPTIONS => e
        # this would indicate that the connection failed post execution, since the channel exec was successful
        @logger.warn "ssh channel on #{@hostname} received exception post command execution #{e.class.name} - #{e.message}"
        close
      end

      result.finalize!
      @logger.last_result = result
      result
    end

    # Execute a command on a host, ensuring a connection exists first
    #
    # @param [Hash{Symbol=>String}] options Options hash to control method conditionals
    # @option options [Integer] :max_connection_tries {#connect_block} option (passed through {#connect})
    # @option options [Boolean] :silent {#connect_block} option (passed through {#connect})
    def execute command, options = {}, stdout_callback = nil,
                stderr_callback = stdout_callback
      # ensure that we have a current connection object
      connect(options)
      try_to_execute(command, options, stdout_callback, stderr_callback)
    end

    def request_terminal_for channel, command
      channel.request_pty do |_ch, success|
        if success
          @logger.debug "Allocated a PTY on #{@hostname} for #{command.inspect}"
        else
          raise Net::SSH::Exception.new("FAILED: could not allocate a pty when requested on " +
            "#{@hostname} for #{command.inspect}")
        end
      end
    end

    def register_stdout_for channel, output, callback = nil
      channel.on_data do |_ch, data|
        callback[data] if callback
        output.stdout << data
        output.output << data
      end
    end

    def register_stderr_for channel, output, callback = nil
      channel.on_extended_data do |_ch, type, data|
        if type == 1
          callback[data] if callback
          output.stderr << data
          output.output << data
        end
      end
    end

    def register_exit_code_for channel, output
      channel.on_request("exit-status") do |_ch, data|
        output.exit_code = data.read_long
      end
    end

    def process_stdin_for channel, stdin
      # queue stdin data, force it to packets, and signal eof: this
      # triggers action in many remote commands, notably including
      # 'puppet apply'.  It must be sent at some point before the rest
      # of the action.
      channel.send_data stdin.to_s
      channel.process
      channel.eof!
    end

    def scp_to source, target, options = {}
      local_opts = options.dup
      local_opts[:recursive] = File.directory?(source) if local_opts[:recursive].nil?
      local_opts[:chunk_size] ||= 16384

      result = Result.new(@hostname, [source, target])
      result.stdout = "\n"

      begin
        # This is probably windows with an environment variable so we need to
        # expand it.
        target = self.execute(%{echo "#{target}"}).output.strip.delete('"') if target.include?('%')

        @ssh.scp.upload! source, target, local_opts do |_ch, name, sent, total|
          result.stdout << (format("\tcopying %s: %10d/%d\n", name, sent, total))
        end
      rescue => e
        logger.warn "#{e.class} error in scp'ing. Forcing the connection to close, which should " <<
                    "raise an error."
        close
      end

      # Setting these values allows reporting via result.log(test_name)
      result.stdout << "  SCP'ed file #{source} to #{@hostname}:#{target}"

      # Net::Scp always returns 0, so just set the return code to 0.
      result.exit_code = 0

      result.finalize!
      return result
    end

    def scp_from source, target, options = {}
      local_opts = options.dup
      local_opts[:recursive] = true if local_opts[:recursive].nil?
      local_opts[:chunk_size] ||= 16384

      result = Result.new(@hostname, [source, target])
      result.stdout = "\n"

      begin
        # This is probably windows with an environment variable so we need to
        # expand it.
        source = self.execute(%{echo "#{source}"}).output.strip.delete('"') if source.include?('%')

        @ssh.scp.download! source, target, local_opts do |_ch, name, sent, total|
          result.stdout << (format("\tcopying %s: %10d/%d\n", name, sent, total))
        end
      rescue => e
        logger.warn "#{e.class} error in scp'ing. Forcing the connection to close, which should " <<
                    "raise an error."
        close
      end

      # Setting these values allows reporting via result.log(test_name)
      result.stdout << "  SCP'ed file #{@hostname}:#{source} to #{target}"

      # Net::Scp always returns 0, so just set the return code to 0.
      result.exit_code = 0

      result.finalize!
      result
    end
  end
end
