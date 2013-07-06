require 'rubygems'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'thread'
require 'uri'
require 'net/http'
require 'logger'

module Sfp
	module Agent
		if Process.euid == 0
			CachedDir = '/var/sfpagent'
		else
			CachedDir = File.expand_path('~/.sfpagent')
		end
		system("mkdir #{CachedDir}") if not File.exist?(CachedDir)

		DefaultPort = 1314
		PIDFile = "#{CachedDir}/sfpagent.pid"
		LogFile = "#{CachedDir}/sfpagent.log"
		ModelFile = "#{CachedDir}/sfpagent.model"

		@@logger = WEBrick::Log.new(LogFile, WEBrick::BasicLog::INFO ||
		                                     WEBrick::BasicLog::ERROR ||
		                                     WEBrick::BasicLog::FATAL ||
		                                     WEBrick::BasicLog::WARN)

		@@model_lock = Mutex.new

		# Start the agent.
		#
		# options:
		#	:daemon => true if running as a daemon, false if as a normal application
		#	:port
		#	:ssl
		#	:certfile
		#	:keyfile
		#
		def self.start(p={})
			# check modules directory, and create it if it's not exist
			p[:modules_dir] = "#{CachedDir}/modules" if p[:modules_dir].to_s.strip == ''
			p[:modules_dir] = File.expand_path(p[:modules_dir].to_s)
			p[:modules_dir].chop! if p[:modules_dir][-1,1] == '/'
			Dir.mkdir(p[:modules_dir], 0700) if not File.exists?(p[:modules_dir])

			@@config = p

			server_type = (p[:daemon] ? WEBrick::Daemon : WEBrick::SimpleServer)
			port = (p[:port] ? p[:port] : DefaultPort)

			config = {:Host => '0.0.0.0', :Port => port, :ServerType => server_type,
			          :Logger => @@logger}
			if p[:ssl]
				config[:SSLEnable] = true
				config[:SSLVerifyClient] = OpenSSL::SSL::VERIFY_NONE
				config[:SSLCertificate] = OpenSSL::X509::Certificate.new(File.open(p[:certfile]).read)
				config[:SSLPrivateKey] = OpenSSL::PKey::RSA.new(File.open(p[:keyfile]).read)
				config[:SSLCertName] = [["CN", WEBrick::Utils::getservername]]
			end

			begin
				load_modules(p)
				reload_model

				server = WEBrick::HTTPServer.new(config)
				server.mount("/", Sfp::Agent::Handler, @@logger)

				fork {
					# send request to save PID
					sleep 2
					url = URI.parse("http://localhost:#{config[:Port]}/pid")
					http = Net::HTTP.new(url.host, url.port)
					http.use_ssl = p[:ssl]
					http.verify_mode = OpenSSL::SSL::VERIFY_NONE
					req = Net::HTTP::Get.new(url.path)
					http.request(req)
					puts "\nSFP Agent is running with PID #{File.read(PIDFile)}"
				}

				trap('INT') { server.shutdown }

				server.start
			rescue Exception => e
				@@logger.error "Starting the agent [Failed] #{e}"
				raise e
			end
		end

		# Stop the agent's daemon.
		#
		def self.stop
			pid = (File.exist?(PIDFile) ? File.read(PIDFile).to_i : nil)
			if not pid.nil? and `ps hf #{pid}`.strip =~ /.*sfpagent.*/
				print "Stopping SFP Agent with PID #{pid} "
				Process.kill('KILL', pid)
				puts "[OK]"
				@@logger.info "SFP Agent daemon has been stopped."
			else
				puts "SFP Agent is not running."
			end
			File.delete(PIDFile) if File.exist?(PIDFile)
		end

		# Print the status of the agent.
		#
		def self.status
			pid = (File.exist?(PIDFile) ? File.read(PIDFile).to_i : nil)
			if pid.nil?
				puts "SFP Agent is not running."
			else
				if `ps hf #{pid}`.strip =~ /.*sfpagent.*/
					puts "SFP Agent is running with PID #{pid}"
				else
					File.delete(PIDFile)
					puts "SFP Agent is not running."
				end
			end
		end

		# Save given model to cached file, and then reload the model.
		#
		def self.set_model(model)
			begin
				@@model_lock.synchronize {
					@@logger.info "Setting the model [Wait]"
					File.open(ModelFile, 'w', 0644) { |f|
						f.write(JSON.generate(model))
						f.flush
					}
				}
				reload_model
				@@logger.info "Setting the model [OK]"
				return true
			rescue Exception => e
				@@logger.error "Setting the model [Failed] #{e}"
			end
			false
		end

		# Return the model which is read from cached file.
		#
		def self.get_model
			return nil if not File.exist?(ModelFile)
			begin
				@@model_lock.synchronize {
					File.open(ModelFile, 'r') { |f|
						return JSON[f.read]
					}
				}
			rescue Exception => e
				@@logger.error "Get the model [Failed] #{e}\n#{e.backtrace}"
			end
			false
		end

		# Reload the model from cached file.
		#
		def self.reload_model
			model = get_model
			if model.nil?
				@@logger.info "There is no model in cache."
			else
				begin
					@@runtime = Sfp::Runtime.new(model)
					@@logger.info "Reloading the model in cache [OK]"
				rescue Exception => e
					@@logger.error "Reloading the model in cache [Failed] #{e}"
				end
			end
		end

		# Return the current state of the model.
		#
		def self.get_state
			return nil if !defined? @@runtime or @@runtime.nil?
			begin
				return @@runtime.get_state
			rescue Exception => e
				@@logger.error "Get state [Failed] #{e}"
			end
			false
		end

		# Execute an action
		#
		# @param action contains the action's schema.
		#
		def self.execute_action(action)
			logger = (p[:daemon] ? @@logger : Logger.new(STDOUT))
			begin
				@@runtime.execute_action(action)
				logger.info "Executing #{action['name']} [OK]"
				return true
			rescue Exception => e
				logger.info "Executing #{action['name']} [Failed] #{e}"
			end
			false
		end

		# Load all modules in given directory.
		#
		# options:
		#	:dir => directory that holds all modules
		#
		def self.load_modules(p={})
			dir = p[:modules_dir]

			logger = (p[:daemon] ? @@logger : Logger.new(STDOUT))
			@@modules = []
			counter = 0
			if dir != '' and File.exist?(dir)
				logger.info "Modules directory: #{dir}"
				Dir.entries(dir).each { |name|
					next if name == '.' or name == '..' or File.file?("#{dir}/#{name}")
					module_file = "#{dir}/#{name}/#{name}.rb"
					next if not File.exist?(module_file)
					begin
						load module_file #require module_file
						logger.info "Loading module #{dir}/#{name} [OK]"
						counter += 1
						@@modules << name
					rescue Exception => e
						logger.warn "Loading module #{dir}/#{name} [Failed]\n#{e}"
					end
				}
			end
			logger.info "Successfully loading #{counter} modules."
		end

		def self.get_schemata(module_name)
			dir = @@config[:modules_dir]

			filepath = "#{dir}/#{module_name}/#{module_name}.sfp"
			sfp = parse(filepath).root
			sfp.accept(Sfp::Visitor::ParentEliminator.new)
			JSON.generate(sfp)
		end

		def self.get_modules
			(defined?(@@modules) and @@modules.is_a?(Array) ? @@modules : [])
		end

		def self.delete_module(name)
			return false if @@config[:modules_dir] == ''
			
			module_dir = "#{@@config[:modules_dir]}/#{name}"
			if File.directory?(module_dir)
				result = !!system("rm -rf #{module_dir}")
			else
				result = true
			end
			load_modules(@@config)
			@@logger.info "Deleting module #{name} " + (result ? "[OK]" : "[Failed]")
			result
		end

		def self.install_module(name, data)
			return false if @@config[:modules_dir] == ''

			if !File.directory? @@config[:modules_dir]
				File.delete @@config[:modules_dir] if File.exist? @@config[:modules_dir]
				Dir.mkdir(@@config[:modules_dir], 0700)
			end

			# delete old files
			module_dir = "#{@@config[:modules_dir]}/#{name}"
			system("rm -rf #{module_dir}") if File.exist? module_dir

			# save the archive
			Dir.mkdir("#{module_dir}", 0700)
			File.open("#{module_dir}/data.tgz", 'wb', 0600) { |f| f.syswrite data }

			# extract the archive and the files
			system("cd #{module_dir}; tar xvf data.tgz")
			Dir.entries(module_dir).each { |name|
				next if name == '.' or name == '..'
				if File.directory? "#{module_dir}/#{name}"
					system("cd #{module_dir}/#{name}; mv * ..; cd ..; rm -rf #{name}")
				end
				system("cd #{module_dir}; rm data.tgz")
			}
			load_modules(@@config)
			@@logger.info "Installing module #{name} [OK]"

			true
		end

		def self.get_log
			return '' if not File.exist?(LogFile)
			File.read(LogFile)
		end

		class Handler < WEBrick::HTTPServlet::AbstractServlet
			def initialize(server, logger)
				@logger = logger
			end

			def query_to_json(query, json=false)
				return query['json'] if json
				JSON[query['json']]
			end

			# Process HTTP Get request
			#
			# uri:
			#	/pid => save daemon's PID to a file
			#	/state => return the current state
			#	/model => return the current model
			#	/schemata => return the schemata of a module
			#	/modules => return a list of available modules
			#
			def do_GET(request, response)
				status = 400
				content_type, body = ''
				if not trusted(request.peeraddr[2])
					status = 403
				else
					path = (request.path[-1,1] == '/' ? request.path.chop : request.path)
					if path == '/pid' and request.peeraddr[2] == 'localhost'
						status, content_type, body = save_pid

					elsif path == '/state'
						status, content_type, body = get_state

					elsif path =~ /^\/state\/.+/
						status, content_type, body = get_state({:path => path[7, path.length-7]})

					elsif path == '/model'
						status, content_type, body = get_model

					elsif path =~ /^\/schemata\/.+/
						status, content_type, body = get_schemata({:module => path[10, path.length-10]})

					elsif path == '/modules'
						status, content_type, body = [200, 'application/json', JSON.generate(Sfp::Agent.get_modules)]

					elsif path == '/log'
						status, content_type, body = [200, 'text/plain', Sfp::Agent.get_log]

					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			# Handle HTTP Post request
			#
			# uri:
			#	/execute => receive an action's schema and execute it
			#
			def do_POST(request, response)
				status = 400
				content_type, body = ''
				if not self.trusted(request.peeraddr[2])
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)
					if path == '/execute'
						status, content_type, body = self.execute({:action => query_to_json(request.query)})
					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			# uri:
			#	/model => receive a new model and save to cached file
			#	/modules => store a module
			#
			def do_PUT(request, response)
				status = 400
				content_type, body = ''
				if not self.trusted(request.peeraddr[2])
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)

					if path == '/model'
						status, content_type, body = self.set_model({:query => request.query})
