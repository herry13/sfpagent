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
end

module Sfp::Module
end

#		class File
#			include Resource
#
#			def update_state
#				path = @model['path'].to_s
#				@state['path'] = path
#				@state['exists'] = ::File.exist?(path)
#				@state['content'] = (@state['exists'] ? ::File.read(path) : '')
#
#				if @state['exists']
#					stat = ::File.stat(path)
#					@state['user'] = Etc.getpwuid(stat.uid).name if @model['user'] != ''
#					@state['group'] = Etc.getgrgid(stat.gid).name if @model['group'] != ''
#				else
#					@state['user'] = @state['group'] = ''
#				end
#			end
#
#			def create(p={})
#				begin
#					::File.open(@state['path'], 'w') { |f| f.write(p['content']) }
#					return true
#				rescue
#				end
#				false
#			end
#
#			def remove(p={})
#				begin
#					::File.delete(@state['path'])
#					return true
#				rescue
#				end
#				false
#			end
#
#			def set_ownership(p={})
#				begin
#					user = (p['user'] == '' ? nil : p['user'])
#					group = (p['group'] == '' ? nil : p['group'])
#					::FileUtils.chown user, group, @state['path']
#					return true
#				rescue
#				end
#				false
#			end
#		end
#	end
#
#end
