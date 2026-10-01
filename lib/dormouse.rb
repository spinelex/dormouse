# Dormouse: a Rack 3 server in plain Ruby, written to be compiled by Spinel
# (and to run unchanged on CRuby, which is how its behaviour is checked).
#
# One green thread per connection. A connection serves requests until the
# client closes it, asks to close, or idles past the keep-alive timeout.
require "socket"
require "stringio"

module Dormouse
  REASONS = {
    100 => "Continue", 200 => "OK", 201 => "Created", 202 => "Accepted",
    204 => "No Content", 206 => "Partial Content", 301 => "Moved Permanently",
    302 => "Found", 303 => "See Other", 304 => "Not Modified",
    307 => "Temporary Redirect", 308 => "Permanent Redirect",
    400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
    404 => "Not Found", 405 => "Method Not Allowed", 408 => "Request Timeout",
    409 => "Conflict", 413 => "Content Too Large", 415 => "Unsupported Media Type",
    422 => "Unprocessable Content", 429 => "Too Many Requests",
    431 => "Request Header Fields Too Large", 500 => "Internal Server Error",
    501 => "Not Implemented", 502 => "Bad Gateway", 503 => "Service Unavailable"
  }

  # The CGI names of the common request headers, so a request doesn't build
  # them again.
  HEADER_KEYS = {}
  %w[Host User-Agent Accept Accept-Encoding Accept-Language Connection Cookie
     Referer Cache-Control Origin Authorization Upgrade-Insecure-Requests
     If-None-Match If-Modified-Since X-Forwarded-For X-Forwarded-Proto
     X-Requested-With Expect Transfer-Encoding].each do |name|
    key = "HTTP_" + name.upcase.tr("-", "_")
    HEADER_KEYS[name] = key
    HEADER_KEYS[name.downcase] = key
  end
  HEADER_KEYS["Content-Type"] = HEADER_KEYS["content-type"] = "CONTENT_TYPE"
  HEADER_KEYS["Content-Length"] = HEADER_KEYS["content-length"] = "CONTENT_LENGTH"

  # A request the server answers itself, before the app sees it.
  class Refusal < StandardError
    attr_reader :status

    def initialize(status, message)
      super(message)
      @status = status
    end
  end

  # What `body.call(stream)` writes to: the response, sent chunked.
  class Stream
    def initialize(sock)
      @sock = sock
      @closed = false
    end

    def write(data)
      s = data.to_s
      @sock.write(s.bytesize.to_s(16) + "\r\n" + s + "\r\n") unless s.empty?
      s.bytesize
    end

    def <<(data)
      write(data)
      self
    end

    def flush = self

    def close
      return if @closed
      @closed = true
      @sock.write("0\r\n\r\n")
    end

    def closed? = @closed
  end

  class Server
    attr_reader :host, :port

    def initialize(app, host: "127.0.0.1", port: 9292, max_header_bytes: 65536,
                   max_body_bytes: 16 * 1024 * 1024, keepalive_timeout: 30,
                   header_timeout: 10, access_log: false)
      @app = app
      @host = host
      @port = port
      @max_header_bytes = max_header_bytes
      @max_body_bytes = max_body_bytes
      @keepalive_timeout = keepalive_timeout
      @header_timeout = header_timeout
      @access_log = access_log
      @listener = nil
    end

    # Bind the listening socket. Separate from run, so a caller (a test) can
    # start serving in a thread and know the port is ready.
    def listen
      @listener = TCPServer.new(@host, @port)
      self
    end

    # Accept until the listener is closed (stop, or TERM / INT).
    def run
      listen unless @listener
      listener = @listener
      Signal.trap("TERM") { listener.close }
      Signal.trap("INT") { listener.close }
      loop do
        sock = listener.accept
        Thread.new(sock) { |s| serve(s) }
      end
    rescue IOError, SystemCallError
      nil
    end

    def stop
      @listener.close if @listener && !@listener.closed?
    end

    # Every request on one connection, until it ends.
    def serve(sock)
      peer = remote_addr(sock)
      buf = +""
      first = true
      loop do
        timeout = first ? @header_timeout : @keepalive_timeout
        first = false
        env = next_request(sock, buf, peer, timeout)
        break unless env
        break unless respond(sock, env)
      end
    rescue IOError, SystemCallError
      nil
    ensure
      sock.close unless sock.closed?
    end

    # The next request as an env, or nil when the connection should end
    # (end of stream, an idle timeout, or a request answered with a refusal).
    def next_request(sock, buf, peer, timeout)
      read_request(sock, buf, peer, timeout)
    rescue Refusal => e
      refuse(sock, e.status, e.message)
      nil
    end

    # Call the app and write its answer. Answers whether the connection
    # stays open.
    def respond(sock, env)
      keep = keep_alive?(env)
      status = 500
      headers = {}
      body = []
      begin
        status, headers, body = @app.call(env)
      rescue StandardError => e
        $stderr.puts("[dormouse] 500 #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]} -- #{e.class}: #{e.message}")
        status = 500
        headers = { "content-type" => "text/plain" }
        body = ["Internal Server Error\n"]
        keep = false
      end
      write_response(sock, env, status.to_i, headers, body, keep)
      run_finished(env)
      log(env, status) if @access_log
      keep
    end

    def keep_alive?(env)
      conn = env["HTTP_CONNECTION"]
      conn = conn ? conn.downcase : ""
      return false if conn.include?("close")
      return true if conn.include?("keep-alive")
      env["SERVER_PROTOCOL"] == "HTTP/1.1"
    end

    # ---- reading ----------------------------------------------------------

    # One request from buf, topped up from the socket, as a Rack env. nil at
    # end of stream or after an idle timeout. What follows the request stays
    # in buf for the next one (pipelining).
    def read_request(sock, buf, peer, timeout)
      head_end = buf.index("\r\n\r\n")
      until head_end
        raise Refusal.new(431, "Request Header Fields Too Large") if buf.bytesize > @max_header_bytes
        return nil unless fill(sock, buf, timeout)
        head_end = buf.index("\r\n\r\n")
      end
      raise Refusal.new(431, "Request Header Fields Too Large") if head_end > @max_header_bytes

      line_end = buf.index("\r\n")
      line = buf[0, line_end]
      parts = line.split(" ")
      raise Refusal.new(400, "Bad Request") unless parts.size == 3
      method = parts[0]
      target = parts[1]
      protocol = parts[2]
      raise Refusal.new(400, "Bad Request") unless protocol.start_with?("HTTP/1.")

      q = target.index("?")
      env = {
        "REQUEST_METHOD" => method,
        "SCRIPT_NAME" => "",
        "PATH_INFO" => q ? target[0, q] : target,
        "QUERY_STRING" => q ? target[q + 1, target.length - q - 1] : "",
        "SERVER_PROTOCOL" => protocol,
        "SERVER_NAME" => @host,
        "SERVER_PORT" => @port.to_s,
        "REMOTE_ADDR" => peer,
        "rack.url_scheme" => "http",
        "rack.errors" => $stderr,
        "rack.multithread" => true,
        "rack.multiprocess" => false,
        "rack.run_once" => false,
        "rack.hijack?" => false,
        "rack.response_finished" => []
      }
      env["REQUEST_URI"] = target

      pos = line_end + 2
      while pos < head_end
        eol = buf.index("\r\n", pos)
        colon = buf.index(":", pos)
        if colon && colon < eol
          name = buf[pos, colon - pos]
          vstart = colon + 1
          vstart += 1 while vstart < eol && buf[vstart] == " "
          key = HEADER_KEYS[name] || cgi_name(name)
          value = buf[vstart, eol - vstart]
          # repeated headers join with a comma, as a CGI env holds them
          env[key] = env[key] ? env[key] + ", " + value : value
        end
        pos = eol + 2
      end
      host_from_header(env)

      rest = head_end + 4
      buf.replace(buf[rest, buf.length - rest] || "")
      env["rack.input"] = StringIO.new(read_body(sock, buf, env))
      env
    end

    # SERVER_NAME and SERVER_PORT from the Host header, when there is one.
    def host_from_header(env)
      host = env["HTTP_HOST"]
      return unless host
      colon = host.rindex(":")
      if colon && !host.end_with?("]")
        env["SERVER_NAME"] = host[0, colon]
        env["SERVER_PORT"] = host[colon + 1, host.length - colon - 1]
      else
        env["SERVER_NAME"] = host
        env["SERVER_PORT"] = "80"
      end
    end

    def cgi_name(name)
      key = name.upcase.tr("-", "_")
      key == "CONTENT_TYPE" || key == "CONTENT_LENGTH" ? key : "HTTP_" + key
    end

    # The request body, by Content-Length or chunked. Sends 100 Continue
    # first when the client waits for it.
    def read_body(sock, buf, env)
      chunked = (env["HTTP_TRANSFER_ENCODING"] || "").downcase.include?("chunked")
      len = (env["CONTENT_LENGTH"] || "0").to_i
      return "" unless chunked || len > 0
      raise Refusal.new(413, "Content Too Large") if len > @max_body_bytes

      if (env["HTTP_EXPECT"] || "").downcase == "100-continue"
        sock.write("HTTP/1.1 100 Continue\r\n\r\n")
      end
      if chunked
        env.delete("HTTP_TRANSFER_ENCODING")
        body = read_chunked(sock, buf)
        env["CONTENT_LENGTH"] = body.bytesize.to_s
        return body
      end
      while buf.bytesize < len
        raise Refusal.new(400, "Bad Request") unless fill(sock, buf, @header_timeout)
      end
      body = buf[0, len]
      buf.replace(buf[len, buf.length - len] || "")
      body
    end

    def read_chunked(sock, buf)
      body = +""
      loop do
        line_end = buf.index("\r\n")
        until line_end
          raise Refusal.new(400, "Bad Request") unless fill(sock, buf, @header_timeout)
          line_end = buf.index("\r\n")
        end
        size_text = buf[0, line_end]
        semi = size_text.index(";")
        size_text = size_text[0, semi] if semi
        size = size_text.strip.to_i(16)
        if size == 0
          # the last chunk, then optional trailers up to an empty line
          trailer_end = buf.index("\r\n\r\n", line_end)
          until trailer_end
            raise Refusal.new(400, "Bad Request") unless fill(sock, buf, @header_timeout)
            trailer_end = buf.index("\r\n\r\n", line_end)
          end
          buf.replace(buf[trailer_end + 4, buf.length - trailer_end - 4] || "")
          return body
        end
        raise Refusal.new(413, "Content Too Large") if body.bytesize + size > @max_body_bytes
        while buf.bytesize < line_end + 2 + size + 2
          raise Refusal.new(400, "Bad Request") unless fill(sock, buf, @header_timeout)
        end
        body << buf[line_end + 2, size]
        rest = line_end + 2 + size + 2
        buf.replace(buf[rest, buf.length - rest] || "")
      end
    end

    # Top up buf from the socket. false at end of stream or on a timeout.
    def fill(sock, buf, timeout)
      return false unless sock.wait_readable(timeout)
      chunk = sock.readpartial(16384)
      buf << chunk
      true
    rescue EOFError
      false
    end

    def remote_addr(sock)
      addr = sock.peeraddr
      addr[3].to_s
    rescue StandardError
      ""
    end

    # ---- writing ----------------------------------------------------------

    def write_response(sock, env, status, headers, body, keep)
      head = +"HTTP/1.1 #{status} #{REASONS[status] || "Unknown"}\r\n"
      has_length = false
      headers.each do |name, value|
        lname = name.downcase
        has_length = true if lname == "content-length"
        next if lname == "connection" || lname == "transfer-encoding"
        if value.is_a?(Array)
          value.each { |v| head << name << ": " << v.to_s << "\r\n" }
        else
          value.to_s.split("\n").each { |v| head << name << ": " << v << "\r\n" }
        end
      end
      no_body = env["REQUEST_METHOD"] == "HEAD" || status == 204 || status == 304 || status < 200

      if body.respond_to?(:to_ary)
        parts = body.to_ary
        unless has_length || status == 204 || status == 304 || status < 200
          head << "content-length: " << parts.sum(0) { |p| p.to_s.bytesize }.to_s << "\r\n"
        end
        head << (keep ? "connection: keep-alive\r\n\r\n" : "connection: close\r\n\r\n")
        parts.each { |p| head << p.to_s } unless no_body
        sock.write(head)
      elsif body.respond_to?(:each)
        if no_body
          head << (keep ? "connection: keep-alive\r\n\r\n" : "connection: close\r\n\r\n")
          sock.write(head)
        elsif has_length
          head << (keep ? "connection: keep-alive\r\n\r\n" : "connection: close\r\n\r\n")
          sock.write(head)
          body.each { |p| sock.write(p.to_s) }
        else
          head << "transfer-encoding: chunked\r\n"
          head << (keep ? "connection: keep-alive\r\n\r\n" : "connection: close\r\n\r\n")
          sock.write(head)
          stream = Stream.new(sock)
          body.each { |p| stream.write(p) }
          stream.close
        end
      else
        # a streaming body: body.call(stream)
        head << "transfer-encoding: chunked\r\n" unless has_length || no_body
        head << (keep ? "connection: keep-alive\r\n\r\n" : "connection: close\r\n\r\n")
        sock.write(head)
        unless no_body
          stream = Stream.new(sock)
          body.call(stream)
          stream.close
        end
      end
    ensure
      body.close if body.respond_to?(:close)
    end

    # A request the app never saw: answer and close.
    def refuse(sock, status, message)
      text = message + "\n"
      sock.write("HTTP/1.1 #{status} #{REASONS[status] || "Unknown"}\r\n" \
                 "content-type: text/plain\r\ncontent-length: #{text.bytesize}\r\n" \
                 "connection: close\r\n\r\n" + text)
    rescue IOError, SystemCallError
      nil
    end

    def run_finished(env)
      callbacks = env["rack.response_finished"]
      callbacks.each { |cb| cb.call(env, nil, nil, nil) } if callbacks
    end

    def log(env, status)
      $stdout.puts("#{env["REMOTE_ADDR"]} \"#{env["REQUEST_METHOD"]} #{env["REQUEST_URI"]} #{env["SERVER_PROTOCOL"]}\" #{status}")
    end
  end
end
