#
# predefined methods: update_state, apply, reset, resolve, resolve_model, resolve_state
#
module Sfp::Resource
	@@resource = Object.new.extend(Sfp::Resource)

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

	##############################
	#
	# Helper methods for resource module
	#
	##############################

	def self.resolve(path)
		@@resource.resolve(path)
	end

	protected
	def update_model(model)
		@model = Sfp.to_ruby(model)
	end

	def reset
		@state = {}
		@model.each { |k,v| @state[k] = v }
	end

	def resolve(path)
		Sfp::Agent.resolve(path)
	end

	alias_method :resolve_state, :resolve

	def resolve_model(path)
		Sfp::Agent.resolve_model(path)
	end

	def exec_seq(*commands)
		commands = [commands.to_s] if not commands.is_a?(Array)
		commands.each { |c| raise Exception, "Error on executing '#{c}'" if !shell(c) }
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

	def render(file, map)
		::Sfp::Template.render_file(map, file)
	end
end

module Sfp::Module
end
