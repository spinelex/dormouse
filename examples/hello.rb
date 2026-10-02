# The smallest Dormouse app. Compile and run:
#   spinel examples/hello.rb -o hello && ./hello
# or run it on CRuby:
#   ruby examples/hello.rb
require_relative "../lib/dormouse"

class Hello
  def call(env)
    [200, { "content-type" => "text/plain" }, ["Hello from #{env["PATH_INFO"]}\n"]]
  end
end

server = Dormouse::Server.new(Hello.new, port: 9292, access_log: true)
puts "Dormouse listening on http://#{server.host}:#{server.port}"
server.run
