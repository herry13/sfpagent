require 'thread'

module Sfp::BSig
end

module Sfp::BSig::Main
	BSigSleepTime = 5
	SatisfierPath = '/bsig/satisfier'

	def execute_model
		Sfp::Agent.logger.info "Execute BSig model"
		@enabled = true

		while @enabled
			wait_for_satisfier?

			bsig = Sfp::Agent.get_bsig
			case achieve_local_goal(bsig['version'], bsig['goal'], bsig['operators'], 1)
			when :failure
				@enabled = false
				fail "Executing BSig model [Failed]"
			when :no_flaw
				sleep BSigSleepTime
			end
		end
	end

	# returns
	# :no_flaw   : there is no goal-flaw
	# :failure   : there is a failure on achieving the goal
	# :ongoing   : the selected operator is being executed
	# :repaired  : some goal-flaws have been repaired, but the goal may have other flaws
	def achieve_local_goal(version, goal, operators, pi)
		flaws = compute_flaws(goal, get_current_state)
		return :no_flaw if flaws.length <= 0

		operator = select_operator(flaws, operators, pi)
		return :failure if operator.nil?

		return :ongoing if operator['selected']

		operator['selected'] = true
		next_pi = pi + 1
		pre_local, pre_remote = split_preconditions(operator)

		status = nil
		begin
			status = achieve_local_goal(version, pre_local, operators, next_pi)
		end until status == :no_flaw or status == :failure

		if status == :failure or
		   achieve_remote_goal(version, pre_remote, next_pi) == :failure or
		   invoke(operator) == :failure
			operator['selected'] = false
			return :failure
		end

		operator['selected'] = false
		return :repaired
	end

	def achieve_remote_goal(version, goal, pi)
		agents = Sfp::Agent.get_agents
		split_goal_by_agent(goal).each do |agent,g|
			return false if not agents.has_key?(agent) or agents[agent]['sfpAddress'].to_s == ''
			return false if not send_goal_to_agent(agents[agent], version, g, pi)
		end
		true
	end

	def receive_goal_from_agent(agent, version, goal, pi)
		return false if not @enabled

		bsig = Sfp::Agent.get_bsig
		return false if version < bsig['version']

		loop do
			case achieve_local_goal(bsig['version'], goal, bsig['operators'], pi)
			when :failure
				return false
			when :no_flaw
				return true
			end
		end
	end

	def shutdown
		@enabled = false
	end

	protected
	def send_goal_to_agent(agent, version, g, pi)
		data = {'version' => version,
		        'goal' => g,
		        'pi' => pi}
		code, _ = put_data(agent['sfpAddress'], agent['sfpPort'], SatisfierPath, data)
		(code == '200')
	end

	def get_current_state
		Sfp::Agent.get_state
	end

	def compute_flaws(goal, current)
		flaws = {}
		goal.each { |var,val|
			current_value = current.at?(var)
			if current_value.is_a?(Sfp::Undefined)
				flaws[var] = val if not val.is_a?(Sfp::Undefined)
			else
				current_value.sort! if current_value.is_a?(Array)
				flaws[var]= val if current_value != val
			end
		}
		flaws
	end

	def select_operator(flaws, operators, pi)
		selected_operator = nil
		operators.each { |op|
			next if op['pi'] < pi
			if can_repair?(op, flaws)
				if selected_operator.nil?
					selected_operator = op
				elsif selected_operator['pi'] > op['pi']
					selected_operator = op
				end
			end
		}
		selected_operator
	end

	def split_preconditions(operator)
		local = {}
		remote = {}
		myself = Sfp::Agent.whoami?
		operator['precondition'].each { |var,val|
			_, agent_name, _ = var.split('.', 3)
			if agent_name = myself
				local[var] = val
			else
				remote[var] = val
			end
		}
		[local, remote]
	end

	def invoke(operator)
		Sfp::Agent.execute_action(operator)
	end
end
