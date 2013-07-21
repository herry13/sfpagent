SFP Agent for Ruby
==================
- Author: Herry (herry13@gmail.com)
- Version: 0.1.1
- License: [BSD License](https://github.com/herry13/sfpagent/blob/master/LICENSE)

A Ruby script and API of an SFP agent. The agent could be accessed through HTTP RESTful API.

With this agent, you could manage a software component such as get the state, install, uninstall, update
its configuration, etc. Each configuration should be specified in [SFP language](https://github.com/herry13/sfp).
Every software component could have a set of methods which could be called through HTTP request.


Requirements
------------
- Ruby (>= 1.8.7)
- Rubygems
	- sfp (>= 0.3.0)
	- antlr3
	- json


To install
----------

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

In default, the agent will use (and created if not exist):
- directory **~/.sfpagent**, when the daemon is running with non-root user,
- directory **/var/sfpagent**, when the daemon is running with root user.


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


