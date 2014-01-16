Gem::Specification.new do |s|
	s.name			= 'sfpagent'
	s.version		= File.read(File.dirname(__FILE__) + '/VERSION').strip
	s.date			= File.mtime(File.dirname(__FILE__) + '/VERSION').strftime("%Y-%m-%d")
	s.summary		= 'SFP Agent'
	s.description	= 'A Ruby implementation of SFP agent.'
	s.authors		= ['Herry']
	s.email			= 'herry13@gmail.com'

	s.executables   << 'sfpagent'
	s.files			= `git ls-files`.split("\n").select { |n| !(n =~ /^(modules|test)\/.*/) }

	s.require_paths = ['lib']
	s.license       = 'BSD'

	s.homepage		    = 'https://github.com/herry13/sfpagent'
	s.rubyforge_project = 'sfpagent'

	s.add_dependency 'sfp', '>= 0.3.17'
	s.add_dependency 'net-ssh'

	s.add_development_dependency 'rake'
end	
