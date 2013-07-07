require 'etc'
require 'fileutils'

module Sfp::Resource
	attr_reader :state, :model

	def init(model, default)
		@model = {}
		model.each { |k,v| @model[k] = v }
		@state = {}
		default.each { |k,v| @state[k] = v }
	end

	def update_state
		@state = {}
	end

	def reset
		@state = {}
		@model.each { |k,v| @state[k] = v }
	end
end

module Sfp::Module
end
