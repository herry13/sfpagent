require 'thread'

class Sfp::BSig
	include Sfp::Helper::Net

	SleepTime = 5
	MaxTries = 5

	SatisfierPath = '/bsig/satisfier'
	Home = ((Process.euid == 0 and File.directory?('/var')) ? '/var/sfpagent' : File.expand_path(Dir.home + '/.sfpagent'))
	SatisfierLockFile = "#{Home}/bsig.satisfier.lock.#{Time.now.to_i}"

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
			begin
				register_satisfier_thread(:reset)
	
				system("rm -f #{Home}/operator.*.lock")
				system("rm -f #{Home}/bsig.satisfier.lock.*")
	
				Sfp::Agent.logger.info "[main] BSig engine is running."
	
				puts "BSig Engine is running with PID #{$$}"
				File.open(Sfp::Agent::BSigPIDFile, 'w') { |f| f.write($$.to_s) }
	
				self.execute_model
	
				File.delete(SatisfierLockFile) if File.exist?(SatisfierLockFile)
				Sfp::Agent.logger.info "[main] BSig engine has stopped."

			rescue Exception => exp
				Sfp::Agent.logger.error "Cannot start BSig engine => #{exp}\n#{exp.backtrace.join("\n")}"
			end
			
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
					bsig['operators'].sort! { |op1,op2| op1['pi'] <=> op2['pi'] }
					exec_status = achieve_local_goal(bsig['id'], bsig['goal'], bsig['operators'], 1, :main)
					if exec_status == :failure
						Sfp::Agent.logger.error "[main] Executing BSig model [Failed]"
						sleep SleepTime
					elsif exec_status == :no_flaw or exec_status == :pending
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

	def get_flaws
		bsig = Sfp::Agent.get_bsig
		if bsig.nil?
			{}
		else
			current = get_current_state
			compute_flaws(bsig['goal'], current)
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

	# @param id         BSig's id
	# @param goal       goal state
	# @param operators  an array of sorted (by 'pi') operators
	# @param pi         current priority index value
	# @param mode       'main' thread or 'satisfier' thread
	#
	# @return
	#   :no_flaw  => there is no goal-flaw
	#   :failure  => there is a failure on achieving the goal
	#   :pending  => the selected operator is being executed
	#   :repaired => some goal-flaws have been repaired, but the goal may have other flaws
	#
	def sequential_achieve_local_goal(id, goal, operators, pi, mode)
		operator = nil

		current = get_current_state
		flaws = compute_flaws(goal, current)
		return :no_flaw if flaws.length <= 0

		operator = select_operator(flaws, operators, pi)
		return :failure if operator.nil?
		
		execute_operator(operator, id, operators, mode)
	end

	# @param id         BSig's id
	# @param goal       goal state
	# @param operators  an array of sorted (by 'pi') operators
	# @param pi         current priority index value
	# @param mode       'main' thread or 'satisfier' thread
	#
	# @return
	#   :no_flaw  => there is no goal-flaw
	#   :failure  => there is a failure on achieving the goal
	#   :pending  => the selected operator is being executed
	#   :repaired => some goal-flaws have been repaired, but the goal may have other flaws
	#
	def achieve_local_goal(id, goal, operators, pi, mode)
		parallel_achieve_local_goal(id, goal, operators, pi, mode)
	end

	def parallel_achieve_local_goal(id, goal, operators, pi, mode)
		current = get_current_state
		flaws = compute_flaws(goal, current)

		return :no_flaw if flaws.length <= 0
		
		selected_operators = select_operators(flaws, operators, pi)
		return :failure if selected_operators == :failure
		
		Sfp::Agent.logger.info "total operators: #{selected_operators.length}"

		status = []
		lock = Mutex.new
		selected_operators.each do |operator|
			Thread.new {
				begin
					stat = execute_operator(operator, id, operators, mode)
					Sfp::Agent.logger.info "[#{mode}] Execute_operator: #{operator['name']}#{JSON.generate(operator['parameters'])} => #{stat}"
				rescue Exception => exp
					stat = :failure
					Sfp::Agent.logger.error "[#{mode}] Execute_operator: #{operator['name']}#{JSON.generate(operator['parameters'])} => #{stat} - #{exp}\n#{exp.backtrace.join("\n")}"
				end
				lock.synchronize { status << stat }
			}
		end
		wait_until? { (status.length >= selected_operators.length) }
		Sfp::Agent.logger.info "[#{mode}] exec status: #{status.inspect}"
		status.each { |stat|
			return :failure if stat == :failure
			return :pending if stat == :pending
		}
		:repaired
	end

	def wait_until?
		until yield do
			sleep 1
		end
	end
	
	def execute_operator(operator, id, operators, mode)
		return :pending if not lock_operator(operator)

		status = :failure

		begin
			Sfp::Agent.logger.info "[#{mode}] Selected operator: #{operator['id']}:#{operator['name']}#{JSON.generate(operator['parameters'])}"
	
			next_pi = operator['pi'] + 1
			pre_local, pre_remote = split_preconditions(operator)
	
			# debugging
			Sfp::Agent.logger.info "[#{mode}] local-flaws: #{JSON.generate(pre_local)}, remote-flaws: #{JSON.generate(pre_remote)}"
	
			status = nil
			tries = MaxTries
			begin
				status = achieve_local_goal(id, pre_local, operators, next_pi, mode)
				if status == :no_flaw or status == :failure or not @enabled
					break
				elsif status == :pending
					sleep SleepTime
					tries += 1
				elsif status == :repaired
					tries = MaxTries
				end
				tries -= 1
			end until tries <= 0 and @enabled

			Sfp::Agent.logger.info "[#{mode}] achieve_local_goal => #{status}"
	
			if status != :no_flaw or
				not achieve_remote_goal(id, pre_remote, next_pi, mode) or
				not invoke(operator, mode)

				status = :failure
			end
	
		rescue Exception => exp
			Sfp::Agent.logger.info "[#{mode}] Execute #{operator['name']}{#{operator['parameters']}} [Error]"
			status = :failure
		end

		unlock_operator(operator) if not operator.nil?
		status
	end

	def achieve_remote_goal(id, goal, pi, mode)
		if goal.length > 0
			agents = Sfp::Agent.get_agents
			status = []
			lock = Mutex.new
			agents_goal = split_goal_by_agent(goal)
			agents_goal.each do |agent_name,agent_goal|
				Thread.new {
					begin
						stat = achieve_remote_agent_goal(agents, agent_name, agent_goal, id, pi, mode)
						Sfp::Agent.logger.info "[#{mode}] remote goal => #{agent_name}: #{agent_goal.inspect} - #{stat}"
					rescue Exception => exp
						stat = false
						Sfp::Agent.logger.error "[#{mode}] remote goal => #{agent_name}: #{agent_goal.inspect} - #{stat} - #{exp}\n#{exp.backtrace.join("\n")}"
					end
					lock.synchronize { status << stat }
				}
			end
			wait_until? { status.length >= agents_goal.length }
			Sfp::Agent.logger.info "[#{mode}] achieve_remote_goal: #{status}"
			status.each { |stat| return false if !stat }
		end
		true
	end

	def achieve_remote_agent_goal(agents, name, goal, id, pi, mode)
		if agents.has_key?(name)
			return false if agents[name]['sfpAddress'].to_s == ''
			return false if not send_goal_to_agent(agents[name], id, goal, pi, name, mode)
		else
			return false if not verify_state_of_not_exist_agent(name, goal)
		end
		true
	end

	def verify_state_of_not_exist_agent(name, goal)
		state = { name => { 'created' => false } }
		goal.each { |var,val|
			return false if state.at?(var) != val
		}
		true
	end

	def receive_goal_from_agent(id, goal, pi, client='')
		register_satisfier_thread

		return false if not @enabled

		bsig = Sfp::Agent.get_bsig
		return false if bsig.nil? or id < bsig['id']

		bsig['operators'].sort! { |op1,op2| op1['pi'] <=> op2['pi'] }
		status = nil
		tries = MaxTries
		begin
			status = achieve_local_goal(bsig['id'], goal, bsig['operators'], pi, "satisfier[#{client}]")
			if status == :no_flaw or status == :failure or not @enabled
				break
			elsif status == :pending
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

	# lock given operator by creating a lock file to avoid another thread
	# executing the same operator
	#
	# @param operator   operator to be locked
	#
	def lock_operator(operator)
		@lock.synchronize {
			operator_lock_file = "#{Home}/operator.#{operator['id']}.#{operator['name']}.lock"
			return false if File.exist?(operator_lock_file)
			File.open(operator_lock_file, 'w') { |f| f.write('1') }
			return true
		}
	end

	# unlock given operator by deleting lock file in order to allow another thread
	# executing the operator
	#
	# @param operator   operator to be unlocked
	#
	def unlock_operator(operator)
		@lock.synchronize {
			operator_lock_file = "#{Home}/operator.#{operator['id']}.#{operator['name']}.lock"
			File.delete(operator_lock_file) if File.exist?(operator_lock_file)
		}
	end

	def split_goal_by_agent(goal)
		agent_goal = {}
		goal.each { |var,val|
			_, agent_name, _ = var.split('.', 3)
			agent_goal[agent_name] = {} if not agent_goal.has_key?(agent_name)
			agent_goal[agent_name][var] = val
		}
		agent_goal
	end

	def send_goal_to_agent(agent, id, goal, pi, agent_name, mode)
		begin
			data = {
				'id' => id,
				'goal' => JSON.generate(goal),
				'pi' => pi
			}
			Sfp::Agent.logger.info "[#{mode}] Request goal to #{agent_name}@#{agent['sfpAddress']}:#{agent['sfpPort']} [WAIT]"
			code, _ = put_data(agent['sfpAddress'], agent['sfpPort'], SatisfierPath, data)
			Sfp::Agent.logger.info "[#{mode}] Request goal to #{agent_name}@#{agent['sfpAddress']}:#{agent['sfpPort']} #{code}"
			(code == '200')
		rescue Exception => exp
			Sfp::Agent.logger.info "[#{mode}] Request goal to #{agent_name} - error: #{exp}\n#{exp.backtrace.join("\n")}"
			return true if check_not_created_agent(agent_name, goal)
			false
		end
	end

	def check_not_created_agent(agent_name, goal)
		state = Sfp::Agent.get_state
		vms = {}
		Sfp::Agent.runtime.cloudfinder.clouds.each { |cloud|
			cloud.sub!(/^\$\./, '')
			cloud_ref = "$.#{Sfp::Agent.whoami?}.#{cloud}"
			ref = "#{cloud_ref}.vms"
			vms = state.at?(ref)
			vms.each { |name,status| vms[name] = {'created' => true} } if vms.is_a?(Hash)
		} if Sfp::Agent.runtime
		if not vms.has_key?(agent_name)
			state = {agent_name => {'created' => false, 'in_cloud' => nil}}
			goal.each { |var,val| return false if state.at?(var) != val }
			return true
		end
		false
	end

	def get_current_state
		state = Sfp::Agent.get_state
		fail "BSig engine cannot get current state" if state == false

		Sfp::Agent.runtime.cloudfinder.clouds.each { |cloud|
			cloud.sub!(/^\$\./, '')
			cloud_ref = "$.#{Sfp::Agent.whoami?}.#{cloud}"
			ref = "#{cloud_ref}.vms"
			vms = state.at?(ref)
			if vms.is_a?(Hash)
				vms.each { |name,status|
					state[name] = { 'created' => true,
					                'in_cloud' => cloud_ref,
					                'sfpAddress' => status['ip'],
					                'sfpPort' => Sfp::Agent::DefaultPort }
				}
			end
		} if Sfp::Agent.runtime

		state
	end

	def compute_flaws(goal, current)
		return goal.clone if current.nil?
		flaws = {}
		goal.each { |var,val|
			current_value = current.at?(var)
			if current_value.is_a?(Sfp::Unknown)
				_, agent_name, _ = var.split('.', 3)
				if agent_name != Sfp::Agent.whoami?
					s = {agent_name => {'created' => false, 'in_cloud' => nil}}
					current_value = s.at?(var)
				end
			end
			if current_value.is_a?(Sfp::Undefined)
				flaws[var] = val if not val.is_a?(Sfp::Undefined)
			else
				current_value.sort! if current_value.is_a?(Array)
				flaws[var]= val if current_value != val
			end
		}
		flaws
	end

	# @param flaws      a map of flaws (variable-value) that should be repaired
	# @param operators  a sorted-list of operators (sorted by 'pi')
	# @param pi         minimum priority-index value
	#
	# @return           a list of applicable operators, or symbol :failure if all flaws
	#                   cannot be repaired by available operators
	#
	def select_operators(flaws, operators, pi)
		selected_operators = []
		repaired = {}
		operators.each do |op|
			next if op['pi'] < pi
			if can_repair?(op, flaws) and                     # can the operator repair the flaws?
			   not threat_operators?(op, selected_operators)  # does the operator threat other selected operators?
				selected_operators << op
				op['effect'].each { |var,val| repaired[var] = val if flaws[var] == val }
			end
			break if repaired.length >= flaws.length
		end
		if selected_operators.length <= 0 #repaired.length < flaws.length
			Sfp::Agent.logger.error "No flaws can be repaired - pi=#{pi}\nflaws: #{flaws.inspect}"
			return :failure
		end
		selected_operators
	end

	# @param flaws       a map of flaws (variable-value) that should be repaired
	# @param operators   a sorted-list of operators (sorted by 'pi')
	# @param pi          minimum priority-index value
	#
	# @return            an operator that can repair the flaws
	#	
	def select_operator(flaws, operators, pi)
		operators.each do |op|
			next if op['pi'] < pi
			return op if can_repair?(op, flaws)
		end
		nil
	end

	# An operator can repair the flaws iff there is an effect that fixes the flaw
	#
	def can_repair?(operator, flaws)
		operator['effect'].each { |variable,value| return true if flaws[variable] == value }
		false
	end

	# Check if an operator threats a set of operators.
	#
	# @param operator   operator to be checked
	# @param operators  a set of operators
	#
	def threat_operators?(operator, operators)
		operators.each do |op|
			return true if threat?(operator, op)
		end
		false
	end

	# Return true if operator1 threats operator2: there is an effect's variable of operator1
	# is in condition's or effect's variable of operator2
	#
	def threat?(operator1, operator2)
		operator1['effect'].each_key do |variable1|
			return true if operator2['condition'].keys.include?(variable1) or
			               operator2['effect'].keys.include?(variable1)
		end
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
		Sfp::Agent.logger.info "[#{mode}] Invoking #{operator['name']}{#{operator['parameters']}}"

		begin
			status = Sfp::Agent.execute_action(operator)
			if status
				if operator['name'] =~ /^\$(\.[a-zA-Z0-9_]+)*\.(create_vm)/
					postprocess_create_vm(operator)
				elsif operator['name'] =~ /^\$(\.[a-zA-Z0-9_]+)*\.(delete_vm)/
					postprocess_delete_vm(operator)
				end
			end
		rescue Exception => e
			Sfp::Agent.logger.error "Error in invoking operator #{operator['name']}{#{operator['parameters']}}\n#{e}\n#{e.backtrace.join("\n")}"
			return false
		end

		status
	end

	def postprocess_delete_vm(operator)
		_, agent_name, _ = operator['parameters']['$.vm'].split('.', 3)

		Sfp::Agent.logger.info "Postprocess delete VM #{agent_name}"

		# update agents database (automatically broadcast to other agents)
		Sfp::Agent.set_agents({agent_name => nil})
	end

	def postprocess_create_vm(operator)
		3.times do |i|
			refs = operator['name'].split('.')
			vms_ref = refs[0..-2].join('.') + '.vms'

			_, agent_name, _ = operator['parameters']['$.vm'].split('.', 3)

			Sfp::Agent.logger.info "Postprocess create VM #{agent_name}"

			# update proxy component's state
			state = Sfp::Agent.get_state
			return false if not state.is_a?(Hash)

			# get VM's address
			vms = state.at?(vms_ref)
			return false if !vms.is_a?(Hash) or !vms[agent_name].is_a?(Hash) or vms[agent_name]['ip'].to_s.strip == ''
			data = {agent_name => {'sfpAddress' => vms[agent_name]['ip'], 'sfpPort' => Sfp::Agent::DefaultPort}}

			# update agents database
			Sfp::Agent.set_agents(data)

			# get new agent's model and BSig model from cache database
			model = Sfp::Agent.get_cache_model(agent_name)
			model['model']['in_cloud'] = refs[0..-2].join('.')
			model['model']['sfpAddress'] = vms[agent_name]['ip']
			model['model']['sfpPort'] = Sfp::Agent::DefaultPort
			
			if not model.nil?
				address = data[agent_name]['sfpAddress']
				port = data[agent_name]['sfpPort']

				# wait until agent is running
				wait_until? {
					begin
						code, _ = get_data(address, port, '/')
						true
					rescue
						false
					end
				}

				# push required modules
				push_modules(model, address, port)

				# push agent database to new agent
				code, _ = put_data(address, port, '/agents', {'agents' => JSON.generate(Sfp::Agent.get_agents)})

				# push new agent's model
				code1, _ = put_data(address, port, '/model', {'model' => JSON.generate({agent_name => model['model']})})

				# push new agent's BSig model
				code2, _ = put_data(address, port, '/bsig', {'bsig' => JSON.generate(model['bsig'])}) if code == '200'

				return (code1 == '200' and code2 == '200')
			end
		end
		false
	end

	def push_modules(agent_model, address, port)
		name = agent_model['_self']
		finder = Sfp::Helper::SchemaCollector.new
		{:agent => agent_model}.accept(finder)
		schemata = finder.schemata.uniq.map { |x| x.sub(/^\$\./, '').downcase }

		modules_dir = Sfp::Agent.config[:modules_dir]
		install_module = File.expand_path('../../../bin/install_module', __FILE__)

		begin
			# get modules list
			code, body = get_data(address, port, '/modules')
			raise Exception, "Unable to get modules list from #{name}" if code.to_i != 200

			modules = JSON[body]
			list = ''
			schemata.each { |m|
				list += "#{m} " if File.exist?("#{modules_dir}/#{m}") and
				                   (not modules.has_key?(m) or modules[m] != get_local_module_hash(m, modules_dir).to_s)
			}

			return true if list == ''

			if system("cd #{modules_dir}; #{install_module} #{address} #{port} #{list} 1>/dev/null 2>/tmp/install_module.error")
				Sfp::Agent.logger.info "Push modules #{list}to #{name} [OK]"
			else
				Sfp::Agent.logger.warn "Push modules #{list}to #{name} [Failed]"
			end

			return true

		rescue Exception => e
			Sfp::Agent.logger.warn "[WARN] Cannot push module to #{name} - #{e}"
		end

		false
	end

	# return the list of Hash value of all modules
	#
	def get_local_module_hash(name, modules_dir)
		module_dir = File.expand_path("#{modules_dir}/#{name}")
		if File.directory? module_dir
			if `which md5sum`.strip.length > 0
				return `find #{module_dir} -type f -exec md5sum {} + | awk '{print $1}' | sort | md5sum | awk '{print $1}'`.strip
			elsif `which md5`.strip.length > 0
				return `find #{module_dir} -type f -exec md5 {} + | awk '{print $4}' | sort | md5`.strip
			end
		end
		nil
	end

end


