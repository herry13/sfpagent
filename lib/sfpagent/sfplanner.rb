module Planner
	def initialize(sas)
		# TODO
		# - build from SAS string
		# - generate image dependencies and joins graph
	end

	class Variable < Array
		attr_accessor :init, :goal, :joins, :dependencies
		attr_reader :name
	
		def initialize(name, init=nil, goal=nil)
			@name = name
			@values = []
			@map = {}
			@init = init
			@goal = goal
			@joins = {}
			@dependencies = {}
		end
	end
	
	class Operator
		attr_reader :name, :cost, :preconditions, :postconditions, :variables
	
		def initialize(name, cost=1)
			@name = name
			@cost = cost
			@preconditions = {}
			@postconditions = {}
			@variables = {}
		end
	
		def <<(variable, pre=nil, post=nil)
			return if variable.nil? or (pre.nil? and post.nil?)
			if !pre.nil?
				fail "Invalid precondition #{variable.name}:#{pre}" if !variable.index(pre)
				@preconditions[variable] = pre
			end
			if !post.nil?
				fail "Invalid postcondition #{variable.name}:#{post}" if !variable.index(post)
				@postconditions[variable] = post
			end
			@variables[variable.name] = variable
		end
	
		def applicable(state)
			@preconditions.each { |var,pre| return false if state[var] != pre }
			true
		end
	
		def apply(state)
			@postconditions.each { |var,post| state[var] = post }
		end

		def update_joins_and_dependencies
			@postconditions.each_key { |var_post|
				@preconditions.each_key { |var_pre|
					next if var_post == var_pre
					if !var_post.dependencies.has_key?(var_pre)
						var_post.dependencies[var_pre] = [self]
					else
						var_post.dependencies[var_pre] << self
					end
				}
				@postconditions.each_key { |var_post2|
					next if var_post == var_post2
					if !var_post.joins.has_key?(var_post2)
						var_post.joins[var_post2] = [self]
					else
						var_post.joins[var_post2] << self
					end
				}
			}
		end
	end
	
	class State < Hash
		attr_reader :id
	
		def initialize(id)
			@id = id
		end
	end
end
