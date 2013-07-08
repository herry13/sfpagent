require File.expand_path(File.dirname(__FILE__)) + "/../package/package.rb"

class Sfp::Module::Service < Sfp::Module::Package
	ServiceCommand = (File.exist?('/usr/bin/service') ? '/usr/bin/service' : '/sbin/service') if
		!const_defined?(:ServiceCommand)

	include Sfp::Resource

	def update_state
		self.reset
		@state['installed'] = Sfp::Module::Package.installed?(@model['package_name'])
		@state['version'] = Sfp::Module::Package.version?(@model['package_name']).to_s
		@state['running'] = Sfp::Module::Service.running?(@model['service_name'])
	end

	def self.running?(service)
		service = service.to_s
		return false if service.length <= 0
		data = `#{ServiceCommand} #{service} status 2>/dev/null`.to_s
		return (not (data =~ /is running/).nil? or not (data =~ /start\/running/).nil?)
	end

	def start(p={})
		service = @model['service_name'].to_s.strip
		return false if service.length <= 0
		return true if Sfp::Module::Service.running?(service)
		result = `sudo #{ServiceCommand} #{service} start`.to_s.downcase
		return (result =~ /.*(running|done).*/)
	end

	def stop(p={})
		service = @model['service_name'].to_s.strip
		return false if service.length <= 0
		return true if not Sfp::Module::Service.running?(service)
		result = `sudo #{ServiceCommand} #{service} stop`.to_s.downcase
		return (result =~ /.*(stop|done).*/)
	end
end