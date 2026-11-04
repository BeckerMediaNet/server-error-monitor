#!/bin/bash
# test/inner.sh — runs inside the container test/run.sh starts: this checkout at /src (read-only), copied to
# /opt/server-error-monitor. Fake Slack on 127.0.0.1:8099 (test/fake_slack.py) records every post.
pass=0; fail=0
ok() { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: no \"$3\""; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected \"$3\""; else ok "$1"; fi; }
python3 /t/fake_slack.py & sleep 1
D=/opt/server-error-monitor; mkdir -p $D; cp -r /src/. $D/; rm -rf $D/.git $D/state $D/logs $D/.env
mkdir -p /var/log/nginx; L=/var/log/nginx/site_access.log; : > $L
cat > $D/.env <<E2
SLACK_WEBHOOK_URL=http://127.0.0.1:8099/hook
SITE_LABEL="test box"
ACCESS_LOGS="/var/log/nginx/*access*log"
DOCKER_CONTAINERS=
CHECK_KERNEL=false
E2
C="$D/bin/check-server-errors.sh --env $D/.env"
TS='[31/Oct/2026:10:00:00 +0000]'
v() { printf '%s %s - - %s "%s %s HTTP/1.1" %s %s "%s" "%s"\n' "$1" "$2" "$TS" "$3" "$4" "$5" "$6" "$7" "$8" >> $L; }   # host client method path status bytes referer agent
PH='Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15'
slack() { cat /tmp/slack.log 2>/dev/null; }
echo "-- baseline run"; $C; : > /tmp/slack.log
echo "-- refused form POSTs: a visitor's, not a bot's"
v learn.test 203.0.113.5 POST /wp-admin/admin-ajax.php 403 162 "https://learn.test/apply/" "$PH"
v page.test 203.0.113.6 POST /request-info/ 403 199 "https://page.test/request-info/" "$PH"
v gf.test 203.0.113.7 POST "/wp-json/gf/v2/forms/3/submissions" 403 199 "https://gf.test/apply/" "$PH"
v bots.test 198.51.100.1 POST /wp-admin/admin-ajax.php 403 22349 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/125.0.0.0"
v bots.test 198.51.100.2 POST /xmlrpc.php 403 199 "https://bots.test/" "$PH"
v bots.test 198.51.100.3 POST /wp-login.php 403 199 "https://bots.test/wp-login.php" "$PH"
v bots.test 198.51.100.4 POST /wp-admin/admin-ajax.php 403 199 "https://bots.test/" "Mozilla/5.0 (compatible; l9scan/2.0; +https://leakix.net)"
v nonce.test 203.0.113.8 POST /wp-admin/admin-ajax.php 403 2 "https://nonce.test/" "$PH"
$C; s=$(slack)
has "F1: admin-ajax POST with Referer refused: alert" "$s" "Form POSTs refused (403) on learn.test"
has "F2: POST to a page with Referer refused: alert" "$s" "Form POSTs refused (403) on page.test"
has "F3: Gravity Forms REST submission refused: alert" "$s" "Form POSTs refused (403) on gf.test"
lacks "F4: bot POSTs (no Referer, xmlrpc, wp-login, self-named agent): no alert" "$s" "bots.test"
lacks "F5: WordPress 2-byte reply (stale nonce): no alert" "$s" "nonce.test"
has "F6: the alert says what it means" "$s" "visitors cannot submit the form"
has "F6: ... and explains it" "$s" "those submissions did not go through"
: > /tmp/slack.log
echo "-- cooldown and recovery"
v learn.test 203.0.113.5 POST /wp-admin/admin-ajax.php 403 162 "https://learn.test/apply/" "$PH"
$C; lacks "F7: still refused next run: no repeat within the cooldown" "$(slack)" "learn.test"
$C; lacks "F8: one clean run: no recovery yet (RECOVERY_RUNS=2)" "$(slack)" "Form POSTs on learn.test are no longer refused"
$C; has "F8: two clean runs: recovery" "$(slack)" "Form POSTs on learn.test are no longer refused"
: > /tmp/slack.log
echo "-- 403s: visitors refused, not scanner probes"
for i in $(seq 60); do v spike.test 192.0.2.$(( i % 5 + 1 )) GET /programs/ 403 199 "-" "$PH"; done
for i in $(seq 60); do v spike.test 192.0.2.$(( i % 5 + 101 )) GET /.env 403 199 "-" "$PH"; done
for i in $(seq 60); do v spike.test 192.0.2.$(( i % 5 + 101 )) GET /wp-login.php 403 199 "-" "$PH"; done
$C; s=$(slack)
has "S1: 60 page 403s from 5 clients: the 403 alert, probes not counted" "$s" "*HTTP 403 Forbidden*: 60 to real visitors in"
has "S1: ... names the clients" "$s" "from 5 clients"
has "S1: ... lists the paths" "$s" "Top paths: \`/programs/\` (60)"
lacks "S1: ... not the probe paths" "$s" "/wp-login.php"
: > /tmp/slack.log; $C; $C; : > /tmp/slack.log
for i in $(seq 60); do v onebot.test 192.0.2.9 GET /programs/ 403 199 "-" "$PH"; done
$C; lacks "S2: 60 page 403s from one client: no alert" "$(slack)" "HTTP 403"
for i in $(seq 200); do v probes.test 192.0.2.$(( i % 9 + 1 )) GET /.git/config 403 199 "-" "$PH"; done
$C; lacks "S3: 200 scanner-path 403s from 9 clients: no alert" "$(slack)" "HTTP 403"
: > /tmp/slack.log
echo "-- a block that refuses pages and forms alike: one alert, not two"
for i in $(seq 60); do v waf.test 192.0.2.$(( i % 5 + 1 )) GET /programs/ 403 199 "-" "$PH"; done
v waf.test 203.0.113.20 POST /apply/ 403 199 "https://waf.test/apply/" "$PH"
$C; s=$(slack)
has "D1: the 403 alert" "$s" "*HTTP 403 Forbidden*: 61 to real visitors in"
has "D1: ... lists the refused form POST" "$s" "Refused form POSTs: \`waf.test\` (1)"
lacks "D1: ... and no separate form alert" "$s" "Form POSTs refused (403) on"
: > /tmp/slack.log; $C; $C; : > /tmp/slack.log
echo "-- what it did before still works"
for i in $(seq 63); do v err.test 192.0.2.$(( i % 7 + 1 )) GET /programs/ 502 157 "-" "$PH"; done
$C; s=$(slack)
has "R1: 63 x 502: the existing HTTP error alert" "$s" "*HTTP 502 Bad Gateway*: 63 to real visitors in"
has "R1: ... same list wording as the 403 alerts" "$s" "Top paths: \`/programs/\` (63)"
has "R1: ... 7 clients, 5 listed: and N other" "$s" "and 2 other clients"
out=$($D/bin/check-server-errors.sh --env $D/.env --dry-run)
has "R2: dry run shows the 403 counts" "$out" "403s: 0 refused form POST(s)"
has "R3: the run log has the 403 counts" "$(tail -3 $D/logs/server-error-monitor.log)" "403: form="
echo "-- bot filter: errors only bots got don't alert"
: > /tmp/slack.log; $C; $C; : > /tmp/slack.log
OLD='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.169 Safari/537.36'
DESK='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'
for p in wrangler.toml vultr.json vercel.json tencent.json service_account.json .env .git/config backup.sql; do
  for i in $(seq 10); do v 64.23.213.183 85.155.14.16 GET /$p 503 197 "-" "$DESK"; done
