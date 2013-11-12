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
- Ruby (>= 1.9.2)
- Ruby Gems
	- sfp


Tested On
---------
- Ruby: 1.9.2, 1.9.3, 2.0.0, JRuby-19mode
- OS: Ubuntu, Debian, MacOS X


To install
----------
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


Home Directory
----------------
Home directory keeps all agent's local data such as:
- log file
- PID file
- model file
- installed modules

In default, the agent will use (and created if not exist) the following directory as _home directory_:
- **~/.sfpagent**, when the daemon is running with non-root user
- **/var/sfpagent**, when the daemon is running with root user


HTTP RESTful API
----------------
- GET
	- /pid      : save daemon's PID to a file (only requested from localhost)
	- /state    : return the current state
	- /model    : return the current model
	- /sfp      : return the SFP description of a module
	- /modules  : return a list of available modules
	- /agents   : return a list of agents database
	- /log      : return last 100 lines of log file

- POST	
	- /execute : receive an action's schema and execute it

- PUT
	- /model          : receive a new model and then save it
	- /model/cache    : receive a "cache" model and then save it
	- /modules        : save the module if parameter "module" is provided
	- /agents         : save the agents' list if parameter "agents" is provided
	- /bsig           : receive BSig model and receive it in cached directory
	- /bsig/satisfier : receive goal request from other agents and then start a satisfier thread in order to achieve it

- DELETE
	- /model            : delete existing model
	- /model/cache      : delete all cache models
	- /model/cache/name : delete cache model of agent "name"
	- /modules          : delete all modules from module database
	- /modules/name     : delete module "name" from module database
	- /agents           : delete all agents from agent database
	- /agents/name      : delete "name" from agent database
	- /bsig             : delete existing BSig model
