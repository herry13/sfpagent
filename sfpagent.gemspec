Gem::Specification.new do |s|
	s.name			= 'sfpagent'
	s.version		= '0.0.1'
	s.date			= '2013-07-03'
	s.summary		= 'SFP Agent'
	s.description	= 'A Ruby gem that provides a Ruby API to an SFP Agent.'
	s.authors		= ['Herry']
	s.email			= 'herry13@gmail.com'

	s.executables << 'sfpagent'
	s.files			= `git ls-files`.split("\n")

	s.require_paths = ['lib']

	s.homepage		= 'https://github.com/herry13/sfpagent'
	s.rubyforge_project = 'sfpagent'

	s.add_dependency 'sfp', '~> 0.3.0'
end	
