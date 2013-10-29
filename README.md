SFP Agent for Ruby
==================
- Author: Herry (herry13@gmail.com)
- License: [BSD License](https://github.com/herry13/sfpagent/blob/master/LICENSE)

[![Build Status](https://travis-ci.org/herry13/sfpagent.png?branch=master)](https://travis-ci.org/herry13/sfpagent)
[![Gem Version](https://badge.fury.io/rb/sfpagent.png)](http://badge.fury.io/rb/sfpagent)

A Ruby script and library of SFP agent. The agent could be accessed through HTTP RESTful API.

With this agent, you could get the state and deploy configuration of particular software components.
Each configuration should be specified in [SFP language](https://github.com/herry13/sfp).
Every software component could have a set of methods which could be called through HTTP request.


Requirements
------------
- Ruby (>= 1.8.7)
- Ruby Gems
	- sfp


To install
----------
- Ruby 1.8.7

		$ apt-get install ruby ruby-dev libz-dev libaugeas-ruby
		$ gem install json
		$ gem install sfpagent

- Ruby 1.9.x

		$ apt-get install ruby1.9.1 ruby1.9.1-dev libz-dev libaugeas-ruby1.9.1
		$ gem install sfpagent


As daemon
---------
- start the agent daemon

		$ sfpagent -s

  In default, the agent will listen at port **1314**.

- stop the agent daemon

		$ sfpagent -t


Cached Directory
----------------
Cached directory keeps all agent's local data such as:
- log file
- PID file
- model file
- installed modules

In default, the agent will use (and created if not exist) the following directory as _cached directory_:
- **~/.sfpagent**, when the daemon is running with non-root user,
- **/var/sfpagent**, when the daemon is running with root user.


HTTP RESTful API
----------------
- GET
	- /state : return the state of the agent
	- /model : return the model of the agent
	- /modules : return the list of modules
	- /log : return the last 100 lines of the log file

- POST
	- /execute : execute an action as specified in "action" parameter

- PUT
	- /model : set/replace the model with given model as specified in "model" parameter
	- /module : set/replace the module if "module" parameter is specified, or delete the module if the parameter is not exist


