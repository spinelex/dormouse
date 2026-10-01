#!/bin/bash
# Run the conformance test under CRuby 4.0 and under Spinel; both must give
# test/conformance.expected. SPINEL and RUBY can point elsewhere.
cd "$(dirname "$0")/.."
RUBY=${RUBY:-$HOME/.rbenv/versions/4.0.1/bin/ruby}
SPINEL=${SPINEL:-$HOME/spinel/bin/spinel}
status=0
$RUBY test/conformance.rb > /tmp/dormouse_cruby.txt 2>/dev/null
diff -q test/conformance.expected /tmp/dormouse_cruby.txt >/dev/null && echo "cruby:  ok" || { echo "cruby:  DIFF"; status=1; }
if $SPINEL test/conformance.rb -o /tmp/dormouse_conformance >/tmp/dormouse_build.log 2>&1; then
  /tmp/dormouse_conformance > /tmp/dormouse_spinel.txt 2>/dev/null
  diff -q test/conformance.expected /tmp/dormouse_spinel.txt >/dev/null && echo "spinel: ok" || { echo "spinel: DIFF (diff test/conformance.expected /tmp/dormouse_spinel.txt)"; status=1; }
else
  echo "spinel: does not compile (see /tmp/dormouse_build.log)"; status=1
fi
# Rack::Lint: the same output from both
$RUBY test/lint_spinel.rb > /tmp/dormouse_lint_cruby.txt 2>/dev/null
if $SPINEL test/lint_spinel.rb -o /tmp/dormouse_lint >/tmp/dormouse_lint_build.log 2>&1; then
  /tmp/dormouse_lint > /tmp/dormouse_lint_spinel.txt 2>/dev/null
  if grep -q "^lint: ok" /tmp/dormouse_lint_cruby.txt && diff -q /tmp/dormouse_lint_cruby.txt /tmp/dormouse_lint_spinel.txt >/dev/null; then
    echo "lint:   ok"
  else
    echo "lint:   DIFF (diff /tmp/dormouse_lint_cruby.txt /tmp/dormouse_lint_spinel.txt)"; status=1
  fi
else
  echo "lint:   does not compile under Spinel (see /tmp/dormouse_lint_build.log)"; status=1
fi
exit $status
