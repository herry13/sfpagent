require 'erb'
require 'ostruct'

class Sfp::TemplateEngine < OpenStruct
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

	def self.render(map, template)
		renderer = TemplateEngine.new(map)
		renderer.render(template)
	end

	def self.render_to_file(map, template, file)
		renderer = TemplateEngine.new(map)
		renderer.render_to_file(template, file)
	end

	def self.render_file(map, file)
		renderer = TemplateEngine.new(map)
		renderer.render_file(file)
	end
end
