require 'rubygems'
require 'json'

module Sfp::Module
	class Machine
		include Sfp::Resource

		def update_state
			@state['running'] = true

			# get memory info
			mem = `free`
			mem = mem.split("\n")[1].split(" ")
			@state["memory_total"] = mem[1].to_i
			@state["memory_free"] = mem[3].to_i

			# get platform, architecture, kernel version
			@state["os"] = `uname -s`.strip
			@state["version"] = `uname -r`.strip
			@state["arch"] = `uname -p`.strip
			@state["platform"] = `cat /etc/issue`.strip
			@state["cpus"] = `cat /proc/cpuinfo | grep processor | wc -l`.strip.to_i

			# network configuration
			@state["hostname"] = `uname -n`.strip
			@state['address'] = ''
			
			#@state["domainname"] = Nuri::Util.domainname
			#@state["ip_addr"] = Nuri::Util.local_ip
			#if system_info.has_key?(@name) and system_info[@name].to_s.length > 0
			#	@state['address'] = system_info[@name]
			#else
			#	@state['address'] = @state['ip_addr'] #@state['domainname']
			#end
		end

		def stop
			return !!system('/sbin/shutdown -h now')
		end
	end
end
