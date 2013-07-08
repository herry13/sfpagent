class Sfp::Runtime
	def initialize(parser)
		@parser = parser
		@root = @parser.root
	end

	def execute_action(action)
		def normalise_parameters(params)
			p = {}
			params.each { |k,v| p[k[2,k.length-2]] = v }
			p
		end

		self.get_state if not defined? @modules

		module_path, method_name = action['name'].pop_ref
		mod = @modules.at?(module_path)[:_self]
		raise Exception, "Module #{module_path} cannot be found!" if mod.nil?
		raise Exception, "Cannot execute #{action['name']}!" if not mod.respond_to?(method_name)

		params = normalise_parameters(action['parameters'])
		mod.send method_name.to_sym, params
	end

	def get_state(sfp=false)
		def cleanup(value)
			#value.accept(SfpState.new)
			#value
			value.select { |k,v| k[0,1] != '_' and !(v.is_a?(Hash) and v['_context'] != 'object') }
			#value.keys.each { |k| value[k] = cleanup(value[k]) if value[k].is_a?(Hash) }
		end

		# Load the implementation of an object, and return its current state
		# @param value a Hash
		# @return a Hash which is the state of the object
		#
		def get_module_state(value, root, sfp=false)
			# extract class name
			class_name = value['_isa'][2, value['_isa'].length]

			# throw an exception if schema's implementation is not exist!
			raise Exception, "Implementation of schema #{class_name} is not available!" if
				Sfp::Module.constants.index(class_name.to_sym).nil?

			# create an instance of the schema
			mod = Sfp::Module::const_get(class_name).new
			model = cleanup(root.at?(value['_isa']))
			mod.init(cleanup(value), model)

			# update and get state
			mod.update_state
			state = mod.state

			if sfp
				# insert all hidden attributes, except "_parent"
				value.each { |k,v|
					next if k[0,1] != '_' or k == '_parent'
					state[k] = v
				}
				value.each { |k,v|
					next if !v.is_a?(Hash) or v['_context'] != 'procedure'
					state[k] = v
				}
			end

			[mod, state]
		end

		# Return the state of an object
		#
		def get_object_state(value, root, sfp=false)
			modules = {}
			state = {}
			if value['_context'] == 'object' and value['_isa'].to_s.isref
				if value['_isa'] != '$.Object'
					# if this value is an instance of a subclass of Object, then
					# get the current state of this object
					modules[:_self], state = get_module_state(value, root, sfp)
				end
			end

			# get the state for each attributes which are not covered by this
			# object's module
			(value.keys - state.keys).each { |key|
				next if key[0,1] == '_'
				if value[key].is_a?(Hash)
					modules[key], state[key] = get_object_state(value[key], root, sfp) if value[key]['_context'] == 'object'
				else
					state[key] = Sfp::Undefined.new
				end
			}

			[modules, state]
		end

		root = Sfp::Helper.deep_clone(@root)
		root.accept(Sfp::Visitor::ParentEliminator.new)
		@modules, state = get_object_state(root, root, sfp)

		state
	end

	def execute_plan(plan)
		plan = JSON[plan]
		if plan['type'] == 'sequential'
			execute_sequential_plan(plan)
		else
			raise Exception, "Not implemented yet!"
		end
	end

	protected
	class SfpState
		def visit(name, value, parent)
			parent.delete(name) if name[0,1] == '_' or
				(value.is_a?(Hash) and value['_context'] != 'object')
			true
		end
	end

	def execute_sequential_plan(plan)
		puts 'Execute a sequential plan...'

		plan['workflow'].each_index { |index|
			action = plan['workflow'][index]
			print "#{index+1}) #{action['name']} "
			if not execute_action(action)
				puts '[Failed]'
				return false
			end
			puts '[OK]'
		}
		true
	end
end

=begin
		def execute(plan)
			plan = JSON.parse(plan)
			if plan['type'] == 'sequential'
				execute_sequential(plan)
			else
				execute_parallel(plan)
			end
		end


		def execute_sequential(plan)
			puts 'Execute a sequential plan...'

			plan['workflow'].each_index { |index|
				action = plan['workflow'][index]
				print "#{index+1}) #{action['name']} "

				module_path, method_name = action['name'].pop_ref
				mod = @modules.at?(module_path)[:_self]
				raise Exception, "Cannot execute #{action['name']}!" if not mod.respond_to?(method_name)
				if not mod.send method_name.to_sym, normalise_parameters(action['parameters'])
					puts '[Failed]'
					return false
				end

				puts '[OK]'
			}
			true
		end

		def execute_parallel(plan)
			# TODO
			puts 'Execute a parallel plan...'
			false
		end
=end

=begin
		def plan
			# generate initial state
			task = { 'initial' => Sfp::Helper.to_state('initial', self.get_state(true)) }

			# add schemas
			@root.each { |k,v|
				next if !v.is_a?(Hash) or v['_context'] != 'class'
				task[k] = v
			}

			# add goal constraint
			model = @root.select { |k,v| v.is_a?(Hash) and v['_context'] == 'object' }
			goalgen = Sfp::Helper::GoalGenerator.new
			model.accept(goalgen)
			task['goal'] = goalgen.results

			# remove old parent links
			task.accept(Sfp::Visitor::ParentEliminator.new)

			# reconstruct Sfp parent links
			task.accept(Sfp::Visitor::SfpGenerator.new(task))

			# solve and return the plan solution
			planner = Sfp::Planner.new
			planner.solve({:sfp => task, :pretty_json => true})
		end
=end



=begin
	module Helper
		def self.create_object(name)
			{ '_self' => name, '_context' => 'object', '_isa' => '$.Object', '_classes' => ['$.Object'] }
		end

		def self.create_state(name)
			{ '_self' => name, '_context' => 'state' }
		end

		def self.to_state(name, value)
			raise Exception, 'Given value should be a Hash!' if not value.is_a?(Hash)
			value['_self'] = name
			value['_context'] = 'state'
			value
		end

		module Constraint
			def self.equals(value)
				{ '_context' => 'constraint', '_type' => 'equals', '_value' => value }
			end

			def self.and(name)
				{ '_context' => 'constraint', '_type' => 'and', '_self' => name }
			end
		end

		class GoalGenerator
			attr_reader :results

			def initialize
				@results = Sfp::Helper::Constraint.and('goal')
			end
				
			def visit(name, value, parent)
				return false if name[0,1] == '_'
				if value.is_a?(Hash)
					return true if value['_context'] == 'object'
					return false
				end

				@results[ parent.ref.push(name) ] = Sfp::Helper::Constraint.equals(value)
				false
			end
		end
	end
=end
