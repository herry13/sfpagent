# external dependencies
require 'rubygems'
require 'json'
require 'sfp'

# internal dependencies
libdir = File.expand_path(File.dirname(__FILE__))

require libdir + '/sfpagent/executor.rb'

require libdir + '/sfpagent/runtime.rb'
require libdir + '/sfpagent/module.rb'
