#!/usr/bin/env ruby

class Planner
	def initialize(p={})
		# TODO
		# - build from SAS string
		# - generate image dependencies and joints graph

		@vars = []
		@variables = {}
		@ops = []
		@operators = {}
		@init = @goal = nil

		lines = p[:sas].split("\n")
		i = 0
		while i < lines.length
			if lines[i] == 'begin_variable'
				i, var = Variable.read(i, lines)
				@vars << var
				@variables[var.sym] = var
			elsif lines[i] == 'begin_operator'
				i, op = Operator.read(i, lines, @vars)
				@ops << op
				@operators[op.sym] = op
			elsif lines[i] == 'begin_state'
				i, @init = State.read(i, lines, @vars)
			elsif lines[i] == 'begin_goal'
				i, @goal = State.read(i, lines, @vars)
			end
			i += 1
		end

		@ops.each { |op| op.update_variables_joints_and_dependencies(@variables) }

		puts "#{@vars.length} variables"
		puts "#{@ops.length} operators"
		puts "#{@init.length} initial state"
		puts "#{@goal.length} goal state"

		@vars.each { |v|
			puts v.to_s
			if v.dependencies.length > 0
				print "\tdep|"
				v.dependencies.each { |k,v| print "#{k}:#{v.length}|" }
				puts ''
			end
			if v.joints.length > 0
				print "\tjoint|"
				v.joints.each { |k,v| print "#{k}:#{v.length}|" }
				puts ''
			end
		}
		@ops.each { |op| puts op.inspect }
		puts @init.inspect
		puts @goal.inspect
	end

	def to_image(p={})
		def self.dot2image(dot, image_file)
			dot_file = "/tmp/#{Time.now.getutc.to_i}.dot"
			File.open(dot_file, 'w') { |f|
				f.write(dot)
				f.flush
			}
			!!system("dot -Tpng -o #{image_file} #{dot_file}")
		ensure
			File.delete(dot_file) if File.exist?(dot_file)
		end

		dot = "digraph {\n"
		@variables.each do |sym,var|
			name = var.name.gsub(/[\s\.\$]/, '_')
			dot += "#{name} [label=\"#{var.name}\", shape=rect];\n"
		end
		@variables.each do |sym,var|
			name = var.name.gsub(/[\s\.\$]/, '_')
			var.dependencies.each { |sym,operators|
				var2 = @variables[sym]
				name2 = var2.name.gsub(/[\s\.\$]/, '_')
				dot += "#{name} -> #{name2} ;\n"
			}
		end
		dot += "}"
puts dot

		dot2image(dot, p[:file])
	end

	class Variable < Array
		attr_reader :name, :sym
		attr_accessor :init, :goal, :joints, :dependencies

		def self.read(i, lines)
			var = Variable.new(lines[i+1])
			i += 4
			i.upto(lines.length) do |j|
				i = j
				break if lines[j] == 'end_variable'
				var << lines[j].to_sym
			end
			fail "Cannot find end_variable" if lines[i] != 'end_variable'
			[i, var]
		end
	
		def initialize(name, init=nil, goal=nil)
			@name = name
			@sym = @name.to_sym
			@values = []
			@map = {}
			@init = init
			@goal = goal
			@joints = {}
			@dependencies = {}
		end

		alias :super_to_s :to_s
		def to_s
			@name + " " + super_to_s
		end
	end
	
	class Operator
		attr_reader :name, :sym
		attr_accessor :cost, :preconditions, :postconditions, :variables

		def self.read(i, lines, variables)
			op = Operator.new(lines[i+1])
			i += 2
			last = nil
			i.upto(lines.length) do |j|
				i = j
				break if lines[j] == 'end_operator'
				parts = lines[j].split(' ')
				if parts.length > 1
					var = variables[parts[1].to_i]
					pre = (parts[2] == '-1' ? nil : var[parts[2].to_i])
					post = (parts[3].nil? ? nil : var[parts[3].to_i])
					op.param var, pre, post
				end
				last = lines[j]
			end
			op.cost = last.to_i
			fail "Cannot find end_operator" if lines[i] != 'end_operator'
			[i, op]
		end
	
		def initialize(name, cost=1)
			@name = name
			@sym = @name.to_sym
			@cost = cost
			@preconditions = {}
			@postconditions = {}
			@variables = {}
		end
	
		def param(variable, pre=nil, post=nil)
			return if variable.nil? or (pre.nil? and post.nil?)
			if !pre.nil?
				fail "Invalid precondition #{variable.name}:#{pre}" if !variable.index(pre)
				@preconditions[variable.sym] = pre
			end
			if !post.nil?
				fail "Invalid postcondition #{variable.name}:#{post}" if !variable.index(post)
				@postconditions[variable.sym] = post
			end
			@variables[variable.sym] = variable
		end
	
		def applicable(state)
			@preconditions.each { |var,pre| return false if state[var.sym] != pre }
			true
		end
	
		def apply(state)
			@postconditions.each { |var,post| state[var.sym] = post }
		end

		def update_variables_joints_and_dependencies(variables)
			@postconditions.each_key { |post|
				var_post = variables[post]
				@preconditions.each_key { |pre|
					next if post == pre
					var_pre = variables[pre]
					if !var_post.dependencies.has_key?(pre)
						var_post.dependencies[pre] = [self]
					else
						var_post.dependencies[pre] << self
					end
				}
				@postconditions.each_key { |post2|
					next if post == post2
					var_post2 = variables[post2]
					if !var_post.joints.has_key?(post2)
						var_post.joints[post2] = [self]
					else
						var_post.joints[post2] << self
					end
				}
			}
		end

		def to_s
			@name + " pre:" + @preconditions.inspect + " post:" + @postconditions.inspect
		end
	end
	
	class State < Hash
		attr_reader :id

		def self.read(i, lines, variables)
			state = State.new(lines[i] == 'begin_state' ? 'init' : 'goal')
			if state.id == 'init'
				i += 1
				var_index = 0
				i.upto(lines.length) do |j|
					i = j
					break if lines[j] == 'end_state'
					var = variables[var_index]
					state[var.sym] = var[lines[j].to_i]
					var_index += 1
				end
				fail "Cannot find end_state" if lines[i] != 'end_state'
				[i, state]
			elsif state.id == 'goal'
				i += 2
				i.upto(lines.length) do |j|
					i = j
					break if lines[j] == 'end_goal'
					parts = lines[j].split(' ')
					var = variables[parts[0].to_i]
					state[var.sym] = var[parts[1].to_i]
				end
				fail "Cannot find end_goal" if lines[i] != 'end_goal'
				[i, state]
			end
		end

		def initialize(id)
			@id = id
		end
	end
end

if $0 == __FILE__ and ARGV.length > 0
	planner = Planner.new(:sas => File.read(ARGV[0]))
	planner.to_image(:file => 'domain.png')
end
