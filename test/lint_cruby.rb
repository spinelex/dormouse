# Dormouse under Rack::Lint (CRuby only): every request goes through Lint,
# which raises Rack::Lint::LintError for anything outside the Rack 3 SPEC.
require "rack"
require "rack/lint"
require_relative "../lib/dormouse"

APP = lambda do |env|
  case env["PATH_INFO"]
  when "/echo"
    body = env["rack.input"].read
    [200, { "content-type" => "text/plain" }, [body]]
  when "/each"
    [200, { "content-type" => "text/plain" }, Enumerator.new { |y| y << "a"; y << "b" }]
  when "/stream"
    [200, {}, ->(s) { s.write("x"); s.close }]
  when "/head"
    [204, {}, []]
  else
    env["rack.errors"].puts("seen #{env["PATH_INFO"]}")
    env["rack.response_finished"] << ->(*) {}
    [200, { "content-type" => "text/plain", "set-cookie" => ["a=1", "b=2"] }, ["ok"]]
  end
end

errors = []
app = lambda do |env|
  Rack::Lint.new(APP).call(env)
rescue Rack::Lint::LintError => e
  errors << "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}: #{e.message}"
  [500, {}, []]
end
# Lint also checks the body side when the server iterates/closes it: wrap so
# errors there are caught too.
port = 19393
server = Dormouse::Server.new(app, port: port).listen
Thread.new { server.run }

def req(port, raw)
  s = TCPSocket.new("127.0.0.1", port)
  s.write(raw)
  out = +""
  loop { out << s.readpartial(65536) }
rescue EOFError
  out
ensure
  s&.close
end

req(port, "GET /?q=1 HTTP/1.1\r\nHost: example.test:8080\r\nConnection: close\r\n\r\n")
req(port, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nhello")
req(port, "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
req(port, "GET /each HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
req(port, "GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
req(port, "HEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
req(port, "GET /head HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
req(port, "GET / HTTP/1.0\r\n\r\n")
req(port, "OPTIONS * HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
server.stop
puts errors.empty? ? "lint: ok" : errors
