#!/bin/bash
# The supervision scripts, driven against a stubbed telnet console. What
# changes with more than one server on a host is the arithmetic of "empty" and
# the cost of replacing the instance, so that is what these cover: the host
# only scales to zero when every world is empty, and a wedged world is
# restarted on its own before the whole host is handed to the ASG.
cd "$(dirname "$0")" || exit 1
export ROOT="$PWD/build/sup"
pass=0; fail=0

ok() { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "  ok   $3"
       else fail=$((fail+1)); echo "  FAIL $3: expected [$2] got [$1]"; fi; }
calls() { local n; n=$(grep -c -- "$1" "$ROOT/calls" 2>/dev/null); echo "${n:-0}"; }
present() { [ -e "$1" ] && echo yes || echo no; }

setup() { # setup <slug>:<players> ...   players "-" = console unreachable
  rm -rf "$ROOT"; mkdir -p "$ROOT/etc/7dtd" "$ROOT/bin" "$ROOT/run"
  cp build/bin/* "$ROOT/bin/"
  : > "$ROOT/etc/7dtd/servers"; : > "$ROOT/calls"
  local port=8081
  for spec in "$@"; do
    local slug=${spec%%:*} n=${spec#*:}
    mkdir -p "$ROOT/etc/7dtd/$slug"
    { echo "SLUG=$slug"; echo "GAME_PORT=269$port"; echo "TELNET_PORT=$port"
      printf 'SERVER_NAME=%q\n' "World $slug"; } > "$ROOT/etc/7dtd/$slug/server.env"
    echo "$slug" >> "$ROOT/etc/7dtd/servers"
    echo "$n" > "$ROOT/players.$port"
    port=$((port+1))
  done
  # The console, SNS, IMDS, the ASG API and systemd, all reduced to a log line.
  cat > "$ROOT/bin/7dtd-listplayers" <<'STUB'
#!/bin/bash
n=$(cat "$ROOT/players.$1")
[ "$n" = "-" ] && exit 1
echo "Total of $n in the game"
STUB
  cat > "$ROOT/bin/7dtd-notify" <<'STUB'
#!/bin/bash
echo "NOTIFY|$1|$3" >> "$ROOT/calls"
STUB
  cat > "$ROOT/bin/7dtd-backup" <<'STUB'
#!/bin/bash
echo "BACKUP" >> "$ROOT/calls"
STUB
  cat > "$ROOT/bin/aws" <<'STUB'
#!/bin/bash
echo "AWS|$*" >> "$ROOT/calls"
STUB
  cat > "$ROOT/bin/curl" <<'STUB'
#!/bin/bash
echo i-0123456789abcdef0
STUB
  cat > "$ROOT/bin/systemctl" <<'STUB'
#!/bin/bash
echo "SYSTEMCTL|$*" >> "$ROOT/calls"
STUB
  chmod +x "$ROOT/bin"/*
  export PATH="$ROOT/bin:$PATH"
}
idle()    { bash "$ROOT/bin/7dtd-idle-check"    >/dev/null 2>&1; }
health()  { bash "$ROOT/bin/7dtd-health-check"  >/dev/null 2>&1; }
refresh() { bash "$ROOT/bin/7dtd-daily-refresh" >/dev/null 2>&1; }
expire()  { echo 1 > "$ROOT/run/7dtd-idle/empty_since"; }

echo "idle shutdown"
setup a:0 b:0
idle
ok "$(present "$ROOT/run/7dtd-idle/empty_since")" "yes" "every world empty starts the grace clock"
ok "$(calls 'AWS|autoscaling')" "0" "but nothing happens inside the window"
expire; idle
ok "$(calls 'terminate-instance-in-auto-scaling-group')" "1" "past the window it terminates the instance"
ok "$(calls 'should-decrement-desired-capacity')" "1" "and decrements desired capacity so the group stays empty"
ok "$(grep -c 'no players on any server' "$ROOT/run/7dtd-notify/stop_reason")" "1" "leaving the reason for the shutdown email"

setup a:0 b:2
mkdir -p "$ROOT/run/7dtd-idle"; expire
idle
ok "$(present "$ROOT/run/7dtd-idle/empty_since")" "no" "a player on any one world clears the clock"
ok "$(calls 'AWS|autoscaling')" "0" "and one busy world keeps the whole host up"

setup a:0 b:-
mkdir -p "$ROOT/run/7dtd-idle"; expire
idle
ok "$(present "$ROOT/run/7dtd-idle/empty_since")" "yes" "one unreachable console leaves the clock untouched"
ok "$(calls 'AWS|autoscaling')" "0" "and never scales down on a console blip"

echo "self-heal (threshold 3)"
setup a:0 b:0
health
ok "$(calls 'NOTIFY|7DTD World')" "2" "each world emails its own server-is-up"
health
ok "$(calls 'NOTIFY|7DTD World')" "2" "once per boot, not once per check"

echo "-" > "$ROOT/players.8081"; : > "$ROOT/calls"
health; health
ok "$(calls 'SYSTEMCTL|restart')" "0" "below the threshold nothing is done"
health
ok "$(calls 'SYSTEMCTL|restart 7dtd@a.service')" "1" "at the threshold only that world is restarted"
ok "$(calls 'set-instance-health')" "0" "the other worlds' players are not evicted"
health; health; health
ok "$(calls 'set-instance-health.*Unhealthy')" "1" "still silent after its restart, the host is handed to the ASG"
ok "$(grep -c 'did not recover from a restart' "$ROOT/run/7dtd-notify/stop_reason")" "1" "with the reason recorded"

setup a:0 b:0
echo "-" > "$ROOT/players.8081"
health; health; health; health; health; health; health
ok "$(calls 'SYSTEMCTL|restart')" "0" "a world that never came up is never restarted"
ok "$(calls 'set-instance-health')" "0" "so a slow first boot or world-gen survives"

setup a:0 b:0
health
echo "-" > "$ROOT/players.8081"
health; health; health
echo "0" > "$ROOT/players.8081"
health
ok "$(cat "$ROOT/run/7dtd-health/a/fails")" "0" "recovery clears the fail count"
ok "$(present "$ROOT/run/7dtd-health/a/restarted")" "no" "and re-arms the restart escalation"

echo "daily refresh"
setup a:0 b:0
refresh
ok "$(calls BACKUP)" "1" "every world empty: archive first"
ok "$(calls 'terminate-instance-in-auto-scaling-group')" "1" "then replace the instance"
ok "$(calls 'should-decrement')" "0" "keeping desired capacity so the ASG relaunches"
setup a:0 b:1
refresh
ok "$(calls 'AWS|autoscaling')" "0" "a player on any world defers the refresh"
setup a:- b:0
refresh
ok "$(calls 'AWS|autoscaling')" "0" "an unreachable console is left to the health check"

echo
echo "supervision: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
