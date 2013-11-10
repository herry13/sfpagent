require 'erb'
require 'ostruct'

class Sfp::Template < OpenStruct
	# Render given template string, and then return the result
	# @template   template string to be rendered
	#
	def render(template)
		ERB.new(template).result(binding)
	end

	# Render given file, and then save the result back to the file
	# @file   target file that will be rendered
	#
	def render_file(file)
		File.open(file, File::RDWR|File::CREAT) do |f|
			f.flock(File::LOCK_EX)
			result = render(f.read)
			f.rewind
			f.write(result)
			f.flush
			f.truncate(f.pos)
		end
	end

	# Render given template string, and then return the result
	# @template   template string to be rendered
	# @map        a Hash of accessible variables in the template
	#
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

	# Render given file, and then save the result back to the file
	# @file   target file to be rendered
	# @map    a Hash of accessible variables in the template
	#
	def self.render_file(file, map)
		renderer = ::Sfp::Template.new(map)
		renderer.render_file(file)
	end
end
