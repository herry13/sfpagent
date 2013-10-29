require 'erb'
require 'ostruct'

class Sfp::Template < OpenStruct
	def render(template)
		ERB.new(template).result(binding)
	end

	def render_to_file(template, file)
		result = render(template)
		File.open(file, 'w+') { |f| f.write(result) }
	end

	def render_file(file)
		render_to_file(File.read(file), file)
	end

	def self.render(template, map)
		if map.is_a?(Hash)
			renderer = ::Sfp::Template.new(map)
			renderer.render(template)
		elsif map.is_a?(OpenStruct)
			ERB.new(template).result(map.instance_eval { binding })
		else
			raise Exception, 'A Hash or OpenStruct is required!'
		end
	end

	def self.render_to_file(template, file, map)
		renderer = ::Sfp::Template.new(map)
		renderer.render_to_file(template, file)
	end

	def self.render_file(file, map)
		renderer = ::Sfp::Template.new(map)
		renderer.render_file(file)
	end
end
