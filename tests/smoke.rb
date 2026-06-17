require "nokogiri"
require "pg"
require "vips"
puts "SMOKE_OK ruby=#{RUBY_VERSION} vips=#{Vips::VERSION_STRING rescue 'n/a'}"
