require 'augeas' # require package libaugeas-ruby (Ubuntu)

require File.expand_path(File.dirname(__FILE__)) + '/../service/service.rb'

class Sfp::Module::Apache < Sfp::Module::Service
	include Sfp::Resource

	ConfigFile = '/etc/apache2/sites-available/default'
	InstallingLockFile = '/tmp/sfp_apache_installing.lock'
	NotRunningLockFile = '/tmp/sfp_apache_not_running.lock'

	def init2
		@php_package = Sfp::Module::Package.new
		@php_package.init({'package_name' => 'libapache2-mod-php5'}, {'package_name' => 'libapache2-mod-php5'})

		@php_mysql_package = Sfp::Module::Package.new
		@php_mysql_package.init({'package_name' => 'php5-mysql'}, {'package_name' => 'php5-mysql'})
	end

	def update_state
		# Call method 'update_state' of Sfp::Module::Service (superclass)
		self.class.superclass.instance_method(:update_state).bind(self).call

		@state['php_module'] = Sfp::Module::Package.installed?('libapache2-mod-php5')
		@state['php_mysql_module'] = Sfp::Module::Package.installed?('php5-mysql')

		if File.exist?(InstallingLockFile)
			@state['installed'] = @state['running'] = false
			@state['version'] = ''
		else
			@state['installed'] = Sfp::Module::Package.installed?('apache2')
			@state['running'] = (File.exist?(NotRunningLockFile) ? false : Sfp::Module::Service.running?('apache2'))
			@state['version'] = Sfp::Module::Package.version?('apache2').to_s
		end

		# port
		data = (File.file?("/etc/apache2/ports.conf") ? `/bin/grep -e "^Listen " /etc/apache2/ports.conf` : "")
		@state['port'] = (data.length > 0 ?	@state["port"] = data.split(' ')[1].to_i : 0)

		# document root
		data = (File.file?(ConfigFile) ? `/bin/grep -e "DocumentRoot " #{ConfigFile}` : "")
		@state['document_root'] = (data.length > 0 ? data.strip.split(' ')[1] : '')

		# ServerName
		data = (File.file?(ConfigFile) ? `/bin/grep -e "ServerName " #{ConfigFile}` : "")
		@state['server_name'] = (data.length > 0 ? data.strip.split(' ')[1] : '')
	end

	def install(p={})
		begin
			File.open(InstallingLockFile, 'w') { |f| f.write(' ') }
			return (self.class.superclass.instance_method(:install).bind(self).call and
				self.stop)
		rescue
		ensure
			File.delete(InstallingLockFile) if File.exist?(InstallingLockFile)
		end
		false
	end

	def uninstall(p={})
		begin
			if self.class.superclass.instance_method(:uninstall).bind(self).call
				system('/bin/rm -rf /etc/apache2') if File.directory?('/etc/apache2')
				return true
			end
		rescue
		end
		false
	end

	def set_port(p={})
		return false if p['target'].nil?
		port = p['target']
		Augeas::open do |aug|
			aug.set("/files/etc/apache2/ports.conf/*[self::directive='NameVirtualHost']/arg",
				"*:#{port}")
			aug.set("/files/etc/apache2/ports.conf/*[self::directive='Listen']/arg", port.to_s)
			aug.set('/files/etc/apache2/sites-available/default/VirtualHost/arg', "*:#{port}")
			return true if aug.save
		end
		false
	end

	def set_document_root(p={})
		return false if not p.has_key?('target')
		Augeas::open do |aug|
			aug.set("/files/etc/apache2/sites-available/default/VirtualHost/*[self::directive='DocumentRoot']/arg", p['target'].to_s)
			return true if aug.save
		end
		false
	end

	def set_server_name(p={})
		return false if not p.has_key?('target')
		server_name = p['target'].to_s
		data = File.read(ConfigFile)
		output = ""
		data.split("\n").each do |line|
			tuple = line.strip.split(' ')
			if tuple[0] == 'ServerName'
				# skip
			elsif tuple[0] == 'DocumentRoot'
				output += "#{line} \n"
				output += "ServerName #{server_name}\n"
			elsif line.strip != ''
				output += "#{line} \n"
			end
		end
		File.open(ConfigFile, 'w') { |f| f.write(output) }
		true
	end

	def install_php_mysql_module(p={})
		begin
			File.open(NotRunningLockFile, 'w') { |f| f.write(' ') }
			return self.stop if @php_mysql_package.install
		rescue
		ensure
			File.delete(NotRunningLockFile) if File.exist?(NotRunningLockFile)
		end
		false
	end

	def uninstall_php_mysql_module(p={})
		begin
			File.open(NotRunningLockFile, 'w') { |f| f.write(' ') }
			return self.stop if @php_mysql_package.uninstall
		rescue
		ensure
			File.delete(NotRunningLockFile) if File.exist?(NotRunningLockFile)
		end
		false
	end

	def install_php_module(p={})
		begin
			self.init2 if @php_package.nil?
			File.open(NotRunningLockFile, 'w') { |f| f.write(' ') }
			return self.stop if @php_package.install
		rescue Exception => e
			Sfp::Agent.logger.error e.to_s + "\n" + e.backtrace.join("\n")
		ensure
			File.delete(NotRunningLockFile) if File.exist?(NotRunningLockFile)
		end
		false
	end

	def uninstall_php_module(p={})
		begin
			File.open(NotRunningLockFile, 'w') { |f| f.write(' ') }
			return self.stop if @php_package.uninstall
		rescue
		ensure
			File.delete(NotRunningLockFile) if File.exist?(NotRunningLockFile)
		end
		false
	end
end
