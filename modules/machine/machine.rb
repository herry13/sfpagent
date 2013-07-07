require 'rubygems'
require 'json'

class Sfp::Module::Machine
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
	end

	def stop
		return !!system('/sbin/shutdown -h now')
	end
end
