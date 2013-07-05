require 'etc'
require 'fileutils'

module Sfp::Module
	class File
		include Sfp::Resource

		def update_state
			path = @model['path'].to_s
			@state['path'] = path
			@state['exists'] = ::File.exist?(path)
			@state['content'] = (@state['exists'] ? ::File.read(path) : '')

			if @state['exists']
				stat = ::File.stat(path)
				@state['user'] = Etc.getpwuid(stat.uid).name if @model['user'] != ''
				@state['group'] = Etc.getgrgid(stat.gid).name if @model['group'] != ''
			else
				@state['user'] = @state['group'] = ''
			end
		end

		def create(p={})
			begin
				::File.open(@state['path'], 'w') { |f| f.write(p['content']) }
				return true
			rescue
			end
			false
		end

		def remove(p={})
			begin
				::File.delete(@state['path'])
				return true
			rescue
			end
			false
		end

		def set_ownership(p={})
			begin
				user = (p['user'] == '' ? nil : p['user'])
				group = (p['group'] == '' ? nil : p['group'])
				::FileUtils.chown user, group, @state['path']
				return true
			rescue
			end
			false
		end
	end
end
