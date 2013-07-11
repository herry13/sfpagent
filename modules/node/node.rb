class Sfp::Module::Node
	include Sfp::Resource

	def update_state
		@state['sfpAddress'] = @model['sfpAddress']
		@state['sfpPort'] = @model['sfpPort']
		@state['is_virtual'] = case ::File.exist?('/proc/scsi/scsi')
			when true
				(`cat /proc/scsi/scsi`.sub(/Attached devices:/, '').strip.length <= 0)
			else
				false
			end
	end
end
