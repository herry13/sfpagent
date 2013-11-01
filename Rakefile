def name
	@name ||= Dir['*.gemspec'].first.split('.').first
end

def version
	File.read('VERSION').strip
end

def date
	Date.today.to_s
end

def test_script
	File.dirname(__FILE__) + '/bin/test'
end

task :default => :test

namespace :test do
	sh(test_script)
end