done
for i in $(seq 60); do v 64.23.213.183 198.51.100.$(( i % 10 + 1 )) GET / 503 197 "-" "$DESK"; done
$C; lacks "B1: 140 x 503 sent to the bare server IP: no alert" "$(slack)" "HTTP 503"
for i in $(seq 40); do v tools.test 198.51.100.$(( i % 5 + 20 )) GET /programs/ 500 157 "-" "curl/8.5.0"; done
for i in $(seq 40); do v tools.test 198.51.100.$(( i % 5 + 30 )) GET /programs/ 500 157 "-" "python-requests/2.31"; done
$C; lacks "B2: 80 x 500 to curl and python (under the outage bar): no alert" "$(slack)" "HTTP 500"
for c in 1 2 3 4 5; do for i in $(seq 15); do v enum.test 198.51.100.4$c GET /page-$i/ 500 157 "-" "$DESK"; done; done
$C; lacks "B3: 75 x 500, each client working through 15 paths: no alert" "$(slack)" "HTTP 500"
for i in $(seq 60); do v old.test 198.51.100.$(( i % 5 + 50 )) GET /programs/ 502 157 "-" "$OLD"; done
$C; lacks "B4: 60 x 502 to an old Chrome that never got an answer: no alert" "$(slack)" "HTTP 502"
for c in 1 2 3 4 5; do
  v probed.test 198.51.100.6$c GET /.env 404 150 "-" "$DESK"
  for i in $(seq 12); do v probed.test 198.51.100.6$c GET /programs/ 502 157 "-" "$DESK"; done