# :model => query_to_json(request.query)})

					elsif path =~ /\/modules\/.+/
						status, content_type, body = self.manage_module({:name => path[9, path.length-9],
						                                                 :query => request.query})
					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			def manage_module(p={})
				p[:name], _ = p[:name].split('/', 2)
				if p[:query].has_key?('module')
					return [200, '', ''] if Sfp::Agent.install_module(p[:name], p[:query]['module'])
				else
					return [200, '', ''] if Sfp::Agent.delete_module(p[:name])
				end
				[500, '', '']
			end

			def get_schemata(p={})
				begin
					module_name, _ = p[:module].split('/', 2)
					return [200, 'application/json', Sfp::Agent.get_schemata(module_name)]
				rescue Exception => e
					@logger.error "Sending schemata [Failed]\n#{e}"
				end
				[500, '', '']
			end

			def get_state(p={})
				state = Sfp::Agent.get_state

				# The model is not exist.
				return [404, 'text/plain', 'There is no model!'] if state.nil?

				if !!state
					state = state.at?("$." + p[:path].gsub(/\//, '.')) if !!p[:path]
					return [200, 'application/json', JSON.generate({'state'=>state})]
				end

				# There is an error when retrieving the state of the model!
				[500, '', '']
			end

			def set_model(p={})
				if p[:query].has_key?('model')
					# Setting the model was success, and then return '200' status.
					return [200, '', ''] if Sfp::Agent.set_model(JSON[p[:query]['model']])
				else
					# Remove the existing model by setting an empty model
					return [200, '', ''] if Sfp::Agent.set_model({})
				end

				# There is an error on setting the model!
				[500, '', '']
			end

			def get_model
				model = Sfp::Agent.get_model

				# The model is not exist.
				return [404, '', ''] if model.nil?

				# The model is exist, and then send the model in JSON.
				return [200, 'application/json', JSON.generate(model)] if !!model

				# There is an error when retrieving the model!
				[500, '', '']
			end

			def execute(p={})
				return [200, '', ''] if Sfp::Agent.execute_action(p[:action])
				[500, '', '']
			end

			def save_pid
				begin
					File.open(PIDFile, 'w', 0644) { |f| f.write($$.to_s) }
					return [200, '', $$.to_s]
				rescue Exception
				end
				[500, '', '']
			end

			def trusted(address)
				true
			end
		end
	end

	def self.require(gem, pack=nil)
		require gem
	rescue LoadError => e
		system("gem install #{pack||gem} --no-ri --no-rdoc")
		require gem
	end
end
