#!/usr/bin/env ruby

require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'sensu-plugin/check/cli'
require 'yaml'
require 'json'

PUPPET_DEFAULT          = '/etc/default/puppet'
PUPPET_CONF             = '/etc/puppet/puppet.conf'
PUPPET_LAST_RUN_SUMMARY = '/var/lib/puppet/state/last_run_summary.yaml'
PUPPET_PROCESS_CHECK    = '/etc/sensu/plugins/processes/check-procs.rb -p "^/usr/bin/ruby /usr/bin/puppet agent" -w 1 -C 1'

class CheckPuppet < Sensu::Plugin::Check::CLI

  option :run_interval,
         :short => "-r INTERVAL",
         :long  => "--run-interval INTERVAL",
         :proc  => proc { |p| p.to_i }

  option :enabled,
         :short => "-e ENABLED",
         :long  => "--enabled ENABLED"

  option :duration,
         :short   => "-d DURATION",
         :long    => "--duration DURATION",
         :proc    => proc { |p| p.to_i },
         :default => 600

  def run
    # --enabled
    enabled = config[:enabled]
    unless enabled
      puppet_default = File.open(PUPPET_DEFAULT).read
      match = /^START=(yes|no)\s*$/.match(puppet_default)
      enabled = match[1] if match
    end
    if enabled != 'yes'
      ok "puppet client not configured to start"
    end

    # --run-interval
    run_interval = config[:run_interval]
    unless run_interval
      puppet_conf = File.open(PUPPET_CONF).read
      match = /^runinterval\s*=\s*(\d+)\s*$/.match(puppet_conf)    
      run_interval = if match
        match[1].to_i
      else
        1800
      end
    end
    
    # checking stage
    # is puppet process running?
    check_proc = `#{PUPPET_PROCESS_CHECK}`
    data = /^\w+\s+(OK|WARNING|CRITICAL):\s*(.*)$/.match(check_proc)
    process = {
      :status  => data[1],
      :message => data[2]
    }
    if process[:status] == 'CRITICAL'
      critical "puppet process is not running"
    end

    # did puppet run in time?
    last_run_summary = YAML.load_file(PUPPET_LAST_RUN_SUMMARY)    
    time_last_run = last_run_summary["time"]["last_run"]
    now = Time.now.to_i
    if (now - time_last_run) > (run_interval + config[:duration])
      how_long = now - time_last_run
      hours = how_long / 3600
      minutes = (how_long - hours * 3600) / 60
      seconds = how_long - hours * 3600 - minutes * 60
      text = "Puppet didn't run in #{hours} hrs, #{minutes} min, #{seconds} sec, "
      text += "should run in #{run_interval + config[:duration]} seconds "
      text += "from now (runinterval=#{run_interval}, duration=#{config[:duration]})"   
      if File.exist?("/var/lib/puppet/state/agent_disabled.lock")
        agent_lock = IO.readlines("/var/lib/puppet/state/agent_disabled.lock")[0]
        reason = JSON.parse(agent_lock)
        message = reason["disabled_message"]
        ok "Administratively disabled (Reason: \'#{message}\')"
      end
      critical text
    end    

    # did puppet run with errors?
    events = last_run_summary["events"]
    resources = last_run_summary["resources"]

    if events && resources
      events_failure = events["failure"]
      resources_failed = resources["failed"]
      resources_failed_to_restart = resources["failed_to_restart"]

      if events_failure != 0 || resources_failed != 0 || 
         resources_failed_to_restart != 0
        
        text = "Puppet ran with errors: "
        if events_failure != 0
          text += "events/failure=#{events_failure}; "
        end
        if resources_failed != 0
          text += "resources/failed=#{resources_failed}; "
        end
        if resources_failed_to_restart != 0
          text += "resources/failed_to_restart=#{resources_failed_to_restart};"
        end

        text += " #{process[:message]};" if process[:status] == "WARNING"
        warning text
      else
        if process[:status] == 'WARNING'
          warning process[:message]
        else
          ok "Puppet ran successfully"
        end
      end
    else
      text = "Puppet ran with error on server"
      text += ", #{process[:message]}" if process[:status] == "WARNING"
      warning text
    end

  end

end