done
$C; lacks "B5: 60 x 502 to clients that also asked for /.env: no alert" "$(slack)" "HTTP 502"
for i in $(seq 60); do v crawl.test 66.249.66.$(( i % 5 + 1 )) GET /programs/ 503 157 "-" "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"; done
$C; lacks "B6: 60 x 503 to Googlebot: no alert" "$(slack)" "HTTP 503"
for i in $(seq 60); do v solo.test 203.0.113.50 GET /programs/ 500 157 "-" "$PH"; done
$C; lacks "B7: 60 x 500 to one real visitor (MIN_REAL_CLIENTS=3): no alert" "$(slack)" "HTTP 500"
for i in $(seq 60); do v ver.test 198.51.100.$(( i + 120 )) GET /readme.html 403 199 "-" "$DESK"; done
$C; lacks "B8: 60 x 403 for readme.html, one per client (a version scan): no alert" "$(slack)" "HTTP 403"
for c in 1 2 3 4 5; do for i in $(seq 12); do v fake.test 198.51.100.8$c GET /old-$i/ 500 157 "https://fake.test/" "$DESK"; done; done
$C; lacks "B9: 60 x 500, each client working through 12 paths with a faked same-site Referer: no alert" "$(slack)" "HTTP 500"
echo "-- bot filter: real visitors still alert, with the bots left out"
for c in 1 2 3 4 5; do
  v real.test 203.0.113.6$c GET /apply/ 200 30000 "-" "$DESK"
  for a in /wp-content/themes/t/style.css /wp-includes/js/jquery/jquery.min.js /wp-content/uploads/logo.png; do
    v real.test 203.0.113.6$c GET $a 200 3000 "https://real.test/apply/" "$DESK"
  done
  for i in $(seq 12); do v real.test 203.0.113.6$c POST /apply/ 500 157 "https://real.test/apply/" "$DESK"; done
