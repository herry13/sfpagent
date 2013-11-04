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
end

module Sfp::Module
end
