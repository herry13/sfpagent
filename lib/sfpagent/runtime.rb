require 'thread'

class Sfp::Runtime
	attr_reader :modules

	def initialize(model)
		@mutex_procedure = Mutex.new
		@mutex_get_state = Mutex.new
		@root = model
		@modules = nil
	end

	def execute_action(action)
		def normalise_parameters(params)
			p = {}
			params.each { |k,v| p[k[2,k.length-2]] = v }
			p
		end

		self.get_state if not defined?(@modules) or @modules.nil?

		module_path, method_name = action['name'].pop_ref
		mod = @modules.at?(module_path)[:_self]
		raise Exception, "Module #{module_path} cannot be found!" if mod.nil?
		raise Exception, "Cannot execute #{action['name']}!" if not mod.respond_to?(method_name)

		params = normalise_parameters(action['parameters'])
		if mod.synchronized.rindex(method_name)
			@mutex_procedure.synchronize { mod.send method_name.to_sym, params }
		else
			mod.send method_name.to_sym, params
		end

		# TODO - check post-execution state for verification
	end

	def get_state(as_sfp=false)
		def cleanup(model)
			model.select { |k,v| k[0,1] != '_' and !(v.is_a?(Hash) and v['_context'] != 'object') }
		end

		def add_hidden_attributes(model, state)
			model.each { |k,v|
				state[k] = v if (k[0,1] == '_' and k != '_parent') or
					(v.is_a?(Hash) and v['_context'] == 'procedure')
			}
		end

		# Load the implementation of an object, and return its current state
		# @param model a Hash
		# @return a Hash which is the state of the object
		#
		def instantiate_module(model, root, as_sfp=false)
			# extract class name
			class_name = model['_isa'].sub(/^\$\./, '')

			# throw an exception if schema's implementation is not exist!
			raise Exception, "Implementation of schema #{class_name} is not available!" if
				not Sfp::Module.const_defined?(class_name)

			# create an instance of the schema
			mod = Sfp::Module::const_get(class_name).new
			default = cleanup(root.at?(model['_isa']))
			ruby_model = cleanup(model)
			mod.init(ruby_model, default)

			# update synchronized list of procedures
			model.each { |k,v|
				next if k[0,1] == '_' or not (v.is_a?(Hash) and v['_context'] == 'procedure')
				mod.synchronized << k if v['_synchronized']
			}

			# return the object instant
			mod
		end

		# Return the state of an object
		#
		def get_object_state(model, root, as_sfp=false, construct_model_only=false, path='$')
			modules = {}
			state = {}
			if model['_context'] == 'object' and model['_isa'].to_s.isref
				if model['_isa'] != '$.Object'
					# if this model is an instance of a subclass of Object, then
					# get the current state of this object
					#modules[:_self] = nil
					mod = (!defined?(@modules) or @modules.nil? ? nil : @modules.at?(path))
					if mod.is_a?(Hash)
						modules[:_self] = mod[:_self]
					else
						# the module has not been instantiated yet!
						modules[:_self] = instantiate_module(model, root, as_sfp)
					end
					# update and get the state
					modules[:_self].update_state if not construct_model_only
					state = modules[:_self].state
					if !mod.nil? and mod.has_key?(:_vars)
						state.keep_if { |k,v| mod[:_vars].index(k) }
						modules[:_vars] = mod[:_vars]
					else
						modules[:_vars] = state.keys
					end
					# set hidden attributes
					add_hidden_attributes(model, state) if as_sfp
				end
			end

			# get the state for each attributes which are not covered by this
			# object's module
			(model.keys - state.keys).each do |key|
				next if key[0,1] == '_'
				if model[key].is_a?(Hash)
					modules[key], state[key] = get_object_state(model[key], root, as_sfp, path.push(key)) if
						model[key]['_context'] == 'object'
					modules[key]['_parent'] = modules if modules[key].is_a?(Hash)
				else
					state[key] = Sfp::Undefined.new
				end
			end

			[modules, state]
		end

		@mutex_get_state.synchronize {
			root = Sfp::Helper.deep_clone(@root)
			root.accept(ParentEliminator)
			@modules, _ = get_object_state(root, root, as_sfp, true)
			@modules, state = get_object_state(root, root, as_sfp)
			@modules.accept(ParentGenerator)

			state
		}
	end

	def whoami?
		@root.each { |key,value| return key if key[0,1] != '_' and value['_context'] == 'object' } if !@root.nil?
		nil
	end

	protected
	ParentEliminator = Sfp::Visitor::ParentEliminator.new

	ParentGenerator = Object.new
	def ParentGenerator.visit(name, value, parent)
		value['_parent'] = parent if value.is_a?(Hash)
		true
	end

end
