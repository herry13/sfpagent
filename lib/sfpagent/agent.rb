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
		NetHelper = Object.new.extend(Sfp::Net::Helper)

		CacheDir = (Process.euid == 0 ? '/var/sfpagent' : File.expand_path('~/.sfpagent'))
		Dir.mkdir(CacheDir, 0700) if not File.exist?(CacheDir)

		DefaultPort = 1314

		PIDFile = "#{CacheDir}/sfpagent.pid"
		LogFile = "#{CacheDir}/sfpagent.log"
		ModelFile = "#{CacheDir}/sfpagent.model"
		AgentsDataFile = "#{CacheDir}/sfpagent.agents"

		CacheModelFile = "#{CacheDir}/cache.model"

		BSigFile = "#{CacheDir}/bsig.model"
		BSigPIDFile = "#{CacheDir}/bsig.pid"
		BSigThreadsLockFile = "#{CacheDir}/bsig.threads.lock.#{Time.now.nsec}"

		@@logger = WEBrick::Log.new(LogFile, WEBrick::BasicLog::INFO ||
		                                     WEBrick::BasicLog::ERROR ||
		                                     WEBrick::BasicLog::FATAL ||
		                                     WEBrick::BasicLog::WARN)

		@@current_model_hash = nil

		@@bsig = nil
		@@bsig_modified_time = nil
		@@bsig_engine = Sfp::BSig.new # create BSig engine instance

		@@runtime_lock = Mutex.new

		@@agents_database = nil
		@@agents_database_modified_time = nil

		def self.logger
			@@logger
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
		def self.start(p={})
			Sfp::Agent.logger.info "Starting SFP Agent daemons..."
			puts "Starting SFP Agent daemons..."

			Process.daemon

			begin
				# check modules directory, and create it if it's not exist
				p[:modules_dir] = File.expand_path(p[:modules_dir].to_s.strip != '' ? p[:modules_dir].to_s : "#{CacheDir}/modules")
				Dir.mkdir(p[:modules_dir], 0700) if not File.exist?(p[:modules_dir])
				@@config = p

				# load modules from cached directory
				load_modules(p)

				# reload model
				update_model({:rebuild => true})

				# create web server
				server_type = WEBrick::SimpleServer
				port = (p[:port] ? p[:port] : DefaultPort)
				config = { :Host => '0.0.0.0',
				           :Port => port,
				           :ServerType => server_type,
				           :pid => '/tmp/webrick.pid',
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

				# trap signal
				['INT', 'KILL', 'HUP'].each { |signal|
					trap(signal) {
						Sfp::Agent.logger.info "Shutting down web server and BSig engine..."
						bsig_engine.stop
						loop do
							break if bsig_engine.status == :stopped
							sleep 1
						end
						server.shutdown
					}
				}

				File.open(PIDFile, 'w', 0644) { |f| f.write($$.to_s) }

				bsig_engine.start

				server.start

			rescue Exception => e
				Sfp::Agent.logger.error "Starting the agent [Failed] #{e}\n#{e.backtrace.join("\n")}"
				raise e
			end
		end

		# Stop the agent's daemon.
		#
		def self.stop
			begin
				pid = File.read(PIDFile).to_i
				puts "Stopping SFP Agent with PID #{pid}..."
				Process.kill 'HUP', pid

				begin
					sleep (Sfp::BSig::SleepTime + 0.25)
					Process.kill 0, pid
					Sfp::Agent.logger.info "SFP Agent daemon is still running."
					puts "SFP Agent daemon is still running."
				rescue
					Sfp::Agent.logger.info "SFP Agent daemon has stopped."
					puts "SFP Agent daemon has stopped."
				end
			rescue
				puts "SFP Agent is not running."
			end

		ensure
			File.delete(PIDFile) if File.exist?(PIDFile)
		end

		# Print the status of the agent.
		#
		def self.status
			begin
				pid = File.read(PIDFile).to_i
				Process.kill 0, pid
				puts "SFP Agent is running with PID #{pid}"
			rescue
				puts "SFP Agent is not running."
				File.delete(PIDFile) if File.exist?(PIDFile)
			end
		end

		def self.get_cache_model(p={})
			model = JSON[File.read(CacheModelFile)]
			(model.has_key?(p[:name]) ? model[p[:name]] : nil)
		end

		def self.set_cache_model(p={})
			File.open(CacheModelFile, File::RDWR|File::CREAT, 0600) do |f|
				f.flock(File::LOCK_EX)
				json = f.read
				model = (json.length >= 2 ? JSON[json] : {})

				if p[:name]
					if p[:model]
						model[p[:name]] = p[:model]
						Sfp::Agent.logger.info "Setting cache model for #{p[:name]}..."
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
					data = (bsig.nil? ? '' : JSON.generate(bsig))
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
						load module_file # use 'load' than 'require'
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
			return [] if not (defined? @@modules and @@modules.is_a? Array)
			data = {}
			@@modules.each { |m| data[m] = get_module_hash(m) }
			data
		end

		# Push a list of modules to an agent using a script in $SFPAGENT_HOME/bin/install_module.
		#
		# parameters:
		#   :address => address of target agent
		#   :port    => port of target agent
		#   :modules => an array of modules' name that will be pushed
		#
		def self.push_modules(p={})
			fail "Incomplete parameters." if !p[:modules] or !p[:address] or !p[:port]

			install_module = File.expand_path('../../../bin/install_module', __FILE__)
			modules = p[:modules].join(' ')
			cmd = "cd #{@@config[:modules_dir]}; #{install_module} #{p[:address]} #{p[:port]} #{modules}"
			result = `#{cmd}`
			(result =~ /status: ok/)
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

		def self.set_agents(new_data)
			new_data.each { |name,agent|
				return false if not agent['sfpAddress'].is_a?(String) or agent['sfpAddress'].strip == '' or
					agent['sfpPort'].to_i <= 0
			}

			updated = false
			File.open(AgentsDataFile, File::RDWR|File::CREAT, 0644) { |f|
				f.flock(File::LOCK_EX)
				old_data = f.read
				old_data = (old_data == '' ? {} : JSON[old_data])
				
				if new_data.hash != old_data.hash
					f.rewind
					f.write(JSON.generate(new_data))
					f.flush
					f.truncate(f.pos)
					updated = true
				end
			}

			if updated # broadcast to other agents
				http_data = {'agents' => JSON.generate(new_data)}

				new_data.each { |name,agent|
					begin
						code, _ = NetHelper.put_data(agent['sfpAddress'], agent['sfpPort'], '/agents', http_data, 5, 20)
						raise Exception if code != '200'
					rescue Exception => e
						Sfp::Agent.logger.warn "Push agents list to #{agent['sfpAddress']}:#{agent['sfpPort']} [Failed]"
					end
				}
			end

			true
		end

		def self.get_agents
			return {} if not File.exist?(AgentsDataFile)
			return @@agents_database if File.mtime(AgentsDataFile) == @@agents_database_modified_time
			@@agents_database = JSON[File.read(AgentsDataFile)]
		end

		# A class that handles HTTP request.
		#
		class Handler < WEBrick::HTTPServlet::AbstractServlet
			def initialize(server, logger)
				@logger = logger
			end

			# Process HTTP Get request
			#
			# uri:
			#	/pid      => save daemon's PID to a file (only requested from localhost)
			#	/state    => return the current state
			#	/model    => return the current model
			#	/sfp      => return the SFP description of a module
			#	/modules  => return a list of available modules
			#  /agents   => return a list of agents database
			#  /log      => return last 100 lines of log file
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
						status, content_Type, body = get_bsig

					elsif path =~ /^\/sfp\/.+/
						status, content_type, body = get_sfp({:module => path[10, path.length-10]})

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

			# Handle HTTP Put request
			#
			# uri:
			#	/model          => receive a new model and save to cached file
			#	/modules        => save the module if parameter "module" is provided
			#                     delete the module if parameter "module" is not provided
			#	/agents         => save the agents' list if parameter "agents" is provided
			#	                   delete all agents if parameter "agents" is not provided
			#  /bsig           => receive BSig model and receive it in cached directory
			#  /bsig/satisfier => receive goal request from other agents and then start
			#                     a satisfier thread to try to achieve it
			def do_PUT(request, response)
				status = 400
				content_type = body = ''
				if not self.trusted(request)
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)

					if path == '/model' and request.query.has_key?('model')
						status, content_type, body = self.set_model({:query => request.query})

					elsif path =~ /\/model\/cache\/.+/ and request.query.length > 0
						status, content_type, body = self.set_cache_model({:name => path[13, path.length-13],
						                                                   :query => request.query})

					elsif path =~ /\/modules\/.+/ and request.query.length > 0
						status, content_type, body = self.manage_modules({:name => path[9, path.length-9],
						                                                  :query => request.query})

					elsif path == '/modules' and request.query.length > 0
						status, content_type, body = self.manage_modules({:query => request.query})

					elsif path == '/agents' and request.query.has_key?('agents')
						status, content_type, body = self.set_agents({:query => request.query})

					elsif path == '/bsig' and request.query.has_key?('bsig')
						status, content_type, body = self.set_bsig({:query => request.query})

					elsif path == '/bsig/satisfier'
						status, content_type, body = self.satisfy_bsig_request({:query => request.query})

					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			# Handle HTTP Put request
			#
			# uri:
			#	/model          => delete existing model
			#	/modules        => delete a module with name specified in parameter "module", or
			#	                   delete all modules if parameter "module" is not provided
			#	/agents         => delete agents database
			#  /bsig           => delete existing BSig model
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
						status, content_type, body = self.set_cache_model

					elsif path =~ /\/model\/cache\/.+/
						status, content_type, body = self.set_cache_model({:name => path[13, path.length-13]})

					elsif path == '/modules'
						status, content_type, body = self.manage_modules({:deleteall => true})

					elsif path =~ /\/modules\/.+/
						status, content_type, body = self.manage_modules({:name => path[9, path.length-9]})

					elsif path == '/agents'
						status, content_type, body = self.set_agents

					elsif path == '/bsig'
						status, content_type, body = self.set_bsig

					end

				end
			end

			def set_agents(p={})
				begin
					if p[:query] and p[:query].has_key?('agents')
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
				if p[:name]
					if p[:query]
						return [200, '', ''] if Sfp::Agent.install_module(p[:name], p[:query]['module'])
					else
						return [200, '', ''] if Sfp::Agent.uninstall_module(p[:name])
					end
				elsif p[:query].length > 0
					return [200, '', ''] if Sfp::Agent.install_modules(p[:query])
				else
					return [200, '', ''] if Sfp::Agent.uninstall_all_modules
				end

				[500, '', '']
			end

			def get_cache_model(p={})
				model = Sfp::Agent.get_cache_model({:name => p[:name]})
				if model
					[200, 'application/json', JSON.generate(model)]
				else
					[404, '', '']
				end
			end

			def set_cache_model(p={})
				p[:model] = JSON[p[:query]['model']] if p[:query].is_a?(Hash) and p[:query]['model']

				if p[:name]
					return [200, '', ''] if Sfp::Agent.set_cache_model(p)
				else
					return [200, '', ''] if Sfp::Agent.set_cache_model
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
				return [200, '', ''] if Sfp::Agent.bsig_engine.receive_goal_from_agent(req['id'].to_i, JSON[req['goal']], req['pi'].to_i)

				[500, '', '']
			end

			def trusted(request)
				true
			end

		end
	end
end