done
for i in $(seq 40); do v 64.23.213.183 85.155.14.16 GET /.env 500 197 "-" "$DESK"; done
for i in $(seq 20); do v real.test 198.51.100.70 GET /programs/ 500 157 "-" "Go-http-client/1.1"; done
$C; s=$(slack)
has "R4: 60 x 500 to 5 browsing visitors: alert" "$s" "*HTTP 500 Internal Server Error*: 60 to real visitors in"
has "R4: ... from 5 clients" "$s" "from 5 clients (threshold 50)"
has "R4: ... says what was left out" "$s" "Not counted, as bots: 60 (40 to the bare server IP, 20 from scripts and scan tools)"
lacks "R4: ... no bot in the client list" "$s" "85.155.14.16"
: > /tmp/slack.log; $C; $C; : > /tmp/slack.log
echo "-- outage: bots on site pages still count when there are enough of them"
for i in $(seq 150); do v down.test 198.51.100.$(( i % 15 + 100 )) GET / 502 157 "-" "Mozilla/5.0 (compatible; UptimeRobot/2.0; http://www.uptimerobot.com/)"; done
$C; s=$(slack)
has "U1: 150 x 502 on the home page to 15 bot clients: the outage alert" "$s" "*HTTP 502 Bad Gateway*: 150 on site pages in"
has "U1: ... names the threshold" "$s" "from 15 clients (outage threshold 100), 0 of them to real visitors"
has "U1: ... explains it" "$s" "so visitors get it too"
: > /tmp/slack.log; $C; $C; : > /tmp/slack.log
for i in $(seq 150); do v 64.23.213.183 198.51.100.$(( i % 15 + 100 )) GET / 502 157 "-" "$DESK"; done
$C; lacks "U2: 150 x 502 to the bare server IP: no outage alert" "$(slack)" "HTTP 502"
echo "-- --explain"
out=$(EXPLAIN_TOP=500 $D/bin/check-server-errors.sh --env $D/.env --explain)
has "E1: shows the bot filter summary" "$out" "Bot filter (BOT_FILTER=true)"
has "E1: ... the bare-IP scanner, with its reason" "$out" "85.155.14.16"
has "E1: ... and why" "$out" "bare-ip"
has "E1: ... real visitors with their score" "$out" "score -5 (loads-assets,same-site-referer)"
has "E1: ... the enumerating client" "$out" "score 5 (enumeration,all-failed)"
has "E1: ... the old browser" "$out" "score 3 (old-browser,all-failed)"
has "E1: ... the client that asked for /.env" "$out" "score 4 (probed,all-failed)"
has "E1: ... the outage's bots" "$out" "bot-agent"
has "E1: dry run reports the ignored counts" "$out" "Errors scored as bots, not counted:"
has "E2: the run log has the ignored counts" "$(tail -3 $D/logs/server-error-monitor.log)" "ignored as bots: 502=150"
echo "-- BOT_FILTER=false: every error counts, as before"
echo "BOT_FILTER=false" >> $D/.env; : > /tmp/slack.log
for i in $(seq 60); do v 64.23.213.183 198.51.100.$(( i % 10 + 1 )) GET / 503 197 "-" "$DESK"; done
$C; s=$(slack)
has "X1: 60 x 503 to the bare server IP: alert" "$s" "*HTTP 503 Service Unavailable*: 60 in"
has "X1: ... with the bare-IP note" "$s" "almost always bots"
sed -i '/^BOT_FILTER=/d' $D/.env; : > /tmp/slack.log; $C; $C; : > /tmp/slack.log
echo "-- FORM_403_CHECK=false: no single-form alert"
echo "FORM_403_CHECK=false" >> $D/.env; : > /tmp/slack.log; $C; $C; $C; : > /tmp/slack.log
v off.test 203.0.113.9 POST /wp-admin/admin-ajax.php 403 162 "https://off.test/apply/" "$PH"
$C; lacks "O1: refused form POST: no alert" "$(slack)" "off.test"
echo "-- 403 not in ERROR_CODES: no 403 alerts at all"
sed -i '/^FORM_403_CHECK=/d' $D/.env; echo "ERROR_CODES=500,502,503,504" >> $D/.env; : > /tmp/slack.log
v off2.test 203.0.113.9 POST /wp-admin/admin-ajax.php 403 162 "https://off2.test/apply/" "$PH"
for i in $(seq 60); do v off2.test 192.0.2.$(( i % 5 + 1 )) GET /programs/ 403 199 "-" "$PH"; done
$C; s=$(slack)
lacks "O2: refused form POST: no alert" "$s" "off2.test"
lacks "O2: 60 page 403s from 5 clients: no alert" "$s" "HTTP 403"

