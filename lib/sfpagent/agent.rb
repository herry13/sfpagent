require 'rubygems'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'thread'
require 'uri'
require 'net/http'
require 'logger'
require 'json'

module Sfp
	module Agent
		NetHelper = Object.new.extend(Nuri::Net::Helper)

		CachedDir = (Process.euid == 0 ? '/var/sfpagent' : File.expand_path('~/.sfpagent'))
		Dir.mkdir(CachedDir, 0700) if not File.exist?(CachedDir)

		DefaultPort = 1314

		PIDFile = "#{CachedDir}/sfpagent.pid"
		LogFile = "#{CachedDir}/sfpagent.log"
		ModelFile = "#{CachedDir}/sfpagent.model"
		AgentsDataFile = "#{CachedDir}/sfpagent.agents"

		BSigFile = "#{CachedDir}/bsig.model"
		BSigPIDFile = "#{CachedDir}/bsig.pid"

		@@logger = WEBrick::Log.new(LogFile, WEBrick::BasicLog::INFO ||
		                                     WEBrick::BasicLog::ERROR ||
		                                     WEBrick::BasicLog::FATAL ||
		                                     WEBrick::BasicLog::WARN)

		@@bsig = nil
		@@bsig_modified_time = nil

		@@model_lock = Mutex.new
		@@runtime_lock = Mutex.new
		@@bsig_model_lock = Mutex.new

		def self.logger
			@@logger
		end

		def self.check_config(p={})
			# check modules directory, and create it if it's not exist
			p[:modules_dir] = "#{CachedDir}/modules" if p[:modules_dir].to_s.strip == ''
			p[:modules_dir] = File.expand_path(p[:modules_dir].to_s)
			p[:modules_dir].chop! if p[:modules_dir][-1,1] == '/'
			Dir.mkdir(p[:modules_dir], 0700) if not File.exists?(p[:modules_dir])
			p
		end

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
			begin
				@@config = p = check_config(p)
	
				# create web server
				server_type = (p[:daemon] ? WEBrick::Daemon : WEBrick::SimpleServer)
				port = (p[:port] ? p[:port] : DefaultPort)
				config = {:Host => '0.0.0.0', :Port => port, :ServerType => server_type,
				          :Logger => Sfp::Agent.logger }
				if p[:ssl]
					config[:SSLEnable] = true
					config[:SSLVerifyClient] = OpenSSL::SSL::VERIFY_NONE
					config[:SSLCertificate] = OpenSSL::X509::Certificate.new(File.open(p[:certfile]).read)
					config[:SSLPrivateKey] = OpenSSL::PKey::RSA.new(File.open(p[:keyfile]).read)
					config[:SSLCertName] = [["CN", WEBrick::Utils::getservername]]
				end
				server = WEBrick::HTTPServer.new(config)
				server.mount("/", Sfp::Agent::Handler, Sfp::Agent.logger)

				# load modules from cached directory
				load_modules(p)

				# reload model
				reload_model

				# create BSig execution engine
				@@bsig_engine = Sfp::BSig.new

				# trap stop-signal
				['INT', 'KILL', 'HUP'].each { |signal|
					trap(signal) {
						Sfp::Agent.logger.info "Shutting down web server"
						server.shutdown
					}
				}

				# start web server
				fork { server.start }

				# start BSig main thread
				bsig_pid = fork { @@bsig_engine.start }
				puts "BSig Engine is running with PID #{bsig_pid}"
				File.open(BSigPIDFile, 'w') { |f| f.write(bsig_pid.to_s) }

				# send request to save PID
				pid = nil
				tries = 1
				begin
					begin
						NetHelper.get_data('127.0.0.1', config[:Port], '/pid')
						pid = File.read(PIDFile) if File.exist?(PIDFile)
					rescue
						sleep tries
					end
					tries += 1
				end until not pid.nil? or tries >= 5

				if not pid.nil?
					puts "SFP Agent is running with PID #{File.read(PIDFile)}" if File.exist?(PIDFile)
				else
					Sfp::Agent.logger.warn "Cannot request PID"
				end

			rescue Exception => e
				Sfp::Agent.logger.error "Starting the agent [Failed] #{e}\n#{e.backtrace.join("\n")}"
				raise e
			end
		end

		# Stop the agent's daemon.
		#
		def self.stop
			# stopping web server (main thread)
			pid = (File.exist?(PIDFile) ? File.read(PIDFile).to_i : nil)
			if not pid.nil? and `ps h #{pid}`.strip =~ /.*sfpagent.*/
				Process.kill('HUP', pid)
				puts "Stopping SFP Agent with PID #{pid} [OK]"
				File.delete(PIDFile) if File.exist?(PIDFile)
			else
				puts "SFP Agent is not running."
			end

			# stopping BSig engine
			pid_bsig = (File.exist?(BSigPIDFile) ? File.read(BSigPIDFile).to_i : nil)
			if not pid_bsig.nil? and `ps h #{pid_bsig}`.strip =~ /.*sfpagent.*/
				Process.kill('HUP', pid_bsig)
				puts "Stopping BSig engine with PID #{pid_bsig} [OK]"
				File.delete(BSigPIDFile) if File.exist?(BSigPIDFile)
			else
				puts "BSig engine is not running."
			end

			Sfp::Agent.logger.info "SFP Agent daemon has been stopped."
		end

		def self.bsig_engine
			@@bsig_engine
		end

		# Print the status of the agent.
		#
		def self.status
			if not File.exist?(PIDFile)
				puts "SFP Agent is not running."
			else
				pid = File.read(PIDFile).to_i
				if `ps hf #{pid}`.strip =~ /.*sfpagent.*/
					puts "SFP Agent is running with PID #{pid}"
				else
					File.delete(PIDFile)
					puts "SFP Agent is not running."
				end
			end

			if not File.exist?(BSigPIDFile)
				puts "BSig engine is not running."
			else
				pid = File.read(BSigPIDFile).to_i
				if `ps hf #{pid}`.strip =~ /.*sfpagent.*/
					puts "BSig engine is running with PID #{pid}"
				else
					File.delete(BSigPIDFile)
					puts "BSig engine is not running."
				end
			end
		end

		# Save given model to cached file, and then reload the model.
		#
		def self.set_model(model)
			begin
				@@model_lock.synchronize {
					Sfp::Agent.logger.info "Setting the model [Wait]"
					File.open(ModelFile, 'w', 0600) { |f|
						f.write(JSON.generate(model))
						f.flush
					}
				}
				reload_model
				Sfp::Agent.logger.info "Setting the model [OK]"
				return true
			rescue Exception => e
				Sfp::Agent.logger.error "Setting the model [Failed] #{e}\n#{e.backtrace.join("\n")}"
			end
			false
		end

		# Return the model which is read from cached file.
		#
		def self.get_model
			return nil if not File.exist?(ModelFile)
			begin
				@@model_lock.synchronize {
					return JSON[File.read(ModelFile)]
				}
			rescue Exception => e
				Sfp::Agent.logger.error "Get the model [Failed] #{e}\n#{e.backtrace.join("\n")}"
			end
			false
		end

		# Setting a new BSig model: set @@bsig variable, and save in cached file
		#
		def self.set_bsig(bsig)
			begin
				@@bsig_model_lock.synchronize {
					Sfp::Agent.logger.info "Setting the BSig model [Wait]"
					if bsig.nil?
						File.delete(BSigFile) if File.exist?(BSigFile)
					else
						File.open(BSigFile, 'w', 0600) { |f|
							f.write(JSON.generate(bsig))
							f.flush
						}
					end
				}
				Sfp::Agent.logger.info "Setting the BSig model [OK]"
				return true
			rescue Exception => e
				Sfp::Agent.logger.error "Setting the BSig model [Failed] #{e}\n#{e.backtrace.join("\n")}"
			end
			false
		end

		# Return a BSig model from cached file
		#
		def self.get_bsig
			return nil if not File.exist?(BSigFile)
			return @@bsig if File.mtime(BSigFile) == @@bsig_modified_time

			begin
				@@bsig_model_lock.synchronize {
					@@bsig = JSON[File.read(BSigFile)]
					@@bsig_modified_time = File.mtime(BSigFile)
					return @@bsig
				}
			rescue Exception => e
				Sfp::Agent.logger.error "Get the BSig model [Failed] #{e}\n#{e.backtrace.join("\n")}"
			end
			false
		end

		# Reload the model from cached file.
		#
		def self.reload_model
			model = get_model
			if model.nil?
				Sfp::Agent.logger.info "There is no model in cache."
			else
				begin
					@@runtime_lock.synchronize { @@runtime = Sfp::Runtime.new(model) }
					Sfp::Agent.logger.info "Reloading the model in cache [OK]"
				rescue Exception => e
					Sfp::Agent.logger.error "Reloading the model in cache [Failed] #{e}\n#{e.backtrace.join("\n")}"
				end
			end
		end

		def self.whoami?
			return nil if @@runtime.nil?
			@@runtime.whoami?
		end

		# Return the current state of the model.
		#
		def self.get_state(as_sfp=true)
			@@runtime_lock.synchronize {
				return nil if !defined?(@@runtime) or @@runtime.nil?
				begin
					@@runtime.get_state if @@runtime.modules.nil?
					return @@runtime.get_state(as_sfp)
				rescue Exception => e
					Sfp::Agent.logger.error "Get state [Failed] #{e}\n#{e.backtrace.join("\n")}"
				end
			}
			false
		end

		def self.resolve(path, as_sfp=true)
			begin
				#@@runtime_lock.synchronize {
					return Sfp::Undefined.new if !defined?(@@runtime) or @@runtime.nil? or @@runtime.modules.nil?
					path = path.simplify
					_, node, _ = path.split('.', 3)
					if @@runtime.modules.has_key?(node)
						# local resolve
						parent, attribute = path.pop_ref
						mod = @@runtime.modules.at?(parent)
						if mod.is_a?(Hash)
							mod[:_self].update_state
							state = mod[:_self].state
							return state[attribute] if state.has_key?(attribute)
						end
						return Sfp::Undefined.new
					end
				#}
				agents = get_agents
				if agents[node].is_a?(Hash)
					# remote resolve
					agent = agents[node]
					path = path[1, path.length-1].gsub /\./, '/'
					code, data = NetHelper.get_data(agent['sfpAddress'], agent['sfpPort'], "/state#{path}")
					if code.to_i == 200
						state = JSON[data]['state']
						return Sfp::Unknown.new if state == '<sfp::unknown>'
						return state if !state.is_a?(String) or state[0,15] != '<sfp::undefined'
					end
				end
			rescue Exception => e
				Sfp::Agent.logger.error "Resolve #{path} [Failed] #{e}\n#{e.backtrace.join("\n")}"
			end
			Sfp::Undefined.new
		end

		# Execute an action
		#
		# @param action contains the action's schema.
		#
		def self.execute_action(action)
			logger = (@@config[:daemon] ? Sfp::Agent.logger : Logger.new(STDOUT))
			action_string = "#{action['name']} #{JSON.generate(action['parameters'])}"
			begin
				result = @@runtime.execute_action(action)
				logger.info "Executing #{action_string} " + (result ? "[OK]" : "[Failed]")
				return result
			rescue Exception => e
				logger.error "Executing #{action_string} [Failed] #{e}\n#{e.backtrace.join("\n")}"
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

			@@modules = []
			counter = 0
			if dir != '' and File.exist?(dir)
				Sfp::Agent.logger.info "Modules directory: #{dir}"
				Dir.entries(dir).each { |name|
					next if name == '.' or name == '..' or File.file?("#{dir}/#{name}")
					module_file = "#{dir}/#{name}/#{name}.rb"
					next if not File.exist?(module_file)
					begin
						load module_file #require module_file
						Sfp::Agent.logger.info "Loading module #{dir}/#{name} [OK]"
						counter += 1
						@@modules << name
					rescue Exception => e
						Sfp::Agent.logger.warn "Loading module #{dir}/#{name} [Failed]\n#{e}"
					end
				}
			end
			Sfp::Agent.logger.info "Successfully loading #{counter} modules."
		end

		def self.get_schemata(module_name)
			dir = @@config[:modules_dir]

			filepath = "#{dir}/#{module_name}/#{module_name}.sfp"
			sfp = parse(filepath).root
			sfp.accept(Sfp::Visitor::ParentEliminator.new)
			JSON.generate(sfp)
		end

		def self.get_module_hash(name)
			return nil if @@config[:modules_dir].to_s == ''

			module_dir = "#{@@config[:modules_dir]}/#{name}"
			if File.directory? module_dir
				if `which md5sum`.strip.length > 0
					return `find #{module_dir} -type f -exec md5sum {} + | awk '{print $1}' | sort | md5sum | awk '{print $1}'`.strip
				elsif `which md5`.strip.length > 0
					return `find #{module_dir} -type f -exec md5 {} + | awk '{print $4}' | sort | md5`.strip
				end
			end
			nil
		end

		def self.get_modules
			return [] if not (defined? @@modules and @@modules.is_a? Array)
			data = {}
			@@modules.each { |m| data[m] = get_module_hash(m) }
			data
			#(defined?(@@modules) and @@modules.is_a?(Array) ? @@modules : [])
		end

		def self.uninstall_all_modules(p={})
			return true if @@config[:modules_dir] == ''
			if system("rm -rf #{@@config[:modules_dir]}/*")
				load_modules(@@config)
				Sfp::Agent.logger.info "Deleting all modules [OK]"
				return true
			end
			Sfp::Agent.logger.info "Deleting all modules [Failed]"
			false
		end

		def self.uninstall_module(name)
			return false if @@config[:modules_dir] == ''
			
			module_dir = "#{@@config[:modules_dir]}/#{name}"
			if File.directory?(module_dir)
				result = !!system("rm -rf #{module_dir}")
			else
				result = true
			end
			load_modules(@@config)
			Sfp::Agent.logger.info "Deleting module #{name} " + (result ? "[OK]" : "[Failed]")
			result
		end

		def self.install_module(name, data)
			return false if @@config[:modules_dir].to_s == ''

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
					system("cd #{module_dir}/#{name}; mv * ..; mv .* .. 2>/dev/null; cd ..; rm -rf #{name}")
				end
				system("cd #{module_dir}; rm data.tgz")
			}
			load_modules(@@config)
			Sfp::Agent.logger.info "Installing module #{name} [OK]"

			true
		end

		def self.get_log(n=0)
			return '' if not File.exist?(LogFile)
			if n <= 0
				File.read(LogFile)
			else
				`tail -n #{n} #{LogFile}`
			end
		end

		def self.set_agents(agents)
			File.open(AgentsDataFile, 'w', 0600) do |f|
				raise Exception, "Invalid agents list." if not agents.is_a?(Hash)
				buffer = {}
				agents.each { |name,data|
					raise Exception, "Invalid agents list." if not data.is_a?(Hash) or
						not data.has_key?('sfpAddress') or data['sfpAddress'].to_s.strip == '' or
						not data.has_key?('sfpPort')
					buffer[name] = {}
					buffer[name]['sfpAddress'] = data['sfpAddress'].to_s
					buffer[name]['sfpPort'] = data['sfpPort'].to_s.strip.to_i
					buffer[name]['sfpPort'] = DefaultPort if buffer[name]['sfpPort'] == 0
				}
				f.write(JSON.generate(buffer))
				f.flush
			end
			true
		end

		@@agents_data = nil
		@@agents_data_modified_time = nil
		def self.get_agents
			return {} if not File.exist?(AgentsDataFile)
			return @@agents_data if File.mtime(AgentsDataFile) == @@agents_data_modified_time
			@@agents_data = JSON[File.read(AgentsDataFile)]
		end

		# A class that handles each request.
		#
		class Handler < WEBrick::HTTPServlet::AbstractServlet
			def initialize(server, logger)
				@logger = logger
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
					if path == '/pid' and (request.peeraddr[2] == 'localhost' or request.peeraddr[3] == '127.0.0.1')
						status, content_type, body = save_pid

					elsif path == '/state'
						status, content_type, body = get_state

					elsif path == '/sfpstate'
						status, content_type, body = get_state({:as_sfp => true})

					elsif path =~ /^\/state\/.+/
						status, content_type, body = get_state({:path => path[7, path.length-7]})

					elsif path =~ /^\/sfpstate\/.+/
						status, content_type, body = get_state({:path => path[10, path.length-10]})

					elsif path == '/model'
						status, content_type, body = get_model

					elsif path == '/bsig'
						status, content_Type, body = get_bsig

					elsif path =~ /^\/schemata\/.+/
						status, content_type, body = get_schemata({:module => path[10, path.length-10]})

					elsif path == '/modules'
						status, content_type, body = [200, 'application/json', JSON.generate(Sfp::Agent.get_modules)]

					elsif path == '/agents'
						status, content_type, body = [200, 'application/JSON', JSON.generate(Sfp::Agent.get_agents)]

					elsif path == '/log'
						status, content_type, body = [200, 'text/plain', Sfp::Agent.get_log(100)]

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
			#	/migrate => SFP object migration
			#	/duplicate => SFP object duplication
			#
			def do_POST(request, response)
				status = 400
				content_type, body = ''
				if not self.trusted(request.peeraddr[2])
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)
					if path == '/execute'
						status, content_type, body = self.execute({:query => request.query})

					elsif path =~ /\/migrate\/.+/
						status, content_type, body = self.migrate({:src => path[8, path.length-8],
						                                           :dest => request.query['destination']})

					elsif path =~ /\/duplicate\/.+/
						# TODO

					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			# uri:
			#	/model => receive a new model and save to cached file
			#	/modules => save the module if parameter "module" is provided
			#               delete the module if parameter "module" is not provided
			#	/agents => save the agents' list if parameter "agents" is provided
			#	           delete all agents if parameter "agents" is not provided
			def do_PUT(request, response)
				status = 400
				content_type, body = ''
				if not self.trusted(request.peeraddr[2])
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)

					if path == '/model'
						status, content_type, body = self.set_model({:query => request.query})

					elsif path =~ /\/modules\/.+/
						status, content_type, body = self.manage_modules({:name => path[9, path.length-9],
						                                                  :query => request.query})

					elsif path == '/modules'
						status, content_type, body = self.manage_modules({:delete => true})

					elsif path == '/agents'
						status, content_type, body = self.manage_agents({:query => request.query})

					elsif path == '/bsig'
						status, content_type, body = self.set_bsig({:query => request.query})

					elsif path == '/bsig/satisfier'
						status, content_type, body = self.satisfy_bsig_request({:query => request.query})

