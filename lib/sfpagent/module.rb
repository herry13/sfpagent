#
# predefined methods: update_state, apply, reset, resolve, resolve_model, resolve_state
#
module Sfp::Resource
	@@resource = Object.new.extend(Sfp::Resource)

	def self.resolve(path)
		@@resource.resolve(path)
	end

	attr_accessor :parent, :synchronized
	attr_reader :state, :model

	def init(model={})
		@model = {}
		@state = {}
		@synchronized = []

		update_model(model)
	end

	def update_state
		@state = {}
	end

	def update_model(model)
		model.each { |k,v| @model[k] = v }
	end

	def to_model
		@state = {}
		@model.each { |k,v| @state[k] = v }
	end

	alias_method :reset, :to_model

	def resolve(path)
		Sfp::Agent.resolve(path)
	end

	alias_method :resolve_state, :resolve

	def resolve_model(path)
		Sfp::Agent.resolve_model(path)
	end

	protected
	def exec_seq(*commands)
		commands = [commands.to_s] if not commands.is_a?(Array)
		commands.each { |c| raise Exception, "Cannot execute: #{c}" if !system(c) }
	end

	def log
		Sfp::Agent.logger
	end

	# copy source file to destination
	# if source is an HTTP/HTTPS/FTP url, then use 'wget' to download the file
	#
	def copy(source, destination)
		if source =~ /^(http|https|ftp):\/\/.+/
			system "wget -O #{destination} #{source}"
		else
			system "cp #{source} #{destination}"
		end
	end
end

module Sfp::Module
end
