require 'thread'

class Sfp::BSig
	include Sfp::Net::Helper

	SleepTime = 5
	MaxTries = 5

	SatisfierPath = '/bsig/satisfier'
	CacheDir = (Process.euid == 0 ? '/var/sfpagent' : File.expand_path('~/.sfpagent'))
	SatisfierLockFile = "#{CacheDir}/bsig.satisfier.lock.#{Time.now.nsec}"

	attr_reader :enabled, :status, :mode

	def initialize(p={})
		@lock = Mutex.new
		@enabled = false
		@status = :stopped
	end

	def stop
		@enabled = false
	end

	def start
		@enabled = true
		@lock.synchronize {
			return if @status == :running
			@status = :running
		}

		Thread.new {
			register_satisfier_thread(:reset)
	
			system("rm -f #{CacheDir}/operator.*.lock")
	
			Sfp::Agent.logger.info "[main] BSig engine is running."
	
			puts "BSig Engine is running with PID #{$$}"
			File.open(Sfp::Agent::BSigPIDFile, 'w') { |f| f.write($$.to_s) }
	
			self.execute_model
	
			File.delete(SatisfierLockFile) if File.exist?(SatisfierLockFile)
			Sfp::Agent.logger.info "[main] BSig engine has stopped."

			@status = :stopped
		}
	end

	def execute_model
		Sfp::Agent.logger.info "[main] Executing BSig model"

		previous_exec_status = exec_status = nil
		while @enabled
			begin
	
				wait_for_satisfier?
	
				bsig = Sfp::Agent.get_bsig
				if bsig.nil?
					exec_status = :no_bsig
					sleep SleepTime
				else
					exec_status = achieve_local_goal(bsig['id'], bsig['goal'], bsig['operators'], 1, :main)
					if exec_status == :failure
						Sfp::Agent.logger.error "[main] Executing BSig model [Failed]"
						sleep SleepTime
					elsif exec_status == :no_flaw
						sleep SleepTime
					end
				end

				if previous_exec_status != exec_status
					Sfp::Agent.logger.info "[main] BSig engine - status: " + exec_status.to_s
					previous_exec_status = exec_status
				end
			rescue Exception => e
				Sfp::Agent.logger.error "[main] Error on executing BSig model\n#{e}\n#{e.backtrace.join("\n")}"
				sleep SleepTime
			end
		end
	end

	def wait_for_satisfier?
		total_satisfier = 1
		loop do
			total_satisfier = (File.exist?(SatisfierLockFile) ? File.read(SatisfierLockFile).to_i : 0)
			return if total_satisfier <= 0 or not @enabled
			sleep 1
		end
	end

	# returns
	#   :no_flaw  => there is no goal-flaw
	#   :failure  => there is a failure on achieving the goal
	#   :ongoing  => the selected operator is being executed
	#   :repaired => some goal-flaws have been repaired, but the goal may have other flaws
	#
	def achieve_local_goal(id, goal, operators, pi, mode)
		operator = nil

		current = get_current_state
		flaws = compute_flaws(goal, current)
		return :no_flaw if flaws.length <= 0

		operator = select_operator(flaws, operators, pi)
		return :failure if operator.nil?

#Sfp::Agent.logger.info "[#{mode}] Flaws: #{JSON.generate(flaws)}"  # debugging

		return :ongoing if not lock_operator(operator)

		Sfp::Agent.logger.info "[#{mode}] Selected operator: #{operator['name']}"

		next_pi = operator['pi'] + 1
		pre_local, pre_remote = split_preconditions(operator)

#Sfp::Agent.logger.info "[#{mode}] local-flaws: #{JSON.generate(pre_local)}, remote-flaws: #{JSON.generate(pre_remote)}"  # debugging

		status = nil
		tries = MaxTries
		begin
			status = achieve_local_goal(id, pre_local, operators, next_pi, mode)
			if status == :no_flaw or status == :failure or not @enabled
				break
			elsif status == :ongoing
				sleep SleepTime
				tries += 1
			elsif status == :repaired
				tries = MaxTries
			end
			tries -= 1
		end until tries <= 0

		if status != :no_flaw or
			not achieve_remote_goal(id, pre_remote, next_pi, mode) or
			not invoke(operator, mode)

			unlock_operator(operator) if not operator.nil?
			return :failure
		end
		
		unlock_operator(operator) if not operator.nil?
		:repaired
	end

	def achieve_remote_goal(id, goal, pi, mode)
		if goal.length > 0
			agents = Sfp::Agent.get_agents
			split_goal_by_agent(goal).each do |agent_name,agent_goal|
				return false if not agents.has_key?(agent_name) or agents[agent_name]['sfpAddress'].to_s == ''

				return false if not send_goal_to_agent(agents[agent_name], id, agent_goal, pi, agent_name, mode)
			end
		end
		true
	end

	def receive_goal_from_agent(id, goal, pi)
		register_satisfier_thread

		return false if not @enabled

		bsig = Sfp::Agent.get_bsig

		return false if bsig.nil? or id < bsig['id']

		status = nil
		tries = MaxTries
		begin
			status = achieve_local_goal(bsig['id'], goal, bsig['operators'], pi, :satisfier)
			if status == :no_flaw or status == :failure or not @enabled
				break
			elsif status == :ongoing
				sleep SleepTime
				tries += 1
			elsif status == :repaired
				tries = MaxTries
			end
			tries -= 1
		end until tries <= 0

		return (status == :no_flaw)

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

	def lock_operator(operator)
		@lock.synchronize {
			operator_lock_file = "#{CacheDir}/operator.#{operator['name']}.lock"
			return false if File.exist?(operator_lock_file)
			File.open(operator_lock_file, 'w') { |f| f.write('1') }
			return true
		}
	end

	def unlock_operator(operator)
		@lock.synchronize {
			operator_lock_file = "#{CacheDir}/operator.#{operator['name']}.lock"
			File.delete(operator_lock_file) if File.exist?(operator_lock_file)
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

	def send_goal_to_agent(agent, id, g, pi, agent_name='', mode)
		data = {'id' => id,
		        'goal' => JSON.generate(g),
		        'pi' => pi}

		Sfp::Agent.logger.info "[#{mode}] Request goal to: #{agent_name} [WAIT]"

		code, _ = put_data(agent['sfpAddress'], agent['sfpPort'], SatisfierPath, data)

		Sfp::Agent.logger.info "[#{mode}] Request goal to: #{agent_name} - status: #{code}"

		(code == '200')
	end

	def get_current_state
		state = Sfp::Agent.get_state
		fail "BSig engine cannot get current state" if state == false
		state
	end

	def compute_flaws(goal, current)
		return goal.clone if current.nil?
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
		operator['effect'].each { |variable,value| return true if flaws[variable] == value }
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

	def invoke(operator, mode)
		Sfp::Agent.logger.info "[#{mode}] Invoking #{operator['name']}"
		Sfp::Agent.execute_action(operator)
	end
end
