require "nokogiri"
require "pg"
require "vips"
puts "SMOKE_OK ruby=#{RUBY_VERSION} vips=#{Vips::LIBRARY_VERSION} (gem #{Vips::VERSION})"
