module Sfp
	def self.to_ruby(object)
		object = Sfp::Helper.deep_clone(object)
		object.accept(Sfp::Helper::Sfp2Ruby)
		object
	end
end

module Sfp::Helper
	Sfp2Ruby = Object.new
	def Sfp2Ruby.visit(name, value, parent)
		if name[0] == '_'
			parent.delete(name)
		elsif value.is_a?(Hash)
			case value['_context']
			when 'null'
				parent[name] = nil
			when 'any_value', 'constraint', 'procedure'
				parent.delete(name)
			when 'set'
				parent[name] = value['_values']
			end
		end
		true
	end
end

module Sfp::Helper::Net
	def post_data(address, port, path, data, open_timeout=5, read_timeout=1800)
		uri = create_uri(address, port, path)
		req = Net::HTTP::Post.new(uri.path)
		req.set_form_data(data)
		http_request(uri, req, open_timeout, read_timeout)
	end

	def put_data(address, port, path, data, open_timeout=5, read_timeout=1800)
		uri = create_uri(address, port, path)
		req = Net::HTTP::Put.new(uri.path)
		req.set_form_data(data)
		http_request(uri, req, open_timeout, read_timeout)
	end

	def get_data(address, port, path, open_timeout=5, read_timeout=1800)
		uri = create_uri(address, port, path)
		req = Net::HTTP::Get.new(uri.path)
		http_request(uri, req, open_timeout, read_timeout)
	end

	def delete_data(address, port, path, open_timeout=5, read_timeout=1800)
		uri = create_uri(address, port, path)
		req = Net::HTTP::Delete.new(uri.path)
		http_request(uri, req, open_timeout, read_timeout)
	end

	protected
	def create_uri(address, port, path)
		address = address.to_s.strip
		port = port.to_s.strip
		path = path.to_s.strip
		raise Exception, "Invalid parameters [address:#{address},port:#{port},path:#{path}]" if
			address.length <= 0 or port.length <= 0 or path.length <= 0
		path.sub!(/^\/+/, '')
		URI.parse("http://#{address}:#{port}/#{path}")
	end

	def use_http_proxy?(uri)
		parts = uri.host.split('.')
		if parts[0] == '10' or
		   (parts[0] == '172' and parts[1] == '16') or
		   (parts[0] == '192' and parts[1] == '168')
			false
		else
			ENV['no_proxy'].to_s.split(',').each { |pattern|
				pattern.chop! if pattern[-1] == '*'
				return false if uri.host[0,pattern.length] == pattern
			}
			true
		end
	end

	def http_request(uri, request, open_timeout=5, read_timeout=1800)
		if ENV['http_proxy'].to_s.strip != '' and use_http_proxy?(uri)
			proxy = URI.parse(ENV['http_proxy'])
			http = Net::HTTP::Proxy(proxy.host, proxy.port).new(uri.host, uri.port)
		else
			http = Net::HTTP.new(uri.host, uri.port)
		end
		http.open_timeout = open_timeout
		http.read_timeout = read_timeout
		http.start
		http.request(request) { |res| return [res.code, res.body] }
	end	
end

class Sfp::Helper::SchemaCollector
	attr_reader :schemata
	def initialize
		@schemata = []
	end
		
	def visit(name, value, parent)
		if value.is_a?(Hash) and value.has_key?('_classes')
			value['_classes'].each { |s| @schemata << s }
		end
		true
	end
end

class Sfp::Helper::CloudFinder
	CloudSchema = '$.Cloud'
	attr_accessor :clouds

	def reset
		@clouds = []
		self
	end

	def visit(name, value, parent)
		if value.is_a?(Hash)
			if value['_context'] == 'object'
				@clouds << parent.ref.push(name) if value.has_key?('_classes') and value['_classes'].index(CloudSchema)
				return true
			end
		end
		false
	end
end
