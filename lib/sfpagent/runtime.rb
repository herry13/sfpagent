require 'thread'

class Sfp::Runtime
	attr_reader :root, :model, :cloudfinder

	def initialize(model)
		@mutex_procedure = Mutex.new
		@mutex_get_state = Mutex.new
		@root = nil
		@cloudfinder = Sfp::Helper::CloudFinder.new
		set_model(model)
	end

	def whoami?
		@model.each { |key,value| return key if key[0,1] != '_' and value['_context'] == 'object' } if !@model.nil?
		nil
	end

	def execute_action(action)
		return false if !defined?(@root) or @root.nil?

		def normalise_parameters(params)
			p = {}
			params.each { |k,v| p[k[2,k.length-2]] = v }
			p
		end

		module_path, method_name = action['name'].pop_ref
		mod = @root.at?(module_path)[:_self]

		if mod.nil?
			raise Exception, "Module #{module_path} cannot be found!"

		elsif mod.is_a?(Sfp::Module::Shell)
			params = normalise_parameters(action['parameters'])
			mod.execute method_name, params

		elsif not mod.respond_to?(method_name)
			raise Exception, "Cannot execute #{action['name']}!"

		else
			params = normalise_parameters(action['parameters'])
			if mod.synchronized.rindex(method_name)
				@mutex_procedure.synchronize {
					mod.send method_name.to_sym, params
				}
			else
				mod.send method_name.to_sym, params
			end

		end

		# TODO - check post-execution state for verification
	end

	def set_model(model)
		@mutex_get_state.synchronize {
			@model = model
			if @model.is_a?(Hash)
				root_model = Sfp::Helper.deep_clone(@model)
				root_model.accept(SFPtoRubyValueConverter)
				root_model.accept(ParentEliminator)
				@root = update_model(root_model, root_model, '$')
				@root.accept(ParentGenerator)

				@cloudfinder.clouds = []
				@model.accept(@cloudfinder.reset)
			end
		}
	end

	def get_state(as_sfp=false)
		@mutex_get_state.synchronize {
			update_state(@root)
			get_object_state(@root, @model)
		}
	end

	protected
	def get_object_state(object, model)
		# get object's state
		state = (object.has_key?(:_self) ? object[:_self].state : {})

		# add hidden attributes and procedures
		model.each { |k,v|
			state[k] = v if (k[0,1] == '_' and k != '_parent') or
				(v.is_a?(Hash) and v['_context'] == 'procedure')
		}

		# accumulate children's state
		object.each { |name,child|
			next if name.to_s[0,1] == '_' #or state.has_key?(name)
			state[name] = get_object_state(child, model[name])
		}

		# set state=Sfp::Undefined for each attribute that exists in the model
		# but not covered by SFP object instants
		(model.keys - state.keys).each do |name|
			next if name[0,1] == '_'
			state[name] = Sfp::Undefined.new
		end

		state
	end

	def update_state(object)
		object[:_self].update_state if not object[:_self].nil?
		object.each { |k,v| update_state(v) if k.to_s[0,1] != '_' }
	end

	def update_model(model, root, path)
		object = {}
		if model['_context'] == 'object' and model['_isa'].to_s.isref #and model['_isa'].to_s != '$.Object'
			object[:_self] = instantiate_sfp_object(model, path)
		end

		model.each do |key,child|
			if key[0,1] != '_' and child.is_a?(Hash) and child['_context'] == 'object' #and child['_isa'].to_s != '$.Object'
				object[key] = update_model(child, root, path.push(key))
			end
		end

		object
	end

	def shell_module?(schema)
		Sfp::Agent.get_modules.each do |name,data|
			return true if schema == name and data[:type] == :shell
		end
		false
	end
	
	def instantiate_sfp_object(model, path)
		### get SFP schema's name
		schema = model['_isa'].sub(/^\$\./, '')
		object = nil

		if schema[0] =~ /[A-Z]/ and Sfp::Module.const_defined?(schema)
			### create an instance of the schema
			object = Sfp::Module::const_get(schema).new

		elsif shell_module?(schema)
			### get module's metadata
			metadata = Sfp::Agent.get_modules[schema]

			### create module wrapper instance
			object = Sfp::Module::Shell.new(metadata)

		else
			# throw an exception if schema's implementation is not exist!
			raise Exception, "Implementation of schema #{schema} is not available!"

		end

		# initialize the instance
		object.init(model)
			
		# update list of synchronized procedures
		model.each { |k,v|
			next if k[0,1] == '_' or not (v.is_a?(Hash) and v['_context'] == 'procedure')
			object.synchronized << k if v['_synchronized']
		}

		# set object's path
		object.path = path

		object
	end

	ParentEliminator = Sfp::Visitor::ParentEliminator.new

	ParentGenerator = Object.new
	def ParentGenerator.visit(name, value, parent)
		value['_parent'] = parent if value.is_a?(Hash)
		true
	end

	SFPtoRubyValueConverter = Object.new
	def SFPtoRubyValueConverter.visit(name, value, parent)
		if name[0,1] != '_' and value.is_a?(Hash)
			if value['_context'] == 'null'
				parent[name] = nil
			elsif value['_context'] == 'set'
				parent[name] = value['_values']
			end
		end
		true
	end
end