echo "-- setup.sh --non-interactive"
N=/opt/sem2; mkdir -p $N; cp -r /src/. $N/; rm -rf $N/.git $N/.env $N/state $N/logs
out=$(bash $N/setup.sh --non-interactive < /dev/null 2>&1); rc=$?
has "N1: no webhook in the environment: stops and says so" "$out" "set SLACK_WEBHOOK_URL in the environment"
[[ $rc != 0 && ! -f $N/.env ]] && ok "N1: ... exit $rc, no .env written" || bad "N1: rc=$rc"
: > /tmp/slack.log
out=$(SLACK_WEBHOOK_URL=http://127.0.0.1:8099/hook bash $N/setup.sh --non-interactive < /dev/null 2>&1); rc=$?
[[ $rc == 0 ]] && ok "N2: runs with no terminal and no answers (exit 0)" || bad "N2: rc=$rc: $(tail -3 <<<"$out")"
has "N2: access logs auto-detected" "$(cat $N/.env)" 'ACCESS_LOGS="/var/log/nginx/*access*log"'
has "N2: 403 in the default codes" "$(cat $N/.env)" "ERROR_CODES=403,500,502,503,504"
has "N2: cron installed" "$(crontab -l)" "$N/bin/check-server-errors.sh --env $N/.env"
lacks "N2: the webhook is never printed" "$out" "8099/hook"
[[ ! -s /tmp/slack.log ]] && ok "N2: no Slack test message" || bad "N2: a test message was sent"
[[ $(stat -c %a $N/.env) == 600 ]] && ok "N2: .env is mode 600" || bad "N2: .env mode $(stat -c %a $N/.env)"
out=$(SLACK_WEBHOOK_URL=http://127.0.0.1:8099/other bash $N/setup.sh --non-interactive < /dev/null 2>&1)
has "N3: an existing .env is kept" "$out" "Keeping existing .env"
lacks "N3: ... unchanged" "$(cat $N/.env)" "8099/other"
sed -i 's/^ERROR_CODES=.*/ERROR_CODES=500,502,503,504/' $N/.env
out=$(bash $N/setup.sh --non-interactive < /dev/null 2>&1)
has "N5: an .env from before 403 monitoring: 403 added" "$(cat $N/.env)" "ERROR_CODES=403,500,502,503,504"
has "N5: ... and says so" "$out" "Added 403 to ERROR_CODES"
[[ $(stat -c %a $N/.env) == 600 ]] && ok "N5: ... still mode 600" || bad "N5: .env mode $(stat -c %a $N/.env)"
sed -i 's/^ERROR_CODES=.*/ERROR_CODES=5xx,404/' $N/.env
out=$(bash $N/setup.sh --non-interactive < /dev/null 2>&1)
has "N6: a list someone changed is left alone" "$(cat $N/.env)" "ERROR_CODES=5xx,404"
M=/opt/sem3; mkdir -p $M; cp -r /src/. $M/; rm -rf $M/.git $M/.env $M/state $M/logs; mv /var/log/nginx /var/log/nginx.off
out=$(SLACK_WEBHOOK_URL=http://127.0.0.1:8099/hook bash $M/setup.sh --non-interactive < /dev/null 2>&1); rc=$?
has "N4: no web logs, no containers (a database box): skipped" "$out" "Nothing to monitor here"
[[ $rc == 0 && ! -f $M/.env ]] && ok "N4: ... exit 0, nothing installed" || bad "N4: rc=$rc .env=$( [[ -f $M/.env ]] && echo yes || echo no)"
mv /var/log/nginx.off /var/log/nginx
echo "== $pass passed, $fail failed"
exit $(( fail > 0 ))
