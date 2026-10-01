# The two pieces of Rack::Utils that Rack::Lint reads, so lint.rb can be
# compiled without the rest of rack/utils.
require "uri"

module Rack
  module Utils
    URI_PARSER = defined?(::URI::RFC2396_PARSER) ? ::URI::RFC2396_PARSER : ::URI::DEFAULT_PARSER
    STATUS_WITH_NO_ENTITY_BODY = { 204 => true, 304 => true }.merge((100..199).to_h { |s| [s, true] })
  end
end
