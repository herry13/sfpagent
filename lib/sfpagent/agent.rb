require 'rubygems'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'thread'
require 'uri'
require 'net/http'

module Sfp
	module Agent
		DefaultPort = 1314
		PIDFile = '/tmp/sfpagent.pid'
		LogFile = '/tmp/sfpagent.log'
		ModelFile = '/tmp/sfpagent.model'

		@@logger = WEBrick::Log.new(LogFile, WEBrick::BasicLog::INFO ||
		                                     WEBrick::BasicLog::ERROR ||
		                                     WEBrick::BasicLog::FATAL ||
		                                     WEBrick::BasicLog::WARN)

		def self.start(p={})
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
	
				reload_model
				server.start
			rescue Exception => e
				@@logger.error "Starting the agent [Failed] #{e}"
				raise e
			end
		end

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

		def self.set_model(model)
			begin
				@@logger.info "Setting the model [Wait]"
				File.open(ModelFile, 'w') { |f|
					f.flock(File::LOCK_EX)
					f.write(JSON.generate(model))
					f.flush
					reload_model
				}
				@@logger.info "Setting the model [OK]"
				return true
			rescue Exception => e
				@@logger.error "Setting the model [Failed] #{e}"
			end
			false
		end

		def self.get_model
			return nil if not File.exist?(ModelFile)
			begin
				File.open(ModelFile, 'r') { |f|
					f.flock(File::LOCK_SH)
					return JSON[f.read]
				}
			rescue Exception => e
				@@logger.error "Get the model [Failed] #{e}"
			end
			false
		end

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

		def self.get_state
			return nil if !defined? @@runtime or @@runtime.nil?
			begin
				return @@runtime.get_state
			rescue Exception => e
				@@logger.error "Get state [Failed] #{e}"
			end
			false
		end

		def self.execute_action(action)
			begin
				@@runtime.execute_action(action)
				@@logger.info "Executing #{action['name']} [OK]"
				return true
			rescue Exception => e
				@@logger.info "Executing #{action['name']} [Failed] #{e}"
			end
			false
		end

		class Handler < WEBrick::HTTPServlet::AbstractServlet
			def initialize(server, logger)
				@logger = logger
			end

			def query_to_json(query, json=false)
				return query['json'] if json
				JSON[query['json']]
			end

			def do_GET(request, response)
				status = 404
				content_type, body = ''
				if not trusted(request.peeraddr[2])
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)
					if path == '/pid' and request.peeraddr[2] == 'localhost'
						status, content_type, body = save_pid

					elsif path == '/state'
						status, content_type, body = get_state

					elsif path[0,7] == '/state/'
						status, content_type, body = get_state({:path => path[7, path.length-7]})

					elsif path == '/model'
						status, content_type, body = get_model

					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			def do_POST(request, response)
				status = 404
				content_type, body = ''
				if not self.trusted(request.peeraddr[2])
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)
					if path == '/model'
						status, content_type, body = self.set_model({:model => query_to_json(request.query)})

					elsif path == '/execute'
						status, content_type, body = self.execute({:action => query_to_json(request.query)})

					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			def get_state(p={})
				state = Sfp::Agent.get_state

				# The model is not exist.
				return [404, 'text/plain', 'There is no model!'] if state.nil?

				return [200, 'application/json', JSON.generate(state)] if !!state

				# There is an error when retrieving the state of the model!
				[500, '', '']
			end

			def set_model(p={})
				# Setting the model was success, and then return '200' status.
				return [200, '', ''] if Sfp::Agent.set_model(p[:model])

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
					File.open(PIDFile, 'w') { |f| f.write($$.to_s) }
					return [200, '', '']
				rescue Exception
				end
				[500, '', '']
			end

			def trusted(address)
				true
			end
		end
	end
end
