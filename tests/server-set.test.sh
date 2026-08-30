#!/bin/bash
# The server-set section of the instance.yml bootstrap: port allocation from
# each record's index, the validation that refuses a deployment rather than
# half-configuring one, per-server config and admin generation, and what
# happens on a cfn-hup re-run when a server is dropped from the parameter.
cd "$(dirname "$0")" || exit 1
HARNESS=build/server-set.sh
WORK=build/work
pass=0; fail=0

run() { # run <case> <servers-json> [telnetbase] [dashbase]
  local case=$1; shift
  rm -rf "$WORK/$case"; mkdir -p "$WORK/$case"
  bash "$HARNESS" "$WORK/$case" "$@" > "$WORK/$case.log" 2>&1
}
ok()      { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "  ok   $3"
            else fail=$((fail+1)); echo "  FAIL $3: expected [$2] got [$1]"; fi; }
has()     { if grep -qF -- "$2" "$WORK/$1" 2>/dev/null; then pass=$((pass+1)); echo "  ok   $3"
            else fail=$((fail+1)); echo "  FAIL $3: '$2' not in $1"; fi; }
lacks()   { if grep -qF -- "$2" "$WORK/$1" 2>/dev/null; then fail=$((fail+1)); echo "  FAIL $3: '$2' unexpectedly in $1"
            else pass=$((pass+1)); echo "  ok   $3"; fi; }
exists()  { if [ -e "$WORK/$1" ]; then pass=$((pass+1)); echo "  ok   $2"
            else fail=$((fail+1)); echo "  FAIL $2: $1 missing"; fi; }
absent()  { if [ -e "$WORK/$1" ]; then fail=$((fail+1)); echo "  FAIL $2: $1 still there"
            else pass=$((pass+1)); echo "  ok   $2"; fi; }
count()   { grep -cF -- "$2" "$WORK/$1" 2>/dev/null || true; }

echo "one server, everything inherited from the stack parameters"
run one '[{"Slug":"main"}]'; ok "$?" 0 "bootstrap succeeds"
ok "$(cat "$WORK/one/etc/7dtd/servers")" "main" "server list"
ok "$(head -1 "$WORK/one/etc/7dtd/main/serverconfig.xml")" '<?xml version="1.0"?>' "xml declaration"
ok "$(tail -1 "$WORK/one/etc/7dtd/main/serverconfig.xml")" '</ServerSettings>' "document closed"
ok "$(stat -f %Lp "$WORK/one/etc/7dtd/main/serverconfig.xml" 2>/dev/null || stat -c %a "$WORK/one/etc/7dtd/main/serverconfig.xml")" "640" "config is not world-readable"
has one/etc/7dtd/main/serverconfig.xml '<property name="ServerPort" value="26900"/>' "game port"
has one/etc/7dtd/main/serverconfig.xml '<property name="TelnetPort" value="8081"/>' "telnet port"
has one/etc/7dtd/main/serverconfig.xml '<property name="WebDashboardPort" value="8200"/>' "dashboard port"
has one/etc/7dtd/main/serverconfig.xml '<property name="ServerIP" value="203.0.113.10"/>' "elastic ip"
has one/etc/7dtd/main/serverconfig.xml '<property name="GameWorld" value="RWG"/>' "world inherited"
has one/etc/7dtd/main/server.env 'GAME_PORT=26900' "env carries the game port"
has one/etc/7dtd/main/server.env 'TELNET_PORT=8081' "env carries the console port"
exists one/opt/games/userdata/main/Saves/serveradmin.xml "admin file is in the Saves folder"

