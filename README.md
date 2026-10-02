<p align="center">
  <img src="logo.svg" alt="Dormouse, asleep on a red cushion" width="200">
</p>

# Dormouse

Dormouse is a Rack 3 web server written in plain Ruby so that
[Spinel](https://github.com/matz/spinel) can compile it to a single
native binary. The same source also runs on CRuby, and the tests use
CRuby to check what Spinel builds.

It is one file, `lib/dormouse.rb`, with no gems. Each connection gets
its own green thread.

> **Status: early.** Dormouse serves Rack 3 apps that Spinel can
> compile, and passes an unmodified `Rack::Lint`. It cannot run Rails
> yet; see [Not yet](#not-yet).

## Quick start

```ruby
# examples/hello.rb
require_relative "../lib/dormouse"

class Hello
  def call(env)
    [200, { "content-type" => "text/plain" }, ["Hello from #{env["PATH_INFO"]}\n"]]
  end
end

Dormouse::Server.new(Hello.new, port: 9292, access_log: true).run
```

```sh
spinel examples/hello.rb -o hello   # compile
./hello                             # serve on http://127.0.0.1:9292
curl localhost:9292/mouse           # Hello from /mouse
```

You can also run it on CRuby with `ruby examples/hello.rb`.

`TERM` or `INT` stops accepting new connections and lets the requests in
flight finish. A second `TERM` or `INT` exits at once.

## Options

```ruby
Dormouse::Server.new(app,
  host: "127.0.0.1",
  port: 9292,
  max_header_bytes: 65536,           # larger headers get a 431
  max_body_bytes: 16 * 1024 * 1024,  # larger bodies get a 413
  keepalive_timeout: 30,             # seconds an idle connection is kept open
  header_timeout: 10,                # seconds to wait for the first request
  access_log: false)                 # one line per request on stdout
```

Call `listen` before `run` if you need the port bound first, for
example to start the server in a thread inside a test.

## What works

- **HTTP/1.1:**
  - keep-alive and `Connection: close`
  - `HEAD`, and no body for 1xx, 204 and 304 responses
  - `Expect: 100-continue`
  - chunked request bodies
- **Response bodies:** it answers `content-length` itself when it knows
  the length, and uses chunked encoding otherwise. It supports:
  - Arrays and anything with `#each`, closing the body afterwards;
  - `#to_ary`;
  - streaming bodies (`body.call(stream)`).
- **Rack 3 env:**
  - the CGI variables;
  - `rack.input`, a binary `StringIO`;
  - `rack.errors`;
  - `rack.response_finished`;
  - `rack.hijack?` is `false`.
- **Refused before the app sees the request:**
  - malformed request lines get a 400;
  - an invalid `Content-Length`, or one sent together with
    `Transfer-Encoding`, gets a 400;
  - a transfer coding other than chunked gets a 400;
  - headers and bodies over the limits get a 431 or 413;
  - a connection that stays silent past its timeout is closed.
- **Errors:** an exception in the app becomes a 500, with one line on
  `$stderr`.

## Testing

```sh
test/run.sh
```

The script runs three checks. Each one prints `ok`, or tells you where
to find the diff.

| check  | what it does |
|--------|--------------|
| cruby  | `test/conformance.rb` on CRuby matches `test/conformance.expected` |
| spinel | the same test compiled by Spinel gives the same output |
| lint   | every request also goes through `Rack::Lint` (rack 3.2.7, vendored in `test/rack/`, unchanged). CRuby and Spinel must both pass and print the same responses |

`test/conformance.rb` starts the server, sends raw requests over a real
socket, and prints every response byte for byte.

The script expects CRuby 4.0 and a Spinel build. You can point it at
others:

```sh
RUBY=~/.rbenv/versions/4.0.1/bin/ruby SPINEL=~/spinel/bin/spinel test/run.sh
```

Use a recent Spinel `master`. Earlier builds miss fixes that Dormouse
needs.

To lint on CRuby with the rack gem installed, use `ruby test/lint_cruby.rb`.

## Not yet

- **Rack's own `Rack::Headers` and `Rack::QueryParser::Params`:** these
  subclass `Hash`, which Spinel is learning to compile. That work is in
  matz/spinel#7088 and matz/spinel#7094. Until it lands,
  `Rack::Request`, `Rack::Response` and `Rack::Files` don't compile.
- **Static files and `sendfile`**
- **`rack.hijack` and WebSockets**
- **Rails:** this is the end goal, through
  [roundhouse](https://github.com/rubys/roundhouse).
- **TLS:** for now, put a proxy in front.

Dormouse has driven a number of fixes in Spinel itself. When something
fails to compile, the fix usually goes into Spinel rather than a
workaround here.

## The name

A dormouse sleeps most of its life. This server spends its time asleep
in `IO.select` until someone knocks.
