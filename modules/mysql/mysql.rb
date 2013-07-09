require 'augeas'

require File.expand_path(File.dirname(__FILE__)) + '/../service/service.rb'

class Sfp::Module::Mysql < Sfp::Module::Service
	include Sfp::Resource

	def update_state
		# package mysql-server: installed, version, running
		@state['installed'] = Sfp::Module::Package.installed?(@model['package_name'])
		@state['version'] = Sfp::Module::Package.version?(@model['package_name'])
		@state['running'] = Sfp::Module::Service.running?(@model['package_name'])

		# port
		data = (File.file?("/etc/mysql/my.cnf") ? `/bin/grep -e "^port" /etc/mysql/my.cnf` : "")
		@state['port'] = (data.length > 0 ? data.split('=')[1].strip.to_i : 3306)

		# root password
		if File.file?('/etc/mysql/nuri.cnf')
			@state["root_password"] = `cat /etc/mysql/nuri.cnf 2>/dev/null`.to_s.sub(/\n$/,'')
		else
			@state['root_password'] = ''
		end

		# can be accessed from outside?
		if @state['installed']
			data = `grep '^bind-address' /etc/mysql/my.cnf 2>/dev/null`
			@state['public'] = (data.length <= 0)
		else
			@state['public'] = false
		end
	end
	
	def install(params={})
#		return (Nuri::Helper::Command.exec('echo mysql-server mysql-server/root_password select mysql | debconf-set-selections') and
#			Nuri::Helper::Command.exec('echo mysql-server mysql-server/root_password_again select mysql | debconf-set-selections') and
#			Nuri::Helper::Package.install('mysql-server') and
#			Nuri::Helper::Command.exec('echo "\n[mysqld]\nmax_connect_errors = 10000" >> /etc/mysql/my.cnf') and
#			Nuri::Helper::Service.stop('mysql') and
#			Nuri::Helper::Command.exec('/bin/echo mysql > /etc/mysql/nuri.cnf') and
#			Nuri::Helper::Command.exec('/bin/chmod 0400 /etc/mysql/nuri.cnf'))
		false
	end
	
	def uninstall(params={})
#		Nuri::Helper::Command.exec('/bin/rm -f /etc/mysql/nuri.cnf') if
#			File.exist?('/etc/mysql/nuri.cnf')
#		result = Nuri::Helper::Package.uninstall('mysql-server')
#		if result == false
#			result = Nuri::Helper::Package.uninstall('mysql*')
#		end
#		#Nuri::Helper::Command.exec('/bin/rm -rf /etc/mysql') if File.exist?('/etc/mysql')
#		return result
		false
	end
	
	def start(params={})
#		return Nuri::Helper::Service.start('mysql')
		false
	end
	
	def stop(params={})
#		return Nuri::Helper::Service.stop('mysql')
		false
	end
	
	def set_port(params={})
		p = params['target']
		Augeas::open do |aug|
			paths = aug.match("/files/etc/mysql/my.cnf/*/port")
			paths.each { |path|
				aug.set(path, p.to_s)
			}
			return aug.save
		end
		false
	end

	def set_public(params={})
		if params['pub']
			cmd = '/bin/sed -i "s/^bind\-address/#bind\-address/g" /etc/mysql/my.cnf'
		else
			cmd = '/bin/sed -i "s/^#bind\-address/bind\-address/g" /etc/mysql/my.cnf'
		end
		return false if not system(cmd)
		if self.get_state('running')
			return (self.stop and self.start)
		end
		true
	end
	
	def set_root_password(params={})
		passwd = params['passwd'].to_s
		system('/bin/chmod 0600 /etc/mysql/nuri.cnf')
		oldpass = `cat /etc/mysql/nuri.cnf`.to_s.sub(/\n$/,'').sub(/"/,'\"')
		passwd.sub!(/"/,'\"')
		return (system("mysqladmin -u root -p\"#{oldpass}\" password \"#{passwd}\"") and
			system("/bin/echo \"#{passwd}\" > /etc/mysql/nuri.cnf") and
			system('/bin/chmod 0400 /etc/mysql/nuri.cnf'))
	end
end