echo "three servers each get their own port block"
run three '[{"Slug":"main"},{"Slug":"pvp","ServerName":"PvP Realm","GameName":"PvPWorld","PlayerKillingMode":"3"},{"Slug":"creative","GameWorld":"Navezgane"}]'
ok "$?" 0 "bootstrap succeeds"
ok "$(tr '\n' ' ' < "$WORK/three/etc/7dtd/servers")" "main pvp creative " "list keeps parameter order"
has three/etc/7dtd/pvp/serverconfig.xml '<property name="ServerPort" value="26904"/>' "second game port is +4"
has three/etc/7dtd/creative/serverconfig.xml '<property name="ServerPort" value="26908"/>' "third game port is +8"
has three/etc/7dtd/pvp/serverconfig.xml '<property name="TelnetPort" value="8082"/>' "second console port is +1"
has three/etc/7dtd/creative/serverconfig.xml '<property name="WebDashboardPort" value="8202"/>' "third dashboard port is +2"
has three/etc/7dtd/pvp/serverconfig.xml '<property name="ServerName" value="PvP Realm"/>' "record overrides the name"
has three/etc/7dtd/pvp/serverconfig.xml '<property name="PlayerKillingMode" value="3"/>' "record overrides pvp mode"
has three/etc/7dtd/creative/serverconfig.xml '<property name="GameWorld" value="Navezgane"/>' "record overrides the world"
has three/etc/7dtd/main/serverconfig.xml '<property name="GameWorld" value="RWG"/>' "unset field falls back to the built-in default"
has three/etc/7dtd/creative/serverconfig.xml '<property name="ServerName" value="7 Days to Die on AWS"/>' "so does an unset name"
has three/etc/7dtd/main/serverconfig.xml '<property name="SandboxCode" value="AAAJABJACJADJARFBNC"/>' "and the sandbox preset"
has three/etc/7dtd/main/serverconfig.xml '<property name="WebDashboardEnabled" value="true"/>' "and the dashboard toggle"
has three/etc/7dtd/pvp/server.env 'SERVER_NAME=PvP\ Realm' "a name with spaces survives being sourced"

echo "refuses a deployment it cannot serve"
run twentyfive "$(python3 -c 'import json;print(json.dumps([{"Slug":"s%d"%i} for i in range(25)]))')"
ok "$?" 0 "25 servers fit the 26900-26999 window"
has twentyfive/etc/7dtd/s24/serverconfig.xml '<property name="ServerPort" value="26996"/>' "the last one lands on 26996-26999"
run overflow "$(python3 -c 'import json;print(json.dumps([{"Slug":"s%d"%i} for i in range(26)]))')"
ok "$?" 1 "a 26th server is refused"
has overflow.log "past the 26999 top of the range" "and the message says why"
absent overflow/etc/7dtd/servers "nothing is written on refusal"
run badslug '[{"Slug":"my server"}]'; ok "$?" 1 "a slug with a space is refused"
has badslug.log "must be 1-32 characters" "and the rule is stated"
run noslug '[{"GameName":"x"}]'; ok "$?" 1 "a record with no slug is refused"
run dupe '[{"Slug":"main"},{"Slug":"main"}]' 26907; ok "$?" 1 "a duplicate slug is refused"
has dupe.log "duplicate Slug" "and named"
run collide '[{"Slug":"a"},{"Slug":"b"}]' 26907 8200 8201; ok "$?" 1 "overlapping console/dashboard bases are refused"
has collide.log "port collision across servers" "and named"
run notarray '{"Slug":"main"}'; ok "$?" 1 "a bare object is refused"
run empty '[]'; ok "$?" 1 "an empty list is refused"
run garbage 'not json at all'; ok "$?" 1 "unparseable JSON is refused"

run dash '[{"Slug":"quiet","WebDashboardEnabled":"false","ServerVisibility":"0","ServerMaxPlayerCount":"4"}]'
ok "$?" 0 "bootstrap succeeds"
has dash/etc/7dtd/quiet/serverconfig.xml '<property name="WebDashboardEnabled" value="false"/>' "a record can turn its own dashboard off"
has dash/etc/7dtd/quiet/serverconfig.xml '<property name="ServerVisibility" value="0"/>' "and hide itself from the browser"
has dash/etc/7dtd/quiet/serverconfig.xml '<property name="ServerMaxPlayerCount" value="4"/>' "and set its own player cap"

run explicitempty '[{"Slug":"bare","ServerDescription":"","ServerWebsiteURL":"","AdminSteamIds":""}]'
ok "$?" 0 "bootstrap succeeds"
has explicitempty/etc/7dtd/bare/serverconfig.xml '<property name="ServerDescription" value=""/>' "an explicit empty value is kept, not filled in by the default"
ok "$(count explicitempty/opt/games/userdata/bare/Saves/serveradmin.xml '<user ')" "0" "and an explicitly empty admin list stays empty"
run nulled '[{"Slug":"bare","ServerDescription":null}]'
ok "$?" 0 "bootstrap succeeds"
has nulled/etc/7dtd/bare/serverconfig.xml '<property name="ServerDescription" value="A 7 Days to Die server, running on AWS"/>' "but a null field falls back to the default"

