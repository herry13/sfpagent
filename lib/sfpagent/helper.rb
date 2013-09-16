module Sfp::Helper
end

class Sfp::Helper::SchemaCollector
	attr_reader :schemata
	def initialize
		@schemata = []
	end
		
	def visit(name, value, parent)
		if value.is_a?(Hash) and value.has_key?('_classes')
			value['_classes'].each { |s| @schemata << s }
		end
		true
	end
end

class Sfp::Helper::CloudFinder
	CloudSchema = '$.Cloud'
	attr_accessor :clouds

	def reset
		@clouds = []
		self
	end

	def visit(name, value, parent)
		if value.is_a?(Hash)
			if value['_context'] == 'object'
				@clouds << parent.ref.push(name) if value.has_key?('_classes') and value['_classes'].index(CloudSchema)
				return true
			end
		end
		false
	end
end
