require 'rubygems'
require 'webrick'
require 'thread'
require 'uri'
require 'net/http'

module Sfp
	module Agent
		PIDFile = '/tmp/sfpagent.pid'
		LogFile = '/tmp/sfpagent.log'

		def self.start
			server_type = WEBrick::Daemon
			logfile = LogFile
			logger = WEBrick::Log.new(logfile, WEBrick::BasicLog::INFO ||
			                                   WEBrick::BasicLog::ERROR ||
			                                   WEBrick::BasicLog::FATAL ||
			                                   WEBrick::BasicLog::WARN)
			config = {:Host => '0.0.0.0', :Port => '1314', :ServerType => server_type,
			          :Logger => logger}
			server = WEBrick::HTTPServer.new(config)
			server.mount("/", Sfp::Agent::Handler)

			fork {
				# send request to save PID
				sleep 2
				url = URI.parse("http://localhost:#{config[:Port]}/pid")
				req = Net::HTTP::Get.new(url.path)
				Net::HTTP.start(url.host, url.port) { |http| http.request(req) }
				puts "Agent running with PID #{File.read(PIDFile)}"
			}

			server.start
		end

		def self.stop
			pid = (File.exist?(PIDFile) ? File.read(PIDFile).to_i : nil)
			if not pid.nil? and `ps hf #{pid}`.strip =~ /.*sfpagent.*/
				print "Stopping SFP Agent with PID #{pid} "
				Process.kill('KILL', pid)
				puts "[OK]"
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

		class Handler < WEBrick::HTTPServlet::AbstractServlet
			def initialize(server)
			end

			def do_GET(request, response)
				content_type, body = ''
				if not trusted(request.peeraddr[2])
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)
					if path == '/pid' and request.peeraddr[2] == 'localhost'
						save_pid
					else
						status = 404
					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			def do_POST(request, response)
				status = 404
				content_type, body = ''
				if not trusted(request.peeraddr[2])
					status = 403
				else
					path = (request.path[-1,1] == '/' ? ryyequest.path.chop : request.path)
					if path == '/state'
						status, content_type, body = get_state(request.query)
					end
				end

				response.status = status
				response['Content-Type'] = content_type
				response.body = body
			end

			def get_state(query)
				# TODO
				[404, '', '']
			end

			def save_pid
				begin
					File.open(PIDFile, 'w') { |f| f.write($$.to_s) }
				rescue Exception
				end
				[200, '', '']
			end

			def trusted(address)
				true
			end
		end
	end
end
