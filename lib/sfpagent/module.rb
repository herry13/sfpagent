#
# predefined methods: update_state, apply, reset, resolve
#
module Sfp::Resource
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

	def apply(p={})
		true
	end

	def to_model
		@state = {}
		@model.each { |k,v| @state[k] = v }
	end

	alias_method :reset, :to_model

	def resolve(path)
		Sfp::Agent.resolve(path.simplify)
	end

	protected
	def exec_seq(*commands)
		commands = [commands.to_s] if not commands.is_a?(Array)
		commands.each { |c| raise Exception, "Cannot execute: #{c}" if !system(c) }
	end
end

module Sfp::Module
end
