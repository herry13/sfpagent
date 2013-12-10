require 'rubygems'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'thread'
require 'uri'
require 'net/http'
require 'logger'
require 'json'
require 'digest/md5'

module Sfp
	module Agent
		NetHelper = Object.new.extend(Sfp::Helper::Net)

		Home = ((Process.euid == 0 and File.directory?('/var')) ? '/var/sfpagent' : File.expand_path(Dir.home + '/.sfpagent'))
		Dir.mkdir(Home, 0700) if not File.exist?(Home)

		DefaultPort = 1314

		PIDFile = "#{Home}/sfpagent.pid"
		LogFile = "#{Home}/sfpagent.log"
		ModelFile = "#{Home}/sfpagent.model"
		AgentsDataFile = "#{Home}/sfpagent.agents"

		CacheModelFile = "#{Home}/cache.model"

		BSigFile = "#{Home}/bsig.model"
		BSigPIDFile = "#{Home}/bsig.pid"
		BSigThreadsLockFile = "#{Home}/bsig.threads.lock.#{Time.now.to_i}"

		@@logger = WEBrick::Log.new(LogFile, WEBrick::BasicLog::INFO ||
		                                     WEBrick::BasicLog::ERROR ||
		                                     WEBrick::BasicLog::FATAL ||
		                                     WEBrick::BasicLog::WARN)

		ParentEliminator = Sfp::Visitor::ParentEliminator.new

		@@current_model_hash = nil

		@@bsig = nil
		@@bsig_modified_time = nil
		@@bsig_engine = Sfp::BSig.new # create BSig engine instance

		@@runtime_lock = Mutex.new

		@@agents_database = {}
		@@agents_database_modified_time = nil

		def self.logger
			@@logger
		end

		def self.config
			@@config
		end

		def self.runtime
			@@runtime
		end

		# Start the agent.
		#
		# options:
		#	:daemon   => true if running as a daemon, false if as a console application
		#	:port     => port of web server will listen to
		#	:ssl      => set true to enable HTTPS
		#	:certfile => certificate file path for HTTPS
		#	:keyfile  => key file path for HTTPS
		#
		def self.start(opts={})
			Sfp::Agent.logger.info "Starting agent..."
			puts "Starting agent..."

			@@config = opts

			Process.daemon if opts[:daemon] and not opts[:mock]

			begin
				# check modules directory, and create it if it's not exist
				opts[:modules_dir] = File.expand_path(opts[:modules_dir].to_s.strip != '' ? opts[:modules_dir].to_s : "#{Home}/modules")
				Dir.mkdir(opts[:modules_dir], 0700) if not File.exist?(opts[:modules_dir])

				# load modules from cached directory
				load_modules(opts)

				# reload model
				update_model({:rebuild => true})

				# create web server
				server_type = WEBrick::SimpleServer
				port = (opts[:port] ? opts[:port] : DefaultPort)
				config = { :Host => '0.0.0.0',
				           :Port => port,
				           :ServerType => server_type,
				           :pid => '/tmp/webrick.pid',
				           :Logger => Sfp::Agent.logger }
				if opts[:ssl]
					config[:SSLEnable] = true
					config[:SSLVerifyClient] = OpenSSL::SSL::VERIFY_NONE
					config[:SSLCertificate] = OpenSSL::X509::Certificate.new(File.open(opts[:certfile]).read)
					config[:SSLPrivateKey] = OpenSSL::PKey::RSA.new(File.open(opts[:keyfile]).read)
					config[:SSLCertName] = [["CN", WEBrick::Utils::getservername]]
				end
				server = WEBrick::HTTPServer.new(config)
				server.mount("/", Sfp::Agent::Handler, Sfp::Agent.logger)

				# create maintenance object
				maintenance = Maintenance.new(opts)

				if not is_windows
					# trap signal
					['INT', 'KILL', 'HUP'].each do |signal|
						trap(signal) {
							maintenance.stop

							Sfp::Agent.logger.info "Shutting down web server and BSig engine..."
							bsig_engine.stop
							loop do
								break if bsig_engine.status == :stopped
								sleep 1
							end
							server.shutdown
						}
					end
				end

				File.open(PIDFile, 'w', 0644) { |f| f.write($$.to_s) }

				bsig_engine.start

				maintenance.start

				server.start if not opts[:mock]

			rescue Exception => e
				Sfp::Agent.logger.error "Starting the agent [Failed] #{e}\n#{e.backtrace.join("\n")}"

				raise e
			end
		end

		# Stop the agent's daemon.
		#
		def self.stop(opts={})
			begin
				pid = File.read(PIDFile).to_i
				puts "Stopping agent with PID #{pid}..."
				Process.kill 'HUP', pid

				if not opts[:mock]
					begin
						sleep (Sfp::BSig::SleepTime + 0.25)

						Process.kill 0, pid
						Sfp::Agent.logger.info "Agent is still running."
						puts "Agent is still running."

						Sfp::Agent.logger.info "Killing agent."
						puts "Killing agent."
						Process.kill 9, pid
					rescue
						Sfp::Agent.logger.info "Agent has stopped."
						puts "Agent has stopped."
						File.delete(PIDFile) if File.exist?(PIDFile)
					end
				end

			rescue
				puts "Agent is not running."
				File.delete(PIDFile) if File.exist?(PIDFile)
			end
		end

		def self.pid
			begin
				pid = File.read(PIDFile).to_i
				return pid if Process.kill 0, pid
			rescue
			end
			nil
		end

		# Return agent's PID if it is running, otherwise nil.
		#
		def self.status
			if pid.nil?
				puts "Agent is not running."
			else
				puts "Agent is running with PID #{pid}"
			end
		end

		def self.get_cache_model(name)
			if File.exist?(CacheModelFile)
				model = JSON[File.read(CacheModelFile)]
				return model[name] if model.has_key?(name)
			end
			nil
		end

		def self.is_windows
			(RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/)
		end
		
		def self.set_cache_model(p={})
			File.open(CacheModelFile, File::RDWR|File::CREAT, 0600) do |f|
				f.flock(File::LOCK_EX)
				json = f.read
				model = (json.length >= 2 ? JSON[json] : {})

				if p[:name]
					if p[:model]
						model[p[:name]] = p[:model]
						Sfp::Agent.logger.info "Saving cache model for #{p[:name]}..."
					else
						model.delete(p[:name]) if model.has_key?(p[:name])
						Sfp::Agent.logger.info "Deleting cache model for #{p[:name]}..."
					end
				else
					model = {}
					Sfp::Agent.logger.info "Deleting all cache model..."
				end

				f.rewind
				f.write(JSON.generate(model))
				f.flush
				f.truncate(f.pos)
			end

			true
		end

		# Save given model to cached file, and then reload the model.
		#
		def self.set_model(model)
			begin
				# generate MD5 hash for the new model
				data = JSON.generate(model)
				new_model_hash = Digest::MD5.hexdigest(data)

				# save the new model if it's not same with the existing one
				if Digest::MD5.hexdigest(data) != @@current_model_hash
					Sfp::Agent.logger.info "Setting new model [Wait]"
					File.open(ModelFile, File::RDWR|File::CREAT, 0600) { |f|
						f.flock(File::LOCK_EX)
						f.rewind
						f.write(data)
						f.flush
						f.truncate(f.pos)
					}
					update_model
					Sfp::Agent.logger.info "Setting the model [OK]"
				end
				return true
			rescue Exception => e
				Sfp::Agent.logger.error "Setting the model [Failed] #{e}\n#{e.backtrace.join("\n")}"
			end
			false
		end

		# Reload the model from cached file.
		#
		def self.update_model(p={})
			if not File.exist?(ModelFile)
				Sfp::Agent.logger.info "There is no model in cache."
			else
				begin
					@@runtime_lock.synchronize {
						data = File.read(ModelFile)
						@@current_model_hash = Digest::MD5.hexdigest(data)
						if !defined?(@@runtime) or @@runtime.nil? or p[:rebuild]
							@@runtime = Sfp::Runtime.new(JSON[data])
						else
							@@runtime.set_model(JSON[data])
						end
					}
					Sfp::Agent.logger.info "Reloading the model in cache [OK]"
				rescue Exception => e
					Sfp::Agent.logger.error "Reloading the model in cache [Failed] #{e}\n#{e.backtrace.join("\n")}"
				end
			end
		end

		# Setting a new BSig model: set @@bsig variable, and save in cached file
		#
		def self.set_bsig(bsig)
			begin
				File.open(BSigFile, File::RDWR|File::CREAT, 0600) { |f|
					f.flock(File::LOCK_EX)
					Sfp::Agent.logger.info "Setting the BSig model [Wait]"
					f.rewind
					data = ''
					if !bsig.nil?
						bsig['operators'].each_index { |i| bsig['operators'][i]['id'] = i }
						data = JSON.generate(bsig)
					end
					f.write(data)
					f.flush
					f.truncate(f.pos)
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
				data = File.read(BSigFile)
				@@bsig = (data.length > 0 ? JSON[data] : nil)
				@@bsig_modified_time = File.mtime(BSigFile)
				return @@bsig
			rescue Exception => e
				Sfp::Agent.logger.error "Get the BSig model [Failed] #{e}\n#{e.backtrace.join("\n")}"
			end
			false
		end

		def self.bsig_engine
			@@bsig_engine
		end

		def self.whoami?
			return nil if !defined?(@@runtime) or @@runtime.nil?
			@@runtime.whoami?
		end

		# Return the current state of the model.
		#
		def self.get_state(as_sfp=true)
			@@runtime_lock.synchronize {
				return nil if !defined?(@@runtime) or @@runtime.nil?
				begin
					return @@runtime.get_state(as_sfp)
				rescue Exception => e
					Sfp::Agent.logger.error "Get state [Failed] #{e}\n#{e.backtrace.join("\n")}"
				end
			}
			false
		end

		def self.resolve_model(path)
			return Sfp::Undefined.new if !defined?(@@runtime) or @@runtime.nil? or @@runtime.root.nil?
			begin
				path = path.simplify
				value = @@runtime.model.at?(path)
				if value.is_a?(Sfp::Unknown)
					_, name, rest = path.split('.', 3)
					model = get_cache_model(name)
					if !model.nil? and model.has_key?('model')
						value = (rest.to_s.length <= 0 ? model['model'] : model['model'].at?("$.#{rest}"))
						value.accept(ParentEliminator) if value.is_a?(Hash)
					end
				end
				return value
			rescue Exception => e
				Sfp::Agent.logger.error "Resolve model #{path} [Failed] #{e}\n#{e.backtrace.join("\n")}"
			end
			Sfp::Undefined.new
		end

		def self.resolve(path, as_sfp=true)
			return Sfp::Undefined.new if !defined?(@@runtime) or @@runtime.nil? or @@runtime.root.nil?
			begin
				path = path.simplify
				_, node, _ = path.split('.', 3)
				if @@runtime.root.has_key?(node)
					# local resolve
					parent, attribute = path.pop_ref
					mod = @@runtime.root.at?(parent)
					if mod.is_a?(Hash)
						mod[:_self].update_state
						state = mod[:_self].state
						return state[attribute] if state.has_key?(attribute)
					end
					return Sfp::Undefined.new
				end

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
			begin
				logger = (@@config[:daemon] ? Sfp::Agent.logger : Logger.new(STDOUT))
				action_string = "#{action['name']} #{JSON.generate(action['parameters'])}"
				logger.info "Executing #{action_string} [Wait]"
				result = @@runtime.execute_action(action)
				logger.info "Executing #{action_string} " + (result ? "[OK]" : "[Failed]")
				return result
			rescue Exception => e
				logger.error "Executing #{action_string} [Failed] #{e}\n#{e.backtrace.join("\n")}"
			end
			false
		end

		###############
		#
		# Load all modules in given agent's module directory.
		#
		# options:
		#	:dir => directory that contains all modules
		#
		###############
		def self.load_modules(p={})
			dir = p[:modules_dir]

			@@modules = {}
			counter = 0
			if dir != '' and File.directory?(dir)
				Sfp::Agent.logger.info "Modules directory: #{dir}"
				Dir.entries(dir).each do |name|
					module_dir = "#{dir}/#{name}"
					next if name == '.' or name == '..' or not File.directory?(module_dir)
					module_file = "#{module_dir}/#{name}.rb"
					if File.exist?(module_file)
						begin
							### use 'load' than 'require' to rewrite previous definitions
							load module_file
							Sfp::Agent.logger.info "Loading module #{module_dir} [OK]"
							counter += 1
							@@modules[name] = {
								:type => :ruby,
								:home => module_dir,
								:hash => get_module_hash(name)
							}
						rescue Exception => e
							Sfp::Agent.logger.warn "Loading module #{dir}/#{name} [Failed]\n#{e}"
						end
					elsif File.exist?("#{module_dir}/main")
						Sfp::Agent.logger.info "Loading module #{module_dir} [OK]"
						@@modules[name] = {
							:type => :shell,
							:home => module_dir,
							:hash => get_module_hash(name)
						}
						counter += 1
					else
						logger.warn "Module #{module_dir} is invalid."
					end
				end
			end
			Sfp::Agent.logger.info "Successfully loading #{counter} modules."
		end

		def self.get_sfp(module_name)
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
			#return [] if not (defined? @@modules and @@modules.is_a?(Hash))
			#data = {}
			#@@modules.each_key { |m| data[m] = get_module_hash(m) }
			#data
			(defined?(@@modules) ? @@modules : {})
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

		def self.install_modules(modules)
			modules.each { |name,data| return false if not install_module(name, data, false) }

			load_modules(@@config)

			true
		end

		def self.install_module(name, data, reload=true)
			return false if @@config[:modules_dir].to_s == '' or data.nil?

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

			load_modules(@@config) if reload
			
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

		def self.delete_agents
			File.open(AgentsDataFile, File::RDWR|File::CREAT, 0644) { |f|
				f.flock(File::LOCK_EX)
				f.rewind
				f.write('{}')
				f.flush
				f.truncate(f.pos)
			}
		end

		# parameter:
		#   :data => To delete an agent: { "agent_name" => nil }
		#            To add/modify an agent: { "agent_name" => { "sfpAddress" => "10.0.0.1", "sfpPort" => 1314 } }
		#
		def self.set_agents(data)
			data.each { |name,agent|
				return false if agent.is_a?(Hash) and (not agent['sfpAddress'].is_a?(String) or
				                agent['sfpAddress'].strip == '' or agent['sfpPort'].to_i <= 0)
			}

			updated = false
			agents = nil
			File.open(AgentsDataFile, File::RDWR|File::CREAT, 0644) { |f|
				f.flock(File::LOCK_EX)
				json = f.read
				agents = (json == '' ? {} : JSON[json])
				current_hash = agents.hash

				#data.each { |k,v|
				#	if !agents.has_key?(k) or v.nil? or agents[k].hash != v.hash
				#		agents[k] = v
				#	end
				#}
				agents.merge!(data)
				agents.keys.each { |k| agents.delete(k) if agents[k].nil? }

				if current_hash != agents.hash
					updated = true
					f.rewind
					f.write(JSON.generate(agents))
					f.flush
					f.truncate(f.pos)
				end
			}

			if updated
				@@agents_database = agents
				Thread.new {
					# if updated then broadcast to other agents
					http_data = {'agents' => JSON.generate(data)}
					agents.each { |name,agent|
						begin
							code, _ = NetHelper.put_data(agent['sfpAddress'], agent['sfpPort'], '/agents', http_data, 5, 20)
							raise Exception if code != '200'
						rescue #Exception => e
							#Sfp::Agent.logger.warn "Push agents list to #{agent['sfpAddress']}:#{agent['sfpPort']} [Failed]"
						end
					}
				}
			end

			true
		end

		def self.get_agents
			return {} if not File.exist?(AgentsDataFile)
			modified_time = File.mtime(AgentsDataFile)
			return @@agents_database if modified_time == @@agents_database_modified_time and
			                            (Time.new - modified_time) < 60
			@@agents_database_modified_time = File.mtime(AgentsDataFile)
			@@agents_database = JSON[File.read(AgentsDataFile)]
		end

		class Maintenance
			IntervalTime = 600 # 10 minutes

			def initialize(opts={})
				@opts = opts
			end

			def start
				return if not defined?(@@enabled) or @@enabled
				@@enabled = true
				# TODO
			end

			def stop
				@@enabled = false
			end
		end

		# A class that handles HTTP request.
		#
		class Handler < WEBrick::HTTPServlet::AbstractServlet
			def initialize(server, logger)
				@logger = logger
			end

			# Process HTTP GET request
			#
			# uri:
			#  /pid          => save daemon's PID to a file (only requested from localhost)
			#  /state        => return the current state
			#  /model        => return the current model
			#  /model/cache  => return the cached model
			#  /sfp          => return the SFP description of a module
			#  /modules      => return a list of available modules
			#  /agents       => return a list of agents database
			#  /log          => return last 100 lines of log file
			#  /bsig         => return BSig model
			#  /bsig/flaws   => return flaws of BSig model
			#
			def do_GET(request, response)
				status = 400
				content_type = body = ''
				if not trusted(request)
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

					elsif path =~ /\/model\/cache\/.+/
						status, content_type, body = self.get_cache_model({:name => path[13, path.length-13]})

					elsif path == '/bsig'
						status, content_type, body = get_bsig

					elsif path == '/bsig/flaws'
						status = 200
						content_type = 'application/json'
						body = JSON.generate(Sfp::Agent.bsig_engine.get_flaws)

					elsif path =~ /^\/sfp\/.+/
						status, content_type, body = get_sfp({:module => path[10, path.length-10]})

					elsif path == '/modules'
						mods = {}
						Sfp::Agent.get_modules.each { |name,data| mods[name] = data[:hash] }
						status, content_type, body = [200, 'application/json', JSON.generate(mods)]

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

			# Handle HTTP POST request
			#
			# uri:
			#	/execute => receive an action's schema and execute it
			#
			def do_POST(request, response)
				status = 400
				content_type, body = ''
				if not self.trusted(request)
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)
					if path == '/execute'
						status, content_type, body = self.execute({:query => request.query})
					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			# Handle HTTP PUT request
			#
			# uri:
			#  /model          => receive a new model and then save it
			#  /model/cache    => receive a "cache" model and then save it
			#  /modules        => save the module if parameter "module" is provided
			#  /agents         => save the agents' list if parameter "agents" is provided
			#  /bsig           => receive BSig model and receive it in cached directory
			#  /bsig/satisfier => receive goal request from other agents and then start
			#                     a satisfier thread in order to achieve it
			#
			def do_PUT(request, response)
				status = 400
				content_type = body = ''
				if not self.trusted(request)
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)

					if path == '/model' and request.query.has_key?('model')
						status, content_type, body = self.set_model({:model => request.query['model']})

					elsif path =~ /\/model\/cache\/.+/ and request.query.length > 0
						status, content_type, body = self.manage_cache_model({:set => true,
						                                                      :name => path[13, path.length-13],
						                                                      :model => request.query['model']})

					elsif path =~ /\/modules\/.+/ and request.query.length > 0
						status, content_type, body = self.manage_modules({:install => true,
						                                                  :name => path[9, path.length-9],
						                                                  :module => request.query['module']})

					elsif path == '/modules' and request.query.length > 0
						status, content_type, body = self.manage_modules({:install => true,
						                                                  :modules => request.query})

					elsif path == '/agents' and request.query.has_key?('agents')
						status, content_type, body = self.manage_agents({:set => true,
						                                                 :agents => request.query['agents']})

					elsif path == '/bsig' and request.query.has_key?('bsig')
						status, content_type, body = self.set_bsig({:query => request.query})

					elsif path == '/bsig/satisfier'
						status, content_type, body = self.satisfy_bsig_request({:query => request.query, :client => request.remote_ip})

					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			# Handle HTTP DELETE request
			#
			# uri:
			#  /model            => delete existing model
			#  /model/cache      => delete all cache models
			#  /model/cache/name => delete cache model of agent "name"
			#  /modules          => delete all modules from module database
			#  /modules/name     => delete module "name" from module database
			#  /agents           => delete all agents from agent database
			#  /agents/name      => delete "name" from agent database
			#  /bsig             => delete existing BSig model
			#
			def do_DELETE(request, response)
				status = 400
				content_type = body = ''
				if not self.trusted(request)
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)

					if path == '/model'
						status, content_type, body = self.set_model

					elsif path == '/model/cache'
						status, content_type, body = self.manage_cache_model({:delete => true, :name => :all})

					elsif path =~ /\/model\/cache\/.+/
						status, content_type, body = self.manage_cache_model({:delete => true, :name => path[13, path.length-13]})

					elsif path == '/modules'
						status, content_type, body = self.manage_modules({:uninstall => true, :name => :all})

					elsif path =~ /\/modules\/.+/
						status, content_type, body = self.manage_modules({:uninstall => true, :name => path[9, path.length-9]})

					elsif path == '/agents'
						status, content_type, body = self.manage_agents({:delete => true, :name => :all})

					elsif path == '/bsig'
						status, content_type, body = self.set_bsig

					end

				end
			end

			def manage_agents(p={})
				begin
					if p[:delete]
						if p[:name] == :all
							return [200, '', ''] if Sfp::Agent.delete_agents
						elsif p[:name] != ''
							return [200, '', ''] if Sfp::Agent.set_agents({p[:name] => nil})
						else
							return [400, '', '']
						end
					elsif p[:set]
						return [200, '', ''] if Sfp::Agent.set_agents(JSON[p[:agents]])
					end
				rescue Exception => e
					@logger.error "Saving agents list [Failed]\n#{e}\n#{e.backtrace.join("\n")}"
				end
				[500, '', '']
			end

			def manage_modules(p={})
				if p[:install]
					if p[:name] and p[:module]
						return [200, '', ''] if Sfp::Agent.install_module(p[:name], p[:module])
					elsif p[:modules]
						return [200, '', ''] if Sfp::Agent.install_modules(p[:modules])
					else
						return [400, '', '']
					end
				elsif p[:uninstall]
					if p[:name] == :all
						return [200, '', ''] if Sfp::Agent.uninstall_all_modules
					elsif p[:name] != ''
						return [200, '', ''] if Sfp::Agent.uninstall_module(p[:name])
					else
						return [400, '', '']
					end
				end
				[500, '', '']
			end

			def get_cache_model(p={})
				model = Sfp::Agent.get_cache_model(p[:name])
				if model
					[200, 'application/json', JSON.generate(model)]
				else
					[404, '', '']
				end
			end

			def manage_cache_model(p={})
				if p[:set] and p[:name] and p[:model]
					p[:model] = JSON[p[:model]]
					return [200, '', ''] if Sfp::Agent.set_cache_model(p)
				elsif p[:delete] and p[:name]
					if p[:name] == :all
						return [200, '', ''] if Sfp::Agent.set_cache_model
					else
						return [200, '', ''] if Sfp::Agent.set_cache_model({:name => p[:name]})
					end
				else
					return [400, '', '']
				end
				[500, '', '']
			end

			def get_sfp(p={})
				begin
					module_name, _ = p[:module].split('/', 2)
					return [200, 'application/json', Sfp::Agent.get_sfp(module_name)]
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
				if p[:model]
					# If setting the model was success, then return '200' status.
					return [200, '', ''] if Sfp::Agent.set_model(JSON[p[:model]])
				else
					# Removing the existing model by setting an empty model, if it's success then return '200' status.
					return [200, '', ''] if Sfp::Agent.set_model({})
				end

				# There is an error on setting the model!
				[500, '', '']
			end

			def get_model
				# The model is not exist.
				return [404, '', ''] if not File.exist?(Sfp::Agent::ModelFile)

				begin
					# The model is exist, and then send it in JSON.
					return [200, 'application/json', File.read(Sfp::Agent::ModelFile)]
				rescue
				end

				# There is an error when retrieving the model!
				[500, '', '']
			end

			def execute(p={})
				return [400, '', ''] if not (p[:query] and p[:query].has_key?('action'))
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

				return [500, '', ''] if Sfp::Agent.bsig_engine.nil?

				req = p[:query]
				return [200, '', ''] if Sfp::Agent.bsig_engine.receive_goal_from_agent(req['id'].to_i, JSON[req['goal']], req['pi'].to_i, p[:client])

				[500, '', '']
			end

			def trusted(request)
				true
			end

		end
	end
end
