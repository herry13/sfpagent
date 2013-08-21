module Sfp::BSig
end

module Sfp::BSig::Main
	def execute_model
		# TODO -- implement
		Sfp::Agent.logger.info "Execute BSig model"
		@enabled = true
		while @enabled
			sleep 1
		Sfp::Agent.logger.info "Execute BSig model"
		end
	end

	def achieve_local_goals(version, goals, operators, pi)
		# TODO -- implement
	end

	def achieve_remote_goals(version, goals, pi)
		# TODO -- implement
	end

	def shutdown
		@enabled = false
	end
end

module Sfp::BSig::Satisfier
	def receive_goals(agent, version, goals, pi)
		# TODO -- implement
	end
end
