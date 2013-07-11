require 'etc'
require 'fileutils'

module Sfp::Resource
	attr_reader :state, :model

	def init(model, default)
		@model = {}
		model.each { |k,v| @model[k] = v }
		@state = {}
		@default = {}
		#default.each { |k,v| @state[k] = @default[k] = v }
	end

	def update_state
		@state = {}
	end

	def to_model
		@state = {}
		@model.each { |k,v| @state[k] = v }
	end

	alias_method :reset, :to_model

	protected
	def exec_seq(*commands)
		commands = [commands.to_s] if not commands.is_a?(Array)
		commands.each { |c| raise Exception, "Cannot execute: #{c}" if !system(c) }
	end
end

module Sfp::Module
end
