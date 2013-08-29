require 'thread'

class Sfp::BSig
	include Nuri::Net::Helper

	BSigSleepTime = 5
	MaxTries = 5

	SatisfierPath = '/bsig/satisfier'
	CachedDir = (Process.euid == 0 ? '/var/sfpagent' : File.expand_path('~/.sfpagent'))
	SatisfierLockFile = "#{CachedDir}/bsig.satisfier.lock.#{Time.now.nsec}"

	attr_reader :enabled, :mode

	def initialize(p={})
		@lock = Mutex.new
		@enabled = false
	end

	def disable
		@enabled = false
	end

	def enable(p={})
		@lock.synchronize {
			return if @enabled
			@enabled = true
		}

		if p[:mode] == :main
			enable_main_thread
		elsif p[:mode] == :satisfier
			enable_satisfier_thread
		end
	end

	def enable_satisfier_thread
		@mode = :satisfier
		Sfp::Agent.logger.info "[satisfier] BSig engine is enabled."
	end

	def enable_main_thread
		@mode = :main

		['INT', 'KILL', 'HUP'].each { |signal|
			trap(signal) {
				Sfp::Agent.logger.info "Shutting down BSig engine"
				File.delete(SatisfierLockFile) if File.exist?(SatisfierLockFile)
				disable
			}
		}
		register_satisfier_thread(:reset)

		Sfp::Agent.logger.info "[main] BSig engine is running."

		puts "BSig Engine is running with PID #{$$}"
		File.open(Sfp::Agent::BSigPIDFile, 'w') { |f| f.write($$.to_s) }

		self.execute_model

		Sfp::Agent.logger.info "[main] BSig engine has stopped."
	end

	def execute_model
		Sfp::Agent.logger.info "[main] Executing BSig model"

		while @enabled
			begin
	
				wait_for_satisfier?
	
				bsig = Sfp::Agent.get_bsig
				if bsig.nil?
					sleep BSigSleepTime
				else
					status = achieve_local_goal(bsig['id'], bsig['goal'], bsig['operators'], 1, :main)
					if status == :failure
						Sfp::Agent.logger.error "[main] Executing BSig model [Failed]"
						sleep BSigSleepTime
					elsif status == :no_flaw
						sleep BSigSleepTime
					end
				end
			rescue Exception => e
				Sfp::Agent.logger.error "Error on executing BSig model\n#{e}\n#{e.backtrace.join("\n")}"
				sleep BSigSleepTime
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
	# :no_flaw   : there is no goal-flaw
	# :failure   : there is a failure on achieving the goal
	# :ongoing   : the selected operator is being executed
	# :repaired  : some goal-flaws have been repaired, but the goal may have other flaws
	def achieve_local_goal(id, goal, operators, pi, mode=nil)
		operator = nil

		current = get_current_state
		flaws = compute_flaws(goal, current)
		return :no_flaw if flaws.length <= 0

		operator = select_operator(flaws, operators, pi)
		return :failure if operator.nil?

		@lock.synchronize {
			return :ongoing if operator['selected']
			operator['selected'] = true
		}
#Sfp::Agent.logger.info "[#{mode}] Selected operator: #{JSON.generate(operator)}"

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

		return :failure if status != :no_flaw

		return :failure if not achieve_remote_goal(id, pre_remote, next_pi)

		return :failure if not invoke(operator)
		
		:repaired

	ensure
		@lock.synchronize { operator['selected'] = false } if not operator.nil?
	end

	def achieve_remote_goal(id, goal, pi)
		if goal.length > 0
			agents = Sfp::Agent.get_agents
			split_goal_by_agent(goal).each do |agent_name,agent_goal|
				return false if not agents.has_key?(agent_name) or agents[agent_name]['sfpAddress'].to_s == ''

Sfp::Agent.logger.info "send_goal_to_agent #{agent_name} - status: " + code.to_s
				return false if not send_goal_to_agent(agents[agent_name], id, agent_goal, pi)
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
				sleep BSigSleepTime
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

	def invoke(operator)
		Sfp::Agent.execute_action(operator)
	end
end
