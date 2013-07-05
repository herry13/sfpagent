#!/usr/bin/env ruby

require 'rubygems'
require 'openssl'
 
key = OpenSSL::PKey::RSA.new(1024)
public_key = key.public_key
 
subject = "/C=BE/O=Test/OU=Test/CN=Test"
 
cert = OpenSSL::X509::Certificate.new
cert.subject = cert.issuer = OpenSSL::X509::Name.parse(subject)
cert.not_before = Time.now
cert.not_after = Time.now + 365 * 24 * 60 * 60
cert.public_key = public_key
cert.serial = 0x0
cert.version = 2
 
ef = OpenSSL::X509::ExtensionFactory.new
ef.subject_certificate = cert
ef.issuer_certificate = cert
cert.extensions = [
  ef.create_extension("basicConstraints","CA:TRUE", true),
  ef.create_extension("subjectKeyIdentifier", "hash"),
  # ef.create_extension("keyUsage", "cRLSign,keyCertSign", true),
]
cert.add_extension ef.create_extension("authorityKeyIdentifier",
                                       "keyid:always,issuer:always")
 
cert.sign key, OpenSSL::Digest::SHA1.new

if ARGV.length < 3
	puts cert.to_pem
	puts key.to_pem
	puts public_key.to_pem
else
	File.open(ARGV[0], 'w') { |f| f.write(cert.to_pem) }
	File.open(ARGV[1], 'w') { |f| f.write(key.to_pem) }
	File.open(ARGV[2], 'w') { |f| f.write(public_key.to_pem) }
end