echo "per-server property overrides"
run overrides '[{"Slug":"lite","ServerPropertyOverrides":"MaxSpawnedZombies=16,LandClaimSize=71,SomeNewProperty=yes"}]'
ok "$?" 0 "bootstrap succeeds"
has overrides/etc/7dtd/lite/serverconfig.xml '<property name="MaxSpawnedZombies" value="16"/>' "replaces a property the template writes"
lacks overrides/etc/7dtd/lite/serverconfig.xml '<property name="MaxSpawnedZombies" value="64"/>' "and leaves no duplicate"
has overrides/etc/7dtd/lite/serverconfig.xml '<property name="LandClaimSize" value="71"/>' "handles more than one pair"
has overrides/etc/7dtd/lite/serverconfig.xml '<property name="SomeNewProperty" value="yes"/>' "appends a property it has never heard of"
ok "$(count overrides/etc/7dtd/lite/serverconfig.xml 'SomeNewProperty')" "1" "appends it exactly once"
ok "$(tail -1 "$WORK/overrides/etc/7dtd/lite/serverconfig.xml")" '</ServerSettings>' "an appended property lands inside the document"
run portoverride '[{"Slug":"a","ServerPropertyOverrides":"ServerPort=26950"}]'
ok "$?" 1 "an override that moves a port is refused"
has portoverride.log "Ports are allocated from the server's position" "and explains where ports come from"
run telnetoverride '[{"Slug":"a","ServerPropertyOverrides":"TelnetPort=9000"}]'
ok "$?" 1 "so is a console port override"

echo "admins are per server"
run admins '[{"Slug":"a","AdminSteamIds":"76561198000000001,76561198000000002"},{"Slug":"b","AdminPermissionLevel":"500"}]'
ok "$?" 0 "bootstrap succeeds"
ok "$(count admins/opt/games/userdata/a/Saves/serveradmin.xml '<user ')" "2" "both ids land, including the last"
has admins/opt/games/userdata/a/Saves/serveradmin.xml 'userid="76561198000000001" permission_level="0"' "at the default level"
ok "$(count admins/opt/games/userdata/b/Saves/serveradmin.xml '<user ')" "0" "a server with no ids has no admins"

echo "dropping a server from the parameter"
run drop '[{"Slug":"keep"},{"Slug":"drop"}]'
echo worldstate > "$WORK/drop/opt/games/userdata/drop/Saves/marker"
bash "$HARNESS" "$WORK/drop" '[{"Slug":"keep"}]' > "$WORK/drop2.log" 2>&1
ok "$?" 0 "the cfn-hup re-run succeeds"
ok "$(cat "$WORK/drop/etc/7dtd/servers")" "keep" "the list shrinks"
absent drop/etc/7dtd/drop "its config is removed"
has drop2.log "STUB systemctl disable --now 7dtd@drop.service" "its game unit is stopped"
has drop2.log "STUB systemctl disable --now 7dtd-login-notify@drop.service" "its login watcher is stopped"
exists drop/opt/games/userdata/drop/Saves/marker "but its world save is left alone"

echo "upgrading a host bootstrapped before the units were templated"
run stale '[{"Slug":"main"}]'
mkdir -p "$WORK/stale/etc/systemd/system"
touch "$WORK/stale/etc/systemd/system/7dtd.service" \
      "$WORK/stale/etc/systemd/system/7dtd-login-notify.service" \
      "$WORK/stale/etc/systemd/system/7dtd-stop-notify.service"
bash "$HARNESS" "$WORK/stale" '[{"Slug":"main"}]' > "$WORK/stale2.log" 2>&1
ok "$?" 0 "the re-run succeeds"
has stale2.log "STUB systemctl disable --now 7dtd.service" "the old game unit is stopped"
has stale2.log "STUB systemctl disable --now 7dtd-login-notify.service" "the old login watcher is stopped"
absent stale/etc/systemd/system/7dtd.service "and its unit file removed"
exists stale/etc/systemd/system/7dtd-stop-notify.service "stop-notify is left alone, so no false shutdown email"

echo "passwords"
run passwords '[{"Slug":"main"}]'
has passwords/etc/7dtd/main/serverconfig.xml '<property name="TelnetPassword" value="tOpS3cretC0nsole"/>' "the console password reaches the config"
lacks passwords.log 'tOpS3cretC0nsole' "but never the launch log"
has passwords/etc/7dtd/main/serverconfig.xml '<property name="ServerPassword" value=""/>' "the literal 'none' means an open server"
absent passwords/run/7dtd-defaults "the file holding both passwords is deleted"

echo
echo "server-set: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
