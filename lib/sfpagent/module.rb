#
# predefined methods: update_state, apply, reset, resolve, resolve_model, resolve_state
#
module Sfp::Resource
	@@resource = Object.new.extend(Sfp::Resource)

	attr_accessor :parent, :synchronized
	attr_reader :state, :model

	def init(model={})
		@state = {}
		@model = (model.length <= 0 ? {} : Sfp.to_ruby(model))
		@synchronized = []
	end

	def update_state
		@state = {}
	end

	##############################
	#
	# Helper methods for resource module
	#
	##############################

	def self.resolve(path)
		@@resource.resolve(path)
	end

	protected
	def to_model
		@state = {}
		@model.each { |k,v| @state[k] = v }
	end

	def resolve_state(path)
		Sfp::Agent.resolve(path)
	end

	alias_method :resolve, :resolve_state

	def resolve_model(path)
		Sfp::Agent.resolve_model(path)
	end

	def log
		Sfp::Agent.logger
	end

	def shell(cmd)
		!!system(cmd)
	end

	def copy(source, destination)
		shell "cp -rf #{source} #{destination}"
	end

	def render(string, map={})
		model = @model.clone
		map.each { |k,v| model[k] = v }
		::Sfp::Template.render(string, model)
	end

	def render_file(file, map={})
		model = @model.clone
		map.each { |k,v| model[k] = v }
		::Sfp::Template.render_file(file, model)
	end

	def download(source, destination)
		def use_http_proxy?(uri)
			ENV['no_proxy'].to_s.split(',').each { |pattern|
				pattern.chop! if pattern[-1] == '*'
				return false if uri.hist[0, pattern.length] == pattern
			}
			true
		end

		file = nil
		begin
			uri = URI.parse(source)
			http = nil
			if use_http_proxy?(uri)
				proxy = URI.parse(ENV['http_proxy'])
				http = Net::HTTP::Proxy(proxy.host, proxy.port).new(uri.host, uri.port)
			else
				http = Net::HTTP.new(uri.host, uri.port)
			end
			http.request_get(uri.path) do |response|
				file = ::File.open(destination, 'wb')
				response.read_body do |segment|
					file.write segment
				end
				file.flush
			end
		ensure
			file.close if not file.nil?
		end
	end
end

module Sfp::Module
end
