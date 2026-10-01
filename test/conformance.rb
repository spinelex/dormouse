# Rack conformance for Dormouse: real requests over a socket, each response
# printed byte for byte. Run under CRuby and under Spinel; the two outputs
# must be the same (test/run.sh compares them).
require_relative "../lib/dormouse"

# A body that only answers #each, and says when it is closed.
class EachBody
  def initialize(parts, log) = (@parts = parts; @log = log)
  def each(&blk) = @parts.each(&blk)
  def close = @log << "closed"
end

class TestApp
  attr_reader :log

  def initialize = @log = []

  def call(env)
    case env["PATH_INFO"]
    when "/env"
      keys = %w[REQUEST_METHOD SCRIPT_NAME PATH_INFO QUERY_STRING SERVER_NAME SERVER_PORT
                SERVER_PROTOCOL REMOTE_ADDR CONTENT_TYPE CONTENT_LENGTH HTTP_HOST
                HTTP_X_CUSTOM REQUEST_URI rack.url_scheme]
      lines = keys.map { |k| "#{k}=#{env[k]}" }
      lines << "input=#{env["rack.input"].read.inspect}"
      lines << "errors=#{env["rack.errors"].respond_to?(:puts)}"
      lines << "hijack=#{env["rack.hijack?"]}"
      [200, { "content-type" => "text/plain" }, [lines.join("\n") + "\n"]]
    when "/echo"
      body = env["rack.input"].read
      [200, { "content-type" => "text/plain" }, ["#{env["REQUEST_METHOD"]} #{body.bytesize} #{body}"]]
    when "/each"
      [200, { "content-type" => "text/plain" }, EachBody.new(["one ", "two ", "three"], @log)]
    when "/each-length"
      [200, { "content-type" => "text/plain", "content-length" => "8" }, EachBody.new(["four", "five"], @log)]
    when "/stream"
      [200, { "content-type" => "text/plain" }, ->(stream) { stream.write("a"); stream << "b"; stream.write("c") }]
    when "/multi"
      [200, { "set-cookie" => ["a=1", "b=2"], "x-list" => "p\nq" }, ["ok"]]
    when "/nocontent"
      [204, {}, []]
    when "/raise"
      raise ArgumentError, "boom"
    when "/finished"
      env["rack.response_finished"] << ->(_env, _status, _headers, _error) { @log << "finished" }
      [200, {}, ["fin"]]
    when "/log"
      [200, {}, [@log.join(",")]]
    else
      [404, { "content-type" => "text/plain" }, ["not found: #{env["PATH_INFO"]}"]]
    end
  end
end

PORT = 19292

def exchange(raw)
  s = TCPSocket.new("127.0.0.1", PORT)
  s.write(raw)
  out = +""
  loop do
    chunk = s.readpartial(65536)
    out << chunk
  end
rescue EOFError
  out
ensure
  s.close if s && !s.closed?
end

def show(title, raw)
  puts "== #{title}"
  exchange(raw).split("\r\n", -1).each { |line| puts line.inspect }
end

app = TestApp.new
server = Dormouse::Server.new(app, port: PORT, max_header_bytes: 4096, max_body_bytes: 1024,
                              header_timeout: 2, keepalive_timeout: 2).listen
Thread.new { server.run }

show "env", "GET /env?a=1&b=2 HTTP/1.1\r\nHost: example.test:8080\r\nX-Custom: one\r\nX-Custom: two\r\nConnection: close\r\n\r\n"
show "post", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
show "chunked upload", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\nX-Trailer: t\r\n\r\n"
show "100 continue", "POST /echo HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc"
show "each body", "GET /each HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
show "each body with length", "GET /each-length HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
show "streaming body", "GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
show "multi-value headers", "GET /multi HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
show "head", "HEAD /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
show "204", "GET /nocontent HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
show "app raises", "GET /raise HTTP/1.1\r\nHost: x\r\n\r\n"
show "keep-alive and pipelining", "GET /echo?1 HTTP/1.1\r\nHost: x\r\n\r\nGET /missing HTTP/1.1\r\nHost: x\r\n\r\nGET /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
show "http/1.0 closes", "GET /echo HTTP/1.0\r\n\r\n"
show "http/1.0 keep-alive", "GET /echo HTTP/1.0\r\nConnection: keep-alive\r\n\r\nGET /echo HTTP/1.0\r\n\r\n"
show "bad request line", "NONSENSE\r\n\r\n"
show "headers too large", "GET / HTTP/1.1\r\nHost: x\r\nX-Big: #{"y" * 5000}\r\n\r\n"
show "bad content-length", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n"
show "length and chunked", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
show "unknown transfer-encoding", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n"
show "chunked body cut short", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab"
show "body too large", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 2000\r\n\r\n"
show "response finished", "GET /finished HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
show "close and finished log", "GET /log HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"

server.stop
puts "done"
