require 'thread'

module Sfp::BSig
	BSigSleepTime = 5
	SatisfierPath = '/bsig/satisfier'
	MaxTries = 5

	attr_accessor :enabled

	def stop
		@enabled = false
	end

	def start
		return if @enabled

		['INT', 'KILL', 'HUP'].each { |signal|
			trap(signal) {
				Sfp::Agent.logger.info "Shutting down BSig engine"
				@enabled = false
			}
		}

		@enabled = true
		Sfp::Agent.logger.info "Starting BSig engine [OK]"

		self.execute_model

		Sfp::Agent.logger.info "BSig engine has stopped."
	end

	def execute_model
		while @enabled
			Sfp::Agent.logger.info "Sfp::BSig enabled"

			wait_for_satisfier?

			bsig = Sfp::Agent.get_bsig
			if bsig.nil?
				sleep BSigSleepTime
			else
				status = achieve_local_goal(bsig['version'], bsig['goal'], bsig['operators'], 1)
Sfp::Agent.logger.info "execute model - status: " + status.to_s
				if status == :failure
					#@enabled = false
					Sfp::Agent.logger.error "Executing BSig model [Failed]"
				elsif status == :no_flaw
					sleep BSigSleepTime
				end
			end
		end
	end

	def wait_for_satisfier?
		# TODO
		false
	end

	# returns
	# :no_flaw   : there is no goal-flaw
	# :failure   : there is a failure on achieving the goal
	# :ongoing   : the selected operator is being executed
	# :repaired  : some goal-flaws have been repaired, but the goal may have other flaws
	def achieve_local_goal(version, goal, operators, pi)
		current = get_current_state
		flaws = compute_flaws(goal, current)
		return :no_flaw if flaws.length <= 0
puts "Flaws: #{JSON.generate(flaws)}"

		operator = select_operator(flaws, operators, pi)
		return :failure if operator.nil?

		return :ongoing if operator['selected']

puts "Selected operator: #{JSON.generate(operator)}"

		operator['selected'] = true
		next_pi = pi + 1
		pre_local, pre_remote = split_preconditions(operator)

#puts "local: #{JSON.generate(pre_local)}"
#puts "remote: #{JSON.generate(pre_remote)}"

		status = nil
		1.upto(MaxTries) do |i|
			status = achieve_local_goal(version, pre_local, operators, next_pi)
			break if status == :no_flaw or status == :failure or not @enabled
		end
#Sfp::Agent.logger.info "status local: " + status.to_s
		
		if status == :failure or
		 achieve_remote_goal(version, pre_remote, next_pi) == :failure or
		 not invoke(operator)
			operator['selected'] = false
			return :failure
		end

		operator['selected'] = false
		return :repaired
	end

	def achieve_remote_goal(version, goal, pi)
		if goal.length > 0
			agents = Sfp::Agent.get_agents
			split_goal_by_agent(goal).each do |agent,g|
				return false if not agents.has_key?(agent) or agents[agent]['sfpAddress'].to_s == ''
				return false if not send_goal_to_agent(agents[agent], version, g, pi)
			end
		end
		true
	end

	def receive_goal_from_agent(version, goal, pi)
		return false if not @enabled

		bsig = Sfp::Agent.get_bsig
		return false if bsig.nil? or version < bsig['version']

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
	def split_goal_by_agent(goal)
		agents = Sfp::Agent.get_agents
		agent_goal = {}
		goal.each { |var,val|
			_, agent_name, _ = var.split('.', 3)
			fail "Agent #{agent_name} is not in database!" if not agents.has_key?(agent_name)
			agent_goal[agent_name] = {} if not agent_goal.has_key?(agent_name)
			agent_goal[agent_name][var] = val
		}
		agent_goal
	end

	def send_goal_to_agent(agent, version, g, pi)
		data = {'version' => version,
		        'goal' => g,
		        'pi' => pi}
		code, _ = put_data(agent['sfpAddress'], agent['sfpPort'], SatisfierPath, data)
		(code == '200')
	end

	def get_current_state
		state = Sfp::Agent.get_state
		fail "BSig engine cannot get current state" if state == false
		state
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

	def can_repair?(operator, flaws)
		operator['effect'].each { |var,val|
			return true if flaws[var] == val
		}
		false
	end

	def split_preconditions(operator)
		local = {}
		remote = {}
		if not operator.nil?
			myself = Sfp::Agent.whoami?
			operator['condition'].each { |var,val|
				_, agent_name, _ = var.split('.', 3)
				if agent_name = myself
					local[var] = val
				else
					remote[var] = val
				end
			}
		end
		[local, remote]
	end

	def invoke(operator)
		Sfp::Agent.execute_action(operator)
	end
end
