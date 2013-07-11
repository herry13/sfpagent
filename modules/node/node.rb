class Sfp::Module::Node
	include Sfp::Resource

	def update_state
		@state['sfpAddress'] = @model['sfpAddress']
		@state['sfpPort'] = @model['sfpPort']
		@state['created'] = true

		data = `dmidecode | grep -i product`.strip
		if data.length <= 0
			@state['is_virtual'] = true
		else
			_, product = data.split("\n")[0].split(":", 2)
			product = product.strip.downcase
			if product =~ /kvm/ or product =~ /virtualbox/ or product =~ /vmware/
				@state['is_virtual'] = true
			else
				@state['is_virtual'] = false
			end
		end
	end
end
