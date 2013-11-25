require 'yaml'
require 'shellwords'

module Sfp::Module
end

###############
#
# Module Sfp::Resource must be included by every module. It provides
# standard methods which are used by Runtime engine in mapping between
# SFP object and schema implementation.
#
# accessible attributes
# - parent        : holds instance of parent's object
#
# - synchronized  : an list of SFP procedures that must be executed in
#                   serial
#
# - path          : an absolute path of this instance
#
# read-only attributes
# - state         : holds the current state of this module instance
#
# - model         : holds the model of desired state of this module
#                   instance
#
# methods:
# - init          : invoked by Runtime engine after instantiating this
#                   module instance for initialization
#
# - update_state  : invoked by Runtime engine to request this module
#                   instance to update the current state which should
#                   be kept in attribute @state
#
# - to_model      : can be invoked by this module instance to set the
#                   current state equals the desired state (model), or
#                   in short: @state == @model
#
# - resolve_state : can be invoked by this module to resolve given
#                   reference of current state either local or other
#                   module instances
#
# - resolve       : an alias to method resolve_state
#
# - resolve_model : can be invoked by this module to resolve given
#                   reference of desired state (model) either local or
#                   other module instances
#
# - log           : return logger object
#
# - copy          : copy a file, whose path is the first parameter, to
#                   a destination path given in the second parameter
#
# - render        : render given template file, whose path is the first
#                   parameter, and the template's variable is a merged
#                   between a Hash in the second parameter with model;
#                   the result is returned as a string
#
# - render_file   : render given template file, whose path is the first
#                   parameter, and the template's variable is a merged
#                   between a Hash on the second parameter with model;
#                   the result is written back to the file
#
###############
module Sfp::Resource
	@@resource = Object.new.extend(Sfp::Resource)

	attr_accessor :parent, :synchronized, :path
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
				return false if uri.host[0, pattern.length] == pattern
			}
			true
		end

		file = nil
		begin
			uri = URI.parse(source)
			http = nil
			if use_http_proxy?(uri)
				begin
					proxy = URI.parse(ENV['http_proxy'])
					http = Net::HTTP::Proxy(proxy.host, proxy.port).new(uri.host, uri.port)
				rescue Exception => e
					log.info "Invalid http_proxy=#{ENV['http_proxy']}"
					http = Net::HTTP.new(uri.host, uri.port)
				end
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

class Sfp::Module::Shell
	include Sfp::Resource

	attr_reader :home, :main

	def initialize(metadata)
		### set module's home directory
		@home = metadata[:home]

		### set main shell command
		@main = @home + '/main'
	end

	def update_state
		@state = invoke({
			:command => :state,
			:model => @model,
			:path => @path
		})
	end

	def execute(name, parameters={})
		result = invoke({
			:command => :execute,
			:procedure => name.split('.').last,
			:parameters => parameters,
			:model => @model,
			:path => @path
		})
		if result['status'] != 'ok'
			log.error "Error in executing #{name} - description: #{result['description']}"
			false
		else
			true
		end
	end

	private

	def invoke(parameters)
		log.info Shellwords.shellescape(JSON.generate(parameters))
		begin
			output = `#{@main} #{Shellwords.shellescape(JSON.generate(parameters))}`
			log.info output
			JSON.parse(output)
		rescue Exception => exp
			log.info "Invalid module output: #{output}"
			raise exp
		end
	end
end