=begin
					elsif path == '/bsig/start'
						status, content_type, body = self.start_bsig

					elsif path == '/bsig/stop'
						status, content_type, body = self.stop_bsig
=end

					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			def migrate(p={})
				# migrate: source path, destination path
				#@logger.info "migrate #{p[:src]} => #{p[:dest]}"
				return [400, 'plain/text', 'Destination path should begin with "/"'] if p[:dest].to_s[0,1] != '/'
				begin
					# reformat the source and destination paths to SFP reference
					p[:src] = '$' + p[:src].gsub(/\//, '.')
					p[:dest] = '$' + p[:dest].gsub(/\//, '.')

					# find the target in agents' database
					agents = Sfp::Agent.get_agents
					data = agents.at?(p[:dest])
					return [404, 'plain/text', 'Unrecognized destination!'] if !data.is_a?(Hash)

					# send the sub-model to destination
					model = Sfp::Agent.get_model
					return [404, '', ''] if model.nil?
					submodel = model.at?(p[:src])

					# TODO
					# 1. send the configuration to destination

					return [200, 'plain/text', "#{p[:src]} #{p[:dest]}:#{data.inspect}"]
				rescue Exception => e
					@logger.error "Migration failed #{e}\n#{e.backtrace.join("\n")}"
				end
				return [500, 'plain/text', e.to_s]
			end

			def manage_agents(p={})
				begin
					if p[:query].has_key?('agents')
						return [200, '', ''] if Sfp::Agent.set_agents(JSON[p[:query]['agents']])
					else
						return [200, '', ''] if Sfp::Agent.set_agents({})
					end
				rescue Exception => e
					@logger.error "Saving agents list [Failed]\n#{e}\n#{e.backtrace.join("\n")}"
				end
				[500, '', '']
			end

			def manage_modules(p={})
				if p[:delete]
					return [200, '', ''] if Sfp::Agent.uninstall_all_modules
				else
					p[:name], _ = p[:name].split('/', 2)
					if p[:query].has_key?('module')
						return [200, '', ''] if Sfp::Agent.install_module(p[:name], p[:query]['module'])
					else
						return [200, '', ''] if Sfp::Agent.uninstall_module(p[:name])
					end
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
				state = Sfp::Agent.get_state(!!p[:as_sfp])

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
				if p[:query] and p[:query].has_key?('model')
					# If setting the model was success, then return '200' status.
					return [200, '', ''] if Sfp::Agent.set_model(JSON[p[:query]['model']])
				else
					# Removing the existing model by setting an empty model, if it's success then return '200' status.
					return [200, '', ''] if Sfp::Agent.set_model({})
				end

				# There is an error on setting the model!
				[500, '', '']
			end

			def get_model
				model = Sfp::Agent.get_model

				# The model is not exist.
				return [404, '', ''] if model.nil?

				# The model is exist, and then send it in JSON.
				return [200, 'application/json', JSON.generate(model)] if !!model

				# There is an error when retrieving the model!
				[500, '', '']
			end

			def execute(p={})
				return [400, '', ''] if not p[:query].has_key?('action')
				begin
					return [200, '', ''] if Sfp::Agent.execute_action(JSON[p[:query]['action']])
				rescue
				end
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

			def set_bsig(p={})
				if p[:query] and p[:query].has_key?('bsig')
					# If setting the BSig model was success, then return '200' status
					return [200, '', ''] if Sfp::Agent.set_bsig(JSON[p[:query]['bsig']])
				else
					# Deleting the existing BSig model by setting with Nil, if it's success then return '200' status.
					return [200, '', ''] if Sfp::Agent.set_bsig(nil)
				end

				# There is an error on setting/deleting the BSig model
				[500, '', '']
			end

			def get_bsig(p={})
				bsig = Sfp::Agent.get_bsig

				# The BSig model is not exist
				return [404, '', ''] if bsig.nil?

				# The BSig model is exist, and then send it in JSON
				return [200, 'application/json', JSON.generate(bsig)] if !!bsig

				[500, '', '']
			end

			def satisfy_bsig_request(p={})
				return [400, '', ''] if not p[:query]

				bsig_engine = Sfp::Agent.bsig_engine
				return [500, '', ''] if bsig_engine.nil?

				#activate_bsig(true) if bsig_engine.enabled.nil?
				req = p[:query]
				if bsig_engine.receive_goal_from_agent(req['id'].to_i, JSON[req['goal']], req['pi'].to_i)
					return [200, '', '']
				end
				[500, '', '']
			end

=begin
			def start_bsig(p={})
				bsig_engine = Sfp::Agent.bsig_engine
				return [500, '', ''] if bsig_engine.nil?

				Thread.new {
					bsig_engine.start if not bsig_engine.enabled
				}
				[200, '', '']
			end

			def stop_bsig(p={})
				bsig_engine = Sfp::Agent.bsig_engine
				return [500, '', ''] if bsig_engine.nil?

				bsig_engine.stop if bsig_engine.enabled
				[200, '', '']
			end


			def activate_bsig(enabled)
				bsig_engine = Sfp::Agent.bsig_engine
				if bsig_engine.nil?
					[500, '', '']
				else
					bsig_engine.enabled = enabled
					[200, '', '']
				end
			end
=end

			def trusted(address)
				true
			end

		end
	end
end
