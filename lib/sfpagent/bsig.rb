require 'thread'

class Sfp::BSig
	include Nuri::Net::Helper

	BSigSleepTime = 5
	MaxTries = 5

	SatisfierPath = '/bsig/satisfier'
	SatisfierLockFile = Sfp::Agent::CachedDir + '/bsig.satisfier.lock'

	attr_accessor :enabled

	def initialize
		@lock = Mutex.new
		@enabled = false
	end

	def stop
		@enabled = false
		@mode = nil
	end

	def start(mode=:main)
		@lock.synchronize {
			if @enabled
				Sfp::Agent.logger.info "BSig engine [#{@mode.to_s}] is already running!"
				return
			end
			@enabled = true
		}

		@mode = mode

		if mode == :main
			['INT', 'KILL', 'HUP'].each { |signal|
				trap(signal) {
					Sfp::Agent.logger.info "Shutting down BSig engine"
					stop
				}
			}
			register_satisfier_thread(:reset)

			Sfp::Agent.logger.info "[main] BSig engine is running."

			self.execute_model

			File.delete(SatisfierLockFile) if File.exist?(SatisfierLockFile)
	
			Sfp::Agent.logger.info "[main] BSig engine has stopped."

		else
			Sfp::Agent.logger.info "[satisfier] BSig engine is running."

		end
	end

	def execute_model
		while @enabled
			Sfp::Agent.logger.info "[main] Sfp::BSig enabled"

			wait_for_satisfier?

			bsig = Sfp::Agent.get_bsig
			if bsig.nil?
				sleep BSigSleepTime
			else
				status = achieve_local_goal(bsig['id'], bsig['goal'], bsig['operators'], 1, :main)
Sfp::Agent.logger.info "[main] execute model - status: " + status.to_s
				if status == :failure
					Sfp::Agent.logger.error "[main] Executing BSig model [Failed]"
					sleep BSigSleepTime
				elsif status == :no_flaw
					sleep BSigSleepTime
				end
			end
		end
	end

	def wait_for_satisfier?
		total_satisfier = 1
		loop do
			total_satisfier = File.read(SatisfierLockFile)
			return if total_satisfier <= 0
			sleep 1
		end
	end

	# returns
	# :no_flaw   : there is no goal-flaw
	# :failure   : there is a failure on achieving the goal
	# :ongoing   : the selected operator is being executed
	# :repaired  : some goal-flaws have been repaired, but the goal may have other flaws
	def achieve_local_goal(id, goal, operators, pi, mode=nil)
		operator = nil

		current = get_current_state
		flaws = compute_flaws(goal, current)
		return :no_flaw if flaws.length <= 0
Sfp::Agent.logger.info "[#{mode}] Flaws: #{JSON.generate(flaws)}"

		operator = select_operator(flaws, operators, pi)
		return :failure if operator.nil?

		@lock.synchronize {
			return :ongoing if operator['selected']
			operator['selected'] = true
Sfp::Agent.logger.info "[#{mode}] Selected operator: #{JSON.generate(operator)}"
		}

		#@lock.synchronize { operator['selected'] = true }
		next_pi = pi + 1
		pre_local, pre_remote = split_preconditions(operator)

Sfp::Agent.logger.info "[#{mode}] local-flaws: #{JSON.generate(pre_local)}"
Sfp::Agent.logger.info "[#{mode}] remote-flaws: #{JSON.generate(pre_remote)}"

		status = nil
		tries = MaxTries
		begin
			status = achieve_local_goal(id, pre_local, operators, next_pi)
			if status == :no_flaw or status == :failure or not @enabled
				break
			elsif status == :ongoing
				sleep BSigSleepTime
				tries += 1
			elsif status == :repaired
				tries = MaxTries
			end
			tries -= 1
		end until tries <= 0

#Sfp::Agent.logger.info "[#{mode}] status local: " + status.to_s
		return :failure if status == :failure

		return :failure if not achieve_remote_goal(id, pre_remote, next_pi)

		return :failure if not invoke(operator)
		
		:repaired

	ensure
		@lock.synchronize { operator['selected'] = false } if not operator.nil?
	end

	def achieve_remote_goal(id, goal, pi)
		if goal.length > 0
			agents = Sfp::Agent.get_agents
			split_goal_by_agent(goal).each do |agent,g|
				return false if not agents.has_key?(agent) or agents[agent]['sfpAddress'].to_s == ''
				return false if not send_goal_to_agent(agents[agent], id, g, pi)
			end
		end
		true
	end

	def receive_goal_from_agent(id, goal, pi)
		register_satisfier_thread

Sfp::Agent.logger.info "[satisfier] enabled: " + @enabled.to_s
		return false if not @enabled

		bsig = Sfp::Agent.get_bsig

Sfp::Agent.logger.info "[satisfier] receive_goal_from_agent - " + id.inspect + " - " + goal.inspect + " - " + pi.inspect
Sfp::Agent.logger.info "[satisfier] " + bsig.inspect

		return false if bsig.nil? or id < bsig['id']

		status = nil
		tries = MaxTries
		begin
			status = achieve_local_goal(bsig['id'], goal, bsig['operators'], pi, :satisfier)
			if status == :no_flaw or status == :failure or not @enabled
				break
			elsif status == :ongoing
				sleep BSigSleepTime
				tries += 1
			elsif status == :repaired
				tries = MaxTries
			end
			tries -= 1
		end until tries <= 0

		return false if status == :failure

		true

	ensure
		unregister_satisfier_thread
	end

	protected
	def register_satisfier_thread(mode=nil)
		File.open(SatisfierLockFile, File::RDWR|File::CREAT, 0644) { |f|
			f.flock(File::LOCK_EX)
			value = (mode == :reset ? 0 : (f.read.to_i + 1))
			f.rewind
			f.write(value.to_s)
			f.flush
			f.truncate(f.pos)
		}
	end

	def unregister_satisfier_thread
		File.open(SatisfierLockFile, File::RDWR|File::CREAT, 0644) { |f|
			f.flock(File::LOCK_EX)
			value = f.read.to_i - 1
			f.rewind
			f.write(value.to_s)
			f.flush
			f.truncate(f.pos)
		}
	end

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

	def send_goal_to_agent(agent, id, g, pi)
		data = {'id' => id,
		        'goal' => JSON.generate(g),
		        'pi' => pi}
		code, _ = put_data(agent['sfpAddress'], agent['sfpPort'], SatisfierPath, data)
Sfp::Agent.logger.info "send_goal_to_agent - status: " + code.to_s
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
				if agent_name == myself
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
