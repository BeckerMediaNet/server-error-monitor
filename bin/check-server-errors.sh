#!/usr/bin/env bash
#
# check-server-errors.sh
#
# Watches the web server access logs (host log files and/or the stdout logs
# of Docker containers) for spikes of HTTP error codes and the kernel log for
# php-fpm segfaults / general protection faults, and posts a Slack alert via
# an Incoming Webhook when either crosses its threshold.
#
# Only errors that real visitors got count toward a threshold: every error is
# scored as bot or real traffic first (see "Bot filter" below), so scanners
# hitting the bare server IP or probing for /.env don't alert.
#
# Only what's new since the previous run is counted (byte offsets for log
# files, a timestamp for the systemd journal), so it's designed to run from
# root's cron every 5 minutes. The very first run just records where the
# logs currently end and never alerts on old history.
#
# Usage:
#   ./check-server-errors.sh                  # run the real check
#   ./check-server-errors.sh --test-slack     # send a Slack test message and exit
#   ./check-server-errors.sh --dry-run        # print counts only: no Slack, no state changes
#   ./check-server-errors.sh --explain        # dry run over the last 5 MB of each log, showing
#                                             # which errors were scored as bots and why
#   ./check-server-errors.sh --env /path/.env # use a specific .env file
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
TEST_SLACK=false
DRY_RUN=false
EXPLAIN=false

# --- argument parsing -------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-slack)
      TEST_SLACK=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --explain)
      DRY_RUN=true
      EXPLAIN=true
      shift
      ;;
    --env)
      ENV_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing config file: $ENV_FILE (copy .env.example to .env and fill it in)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL not set in $ENV_FILE}"

SITE_LABEL="${SITE_LABEL:-$(hostname)}"
ACCESS_LOGS="${ACCESS_LOGS-/var/log/nginx/*access*log /var/log/apache2/*access*log /var/log/httpd/*access*log}"
DOCKER_CONTAINERS="${DOCKER_CONTAINERS:-}"
ERROR_CODES="${ERROR_CODES:-403,500,502,503,504}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-50}"
CHECK_KERNEL="${CHECK_KERNEL:-true}"
KERNEL_LOG_SOURCE="${KERNEL_LOG_SOURCE:-auto}"
KERNEL_FAULT_THRESHOLD="${KERNEL_FAULT_THRESHOLD:-3}"
KERNEL_FAULT_PROCESS="${KERNEL_FAULT_PROCESS:-php-fpm}"
FORM_403_CHECK="${FORM_403_CHECK:-true}"
MIN_REAL_CLIENTS="${MIN_REAL_CLIENTS:-3}"
BOT_FILTER="${BOT_FILTER:-true}"
BOT_SCORE_THRESHOLD="${BOT_SCORE_THRESHOLD:-3}"
OUTAGE_THRESHOLD="${OUTAGE_THRESHOLD:-100}"
OUTAGE_MIN_CLIENTS="${OUTAGE_MIN_CLIENTS:-10}"
EXPLAIN_TOP="${EXPLAIN_TOP:-25}"
ALERT_COOLDOWN_MINUTES="${ALERT_COOLDOWN_MINUTES:-60}"
RECOVERY_RUNS="${RECOVERY_RUNS:-2}"
TOP_N="${TOP_N:-5}"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/state}"
LOG_DIR="$ROOT_DIR/logs"

mkdir -p "$STATE_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/server-error-monitor.log"
LAST_RUN_FILE="$STATE_DIR/last_run.ts"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# say <msg> — log it, and echo it too during a dry run so it's visible.
say() {
  log "$1"
  [[ "$DRY_RUN" == true ]] && echo "$1"
  return 0
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

send_slack() {
  local text
  text="$(json_escape "$1")"
  curl -fsS --max-time 20 -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"${text}\"}" \
    "$SLACK_WEBHOOK_URL"
}

# --- test mode ---------------------------------------------------------
if [[ "$TEST_SLACK" == true ]]; then
  echo "Sending test message to Slack..."
  if send_slack ":white_check_mark: Test message from the server error monitor for *${SITE_LABEL}*. Slack connection is working."; then
    echo
    echo "Sent. Check the Slack channel tied to your webhook."
    exit 0
  else
    echo "Slack request failed. Check SLACK_WEBHOOK_URL in $ENV_FILE." >&2
    exit 1
  fi
fi

# --- one run at a time ---------------------------------------------------
# A slow run (huge log burst) must not overlap the next cron tick, or both
# would read the same bytes and double count.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$STATE_DIR/.lock"
  if ! flock -n 9; then
    log "Previous run still in progress — skipping this one"
    exit 0
  fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
RAW="$TMP_DIR/raw.tsv"           # one row per monitored error, as parsed (see AWK_PARSE)
CSTATS="$TMP_DIR/clients.tsv"    # client<TAB>requests<TAB>ok<TAB>assets<TAB>error paths<TAB>same-site referer<TAB>probed, per log source
ALL="$TMP_DIR/all.tsv"           # RAW scored: code client path source site class reason score signals method agent
MATCHES="$TMP_DIR/matches.tsv"   # the rows of ALL that real visitors got (all of them with BOT_FILTER=false)
BOTS="$TMP_DIR/bots.tsv"         # the rows of ALL scored as bots
PAGES="$TMP_DIR/pages.tsv"       # the rows of ALL for a normal page on a named site, whoever asked (outage check)
STATS="$TMP_DIR/stats"           # source<TAB>lines<TAB>unparsed, one row per log source
FORM403="$TMP_DIR/403.tsv"       # form<TAB>client<TAB>path<TAB>source<TAB>site (or source), one row per refused form POST
: > "$RAW"
: > "$CSTATS"
: > "$STATS"
: > "$FORM403"

NOW="$(date +%s)"
LAST_RUN="$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")"
if [[ -n "$LAST_RUN" ]] && (( NOW - LAST_RUN < 120 )); then
  WINDOW_LABEL="the last $(( NOW - LAST_RUN )) seconds"
elif [[ -n "$LAST_RUN" ]] && (( NOW - LAST_RUN < 7200 )); then
  WINDOW_LABEL="the last $(( (NOW - LAST_RUN + 30) / 60 )) minutes"
elif [[ -n "$LAST_RUN" ]]; then
  WINDOW_LABEL="the last $(( (NOW - LAST_RUN + 1800) / 3600 )) hours"
else
  WINDOW_LABEL="this run"
fi
[[ "$DRY_RUN" == true ]] && WINDOW_LABEL="this dry run"

write_state() {
  [[ "$DRY_RUN" == true ]] || printf '%s\n' "$2" > "$1"
}

state_key() {
  printf '%s' "$1" | sed 's|[^A-Za-z0-9._-]|_|g'
}

# head_sum <file> <bytes> — checksum of the first <bytes> of a file.
head_sum() {
  head -c "$2" "$1" 2>/dev/null | cksum | cut -d' ' -f1
}

# read_new <file>
# Prints whatever was appended to <file> since the last run and records the
# new end position. Handles logrotate: if the inode changed, the rest of the
# old file (now <file>.1) is read first, then the new file from the start;
# if the file shrank or its first bytes changed (copytruncate, even when it
# has already grown past the old position), it's read from the start. With no saved
# position it only records one (first run) — except in a dry run, where it
# prints the last 5 MB so you can see what the parser makes of it. --explain
# always reads the last 5 MB, so there's enough traffic to judge the scoring.
read_new() {
  local file="$1" offset_file inode size old_inode="" old_offset="" old_head="" old_head_len=0 rotated head_len
  offset_file="$STATE_DIR/offset_$(state_key "$file")"

  if [[ ! -r "$file" ]]; then
    say "Cannot read $file — skipping (run as root?)"
    return 0
  fi
  read -r inode size < <(stat -c '%i %s' "$file" 2>/dev/null) || return 0
  [[ -f "$offset_file" ]] && read -r old_inode old_offset old_head old_head_len < "$offset_file"

  if [[ -z "$old_offset" || "$EXPLAIN" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      tail -c 5000000 "$file"
    else
      log "Baseline for $file at byte $size (first time seeing it — existing lines not counted)"
    fi
  else
    if [[ "$inode" != "$old_inode" ]]; then
      rotated="$file.1"
      if [[ -f "$rotated" ]] && [[ "$(stat -c %i "$rotated" 2>/dev/null)" == "$old_inode" ]]; then
        tail -c +"$((old_offset + 1))" "$rotated"
        echo
      fi
      old_offset=0
    elif (( size < old_offset )) || [[ -n "$old_head" && "$(head_sum "$file" "$old_head_len")" != "$old_head" ]]; then
      old_offset=0
    fi
    if (( size > old_offset )); then
      tail -c +"$((old_offset + 1))" "$file" | head -c "$((size - old_offset))"
      echo
    fi
  fi

  head_len=$(( size < 512 ? size : 512 ))
  write_state "$offset_file" "$inode $size $(head_sum "$file" "$head_len") $head_len"
}

# --- HTTP error check -------------------------------------------------------
# Works with the default nginx "combined" and Apache combined/common formats
# (and anything else with `"<request>" <status> ` in it): the status code is
# the first 3-digit number that follows a closing quote. The client is the
# IP address three fields before the [timestamp] ("<ip> <ident> <user> [ts]"),
# falling back to the first IP address before it. If a hostname or IP comes
# right before the client — nginx-proxy's "vhost" format, Apache's
# vhost_combined — that's recorded as the site (an IP there means the request
# was sent to the server's bare IP, not to a site name). Anything in front of
# those (like the "nginx.1 |" prefix nginx-proxy's process manager adds) and
# terminal colour codes are ignored. Written for plain POSIX awk (mawk on
# Debian/Ubuntu) — no gawk extensions.
#
# A monitored 403 only counts when a visitor was refused. Each one is sorted:
#   form   a visitor's form POST was refused: a POST from a browser that carried
#          the page it came from (Referer) to admin-ajax.php, a form plugin's REST
#          route, or a page. Bots and scanners send no Referer (checked against
#          13 servers' logs, 10/29: every real refused form POST had one, no bot
#          did). WordPress's own 2-byte "-1"/"0" reply on admin-ajax.php is a stale
#          nonce on a cached page, not a block, and is left out. Also written to
#          the form file (f403) for the refused-form alert.
#   visit  any other 403 on a path a visitor could ask for.
# Anything else is never counted ("probe-403"): scanner paths (dot files, .php
# other than index.php, wp-login, xmlrpc, wp-admin, backups) and POSTs with no
# Referer, since bots get refused there all day.
#
# Bot filter, part 1 (here, per request). Every error row gets either a hard
# reason, which makes it a bot whatever else the client did:
#   bad-request  no proper "METHOD /path HTTP/x" request line (TLS sent to
#                port 80, "-", an unknown method)
#   bare-ip      sent to the server's IP address, not to a site name
#   probe        a path no visitor asks for: dot files (/.env, /.git/),
#                backups and config files (.sql, .zip, .yml, .toml, a .json
#                at the web root), .php files other than WordPress's own entry
#                points (xmlrpc.php included), /vendor/, /cgi-bin/, phpMyAdmin
#   no-agent     no User-Agent
#   crawler      a search engine's crawler (Googlebot, Bingbot, ...)
#   tool-agent   a script or scanner (curl, python, Go, zgrab, nuclei, ...)
#   bot-agent    an agent that names itself a bot (bot/, crawl, spider, a URL)
# or soft points that the client's behaviour adds to (part 2, SCORE_AWK):
#   not-a-browser +2  an agent that isn't a browser's "Mozilla/..." string
#   old-browser   +2  Chrome or Firefox older than version 100, or Internet
#                     Explorer: bots copy old browser strings, browsers update
#   head-request  +2  HEAD (browsers never send one)
#   http1.0       +2  HTTP/1.0 (browsers never send one)
# Every line (not just errors) also adds to its client's totals, written to
# the cstats file at the end: requests, successful (2xx/3xx) replies, static
# files loaded, distinct paths that errored, whether it sent a same-site
# Referer, and whether it asked for a probe path.
AWK_PARSE='
function is_ip(s) {
  return s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || s ~ /^[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F:.]*$/
}
function kind403(method, url, after, ua, ref,   lp, qs, j, bytes, endpoint, page, browser) {
  lp = tolower(url); qs = ""
  j = index(lp, "?"); if (j > 0) { qs = substr(lp, j + 1); lp = substr(lp, 1, j - 1) }
  bytes = after; sub(/ .*/, "", bytes); if (bytes == "-") bytes = 0
  endpoint = (lp == "/wp-admin/admin-ajax.php" || ((lp ~ /^\/wp-json\// || qs ~ /(^|&)rest_route=/) && (lp "?" qs) ~ /(\/|=%2f|=\/)(gf|gravityforms|contact-form-7|wpforms|frm|ninja-forms|forminator)(\/|%2f)/))
  page = !(lp ~ /^\/wp-(admin|content|includes|json)(\/|$)/ || lp ~ /\/\./ || (lp ~ /\.[a-z0-9]+$/ && lp !~ /\/index\.php$/ && lp !~ /\.html?$/))
  browser = (ua ~ /Mozilla\// && tolower(ua) !~ /compatible[;)]|\+https?:\/\/|headless/)
  if (method == "POST" && browser && ref != "" && ref != "-" && (endpoint || page) && !(lp == "/wp-admin/admin-ajax.php" && bytes + 0 <= 2)) return "form"
  if (lp ~ /\/\./ || lp ~ /(^|\/)(xmlrpc|wp-login|wp-cron|wp-trackback|wp-comments-post|wp-signup|wp-activate)\.php$/) return ""
  if (lp ~ /\.php$/ && lp !~ /(^|\/)index\.php$/ && lp != "/wp-admin/admin-ajax.php") return ""
  if (lp ~ /^\/wp-admin(\/|$)/ && lp != "/wp-admin/admin-ajax.php") return ""
  if (lp ~ /\.(bak|old|orig|sql|zip|tar|gz|tgz|rar|7z|env|ini|log|swp|yml|yaml|conf|config)$/) return ""
  if (method == "POST" && !(browser && ref != "" && ref != "-")) return ""
  return "visit"
}
# is_probe <lowercased path, no query string> — a path only scanners ask for.
function is_probe(lp) {
  if (lp ~ /\/\./) return 1
  if (lp ~ /\.(bak|old|orig|save|swp|sql|zip|tar|gz|tgz|rar|7z|env|ini|log|yml|yaml|toml|conf|config|cfg|pem|key|asp|aspx|jsp|cgi|cfm)$/) return 1
  if (lp ~ /^\/[^\/]+\.json$/ && lp != "/manifest.json") return 1
  if (lp ~ /\.php$/ && lp !~ /(^|\/)index\.php$/ && lp !~ /^\/wp-admin\// && lp !~ /^\/(wp-login|wp-cron|wp-comments-post|wp-signup|wp-activate|wp-trackback)\.php$/) return 1
  if (lp ~ /^\/(vendor|cgi-bin|phpmyadmin|pma|myadmin|adminer|actuator|solr|owa|ecp|autodiscover|boaform|hnap1|geoserver|druid|telescope|_ignition|server-status)(\/|$)/) return 1
  if (lp ~ /wlwmanifest\.xml$/) return 1
  return 0
}
# agent_hard <user agent> — a hard bot reason for the agent alone, or "".
function agent_hard(ua,   l) {
  if (ua == "" || ua == "-") return "no-agent"
  l = tolower(ua)
  if (l ~ /googlebot|google-inspectiontool|bingbot|bingpreview|duckduckbot|yandex(bot|images)|baiduspider|applebot|slurp|petalbot|seznambot/) return "crawler"
  if (l ~ /^(curl|wget|python|go-http-client|java|okhttp|libwww|lwp|perl|ruby|php|guzzle|axios|node|undici|apache-httpclient|scrapy|aiohttp|httpx|fasthttp|colly|postman|httpie|reqwest|dart|winhttp|mechanize|faraday|wordpress)/) return "tool-agent"
  if (l ~ /zgrab|masscan|nmap|nikto|sqlmap|nuclei|wpscan|censys|shodan|l9scan|leakix|expanse|phantomjs|selenium|puppeteer|playwright|headless/) return "tool-agent"
  if (l ~ /bot[\/;+)]|bot$|crawl|spider|scan|compatible[;)]|https?:\/\/|\+http/) return "bot-agent"
  return ""
}
# major <ua> <name/> — the major version after e.g. "Chrome/", or -1.
function major(ua, name,   p, v) {
  p = index(ua, name); if (p == 0) return -1
  v = substr(ua, p + length(name)); sub(/[^0-9].*/, "", v)
  return (v == "") ? -1 : v + 0
}
function soft(pts, label) { spts += pts; slab = slab (slab != "" ? "," : "") label }
BEGIN {
  n = split(codes, list, ",")
  for (i = 1; i <= n; i++) {
    c = tolower(list[i]); gsub(/[ \t]/, "", c)
    if (c ~ /^[1-5]xx$/) cls[substr(c, 1, 1)] = 1
    else if (c != "") exact[c] = 1
  }
  esc = sprintf("%c", 27)
}
NF == 0 { next }
{
  # nginx-proxy colours its output; in Docker JSON logs the escape shows up
  # as a literal \u001b, elsewhere as a real ESC character.
  gsub(esc "\\[[0-9;]*m", ""); gsub(/\\u001b\[[0-9;]*m/, "")
  total++
  if (!match($0, /" [1-5][0-9][0-9] /)) { unparsed++; next }
  code = substr($0, RSTART + 2, 3)
  after = substr($0, RSTART + RLENGTH)
  q = index($0, "\"")
  req = substr($0, q + 1, RSTART - q - 1)
  np = split(req, parts, " ")
  url = (parts[2] != "") ? parts[2] : req
  path = url
  sub(/\?.*/, "", path)
  lp = tolower(path)
  if (length(path) > 100) path = substr(path, 1, 100) "..."
  client = $1; site = ""; ci = 0
  for (j = 1; j <= NF && substr($j, 1, 1) != "["; j++) ;
  if (j <= NF && j > 3 && is_ip($(j - 3))) ci = j - 3
  else for (i = 1; i < j; i++) if (is_ip($i)) { ci = i; break }
  if (ci > 0) {
    client = $ci
    if (ci > 1) {
      s = $(ci - 1); sub(/:[0-9]+$/, "", s)
      if (s !~ /[|]/ && s ~ /\./ && (s ~ /[A-Za-z]/ || is_ip(s))) site = s
    }
  }
  ref = ""; ua = ""; rest = after; nq = 0
  while (match(rest, /"[^"]*"/)) {
    nq++
    if (nq == 1) ref = substr(rest, RSTART + 1, RLENGTH - 2)
    else { ua = substr(rest, RSTART + 1, RLENGTH - 2); break }
    rest = substr(rest, RSTART + RLENGTH)
  }

  # the client totals, over every line
  c1 = substr(code, 1, 1)
  nreq[client]++
  if (c1 == "2" || c1 == "3") ok[client]++
  if ((c1 == "2" || code == "304") && lp ~ /\.(css|js|mjs|woff2?|ttf|otf|png|jpe?g|gif|svg|webp|avif)$/) asset[client]++
  if (c1 == "4" || c1 == "5") { k = client SUBSEP lp; if (!(k in errpath)) { errpath[k] = 1; nerr[client]++ } }
  probe = is_probe(lp)
  if (probe) probed[client] = 1
  if (ref ~ /^https?:\/\//) {
    rh = tolower(ref); sub(/^[a-z]+:\/\//, "", rh); sub(/[\/:?#].*$/, "", rh); sub(/^www\./, "", rh)
    sh = tolower(site); sub(/^www\./, "", sh)
    if (sh == "" || rh == sh) sameref[client] = 1
  }

  watched = (code in exact) || (c1 in cls)
  if (!watched) next
  hard = ""
  if (code == "403") {
    k = kind403(parts[1], url, after, ua, ref)
    if (k == "form" && f403 != "") print k "\t" client "\t" path "\t" src "\t" (site != "" ? site : src) >> f403
    if (k == "") hard = "probe-403"
  }
  if (np != 3 || parts[1] !~ /^(GET|POST|HEAD|PUT|PATCH|DELETE|OPTIONS)$/ || parts[3] !~ /^HTTP\/[0-9.]+$/) hard = "bad-request"
  else if (is_ip(site)) hard = "bare-ip"
  else if (probe) hard = "probe"
  else if (hard == "") hard = agent_hard(ua)
  spts = 0; slab = ""
  if (hard == "") {
    if (ua !~ /Mozilla\/|Opera\//) soft(2, "not-a-browser")
    else if ((v = major(ua, "Chrome/")) >= 0 && v < 100 || (v = major(ua, "Firefox/")) >= 0 && v < 100 || ua ~ /MSIE |Trident\//) soft(2, "old-browser")
    if (parts[1] == "HEAD") soft(2, "head-request")
    if (parts[3] == "HTTP/1.0") soft(2, "http1.0")
  }
  agent = ua; gsub(/\t/, " ", agent); if (length(agent) > 150) agent = substr(agent, 1, 150) "..."
  print code "\t" client "\t" path "\t" src "\t" site "\t" (hard != "" ? hard : "-") "\t" spts "\t" (slab != "" ? slab : "-") "\t" parts[1] "\t" agent
}
END {
  print src "\t" (total + 0) "\t" (unparsed + 0) >> stats
  for (c in nreq) print c "\t" nreq[c] "\t" (ok[c] + 0) "\t" (asset[c] + 0) "\t" (nerr[c] + 0) "\t" (sameref[c] + 0) "\t" (probed[c] + 0) >> cstats
}
'

is_rotated_name() {
  [[ "$1" =~ \.(gz|bz2|xz|zst|zip)$ || "$1" =~ \.[0-9]+$ || "$1" =~ -[0-9]{8}$ ]]
}

LOG_FILES=()
declare -A SEEN_LOG=()
shopt -s nullglob
# shellcheck disable=SC2086 # word splitting + glob expansion is the point
for f in $ACCESS_LOGS; do
  [[ -f "$f" ]] || continue
  is_rotated_name "$f" && continue
  [[ -n "${SEEN_LOG[$f]:-}" ]] && continue
  SEEN_LOG[$f]=1
  LOG_FILES+=("$f")
done
shopt -u nullglob

for f in ${LOG_FILES[@]+"${LOG_FILES[@]}"}; do
  read_new "$f" | awk -v codes="$ERROR_CODES" -v src="$f" -v stats="$STATS" -v cstats="$CSTATS" -v f403="$FORM403" "$AWK_PARSE" >> "$RAW"
done

# read_container <name>
# Prints the stdout lines a container has logged since the last run (access
# logs go to stdout in nginx-proxy and the official nginx/httpd images; error
# logs go to stderr and are skipped). With Docker's default json-file driver
# the container's log file is read directly via read_new — cheap even when it
# has grown to gigabytes, unlike `docker logs --since`, which rescans it from
# the start — and the JSON wrapper is stripped off. A changed log path means
# the container was recreated since the last run, so its new log is read from
# the start. Other log drivers fall back to `docker logs --since`.
read_container() {
  local name="$1" driver path path_file prev ts_file since
  read -r driver path < <(docker inspect -f '{{.HostConfig.LogConfig.Type}} {{.LogPath}}' "$name" 2>/dev/null) || return 0

  if [[ "$driver" == json-file && -r "$path" ]]; then
    path_file="$STATE_DIR/docker_$(state_key "$name").path"
    prev="$(cat "$path_file" 2>/dev/null || true)"
    if [[ -n "$prev" && "$prev" != "$path" ]]; then
      log "Container $name was recreated — reading its new log from the start"
      [[ "$DRY_RUN" == true ]] || rm -f "$STATE_DIR/offset_$(state_key "$prev")"
      write_state "$STATE_DIR/offset_$(state_key "$path")" "$(stat -c %i "$path") 0"
    fi
    write_state "$path_file" "$path"
    read_new "$path" | sed -e '/"stream":"stdout"/!d' -e 's/^{"log":"//' \
      -e 's/\(\\n\)\{0,1\}","stream":.*$//' -e 's/\\"/"/g'
  else
    ts_file="$STATE_DIR/docker_$(state_key "$name").ts"
    since="$(cat "$ts_file" 2>/dev/null || true)"
    if [[ -n "$since" && "$EXPLAIN" != true ]]; then
      docker logs --since "$since" --until "$NOW" "$name" 2>/dev/null
    elif [[ "$DRY_RUN" == true ]]; then
      docker logs --tail 20000 "$name" 2>/dev/null
    else
      log "Baseline for container $name (first time seeing it — earlier lines not counted)"
    fi
    write_state "$ts_file" "$NOW"
  fi
}

CONTAINERS=()
MISSING_CONTAINERS=()
if [[ -n "$DOCKER_CONTAINERS" ]] && ! command -v docker >/dev/null 2>&1; then
  say "DOCKER_CONTAINERS is set but docker isn't on PATH"
fi
for name in $DOCKER_CONTAINERS; do
  if command -v docker >/dev/null 2>&1 && docker inspect "$name" >/dev/null 2>&1; then
    CONTAINERS+=("$name")
    read_container "$name" | awk -v codes="$ERROR_CODES" -v src="docker:$name" -v stats="$STATS" -v cstats="$CSTATS" -v f403="$FORM403" "$AWK_PARSE" >> "$RAW"
  else
    say "Container $name not found"
    MISSING_CONTAINERS+=("$name")
  fi
done
SOURCE_COUNT=$(( ${#LOG_FILES[@]} + ${#CONTAINERS[@]} ))

# --- bot filter, part 2: the client's behaviour ---------------------------------
# A row with a hard reason (see AWK_PARSE) is a bot. Every other row starts from
# its request's soft points and adds what its client did across all the logs
# since the last run:
#   probed            +3  also asked for a probe path (/.env, /.git/, ...)
#   enumeration       +3  errors on 8+ different paths, under 20% answered OK:
#                         working through a list, not reading a site
#   all-failed        +1  not a single request answered OK
#   loads-assets      -3  loaded 3+ css/js/font/image files: a browser
#                         drawing the page (behind a CDN those never reach
#                         this log, so not loading them counts for nothing)
#   same-site-referer -2  came from one of the site's own pages
# BOT_SCORE_THRESHOLD (3) or more is a bot. A visitor caught in an outage gets
# nothing but errors and no assets (all-failed, +1): still real.
# BOT_FILTER=false counts everything as real, as before the filter, except the
# 403s that were never counted (probe-403).
SCORE_AWK='
FILENAME == cf { n[$1] += $2; ok[$1] += $3; as[$1] += $4; ne[$1] += $5; if ($6 + 0) sr[$1] = 1; if ($7 + 0) pr[$1] = 1; next }
function add(pts, label) { s += pts; lab = lab (lab != "" ? "," : "") label }
{
  c = $2; h = $6; s = $7 + 0; lab = ($8 == "-") ? "" : $8
  if (h == "-") {
    if (pr[c]) add(3, "probed")
    if (ne[c] >= 8 && ok[c] * 5 < n[c]) add(3, "enumeration")
    if (ok[c] == 0) add(1, "all-failed")
    if (as[c] >= 3) add(-3, "loads-assets")
    if (sr[c]) add(-2, "same-site-referer")
    class = (s >= thr) ? "bot" : "real"
    why = (class == "bot") ? "behaviour" : "-"
  } else {
    class = "bot"; why = h; s = "-"
  }
  if (filter != "true") class = (h == "probe-403") ? "bot" : "real"
  print $1, $2, $3, $4, $5, class, why, s, (lab != "" ? lab : "-"), $9, $10
}'
awk -F'\t' -v OFS='\t' -v cf="$CSTATS" -v thr="$BOT_SCORE_THRESHOLD" -v filter="$BOT_FILTER" \
  "$SCORE_AWK" "$CSTATS" "$RAW" > "$ALL"
awk -F'\t' '$6 == "real"' "$ALL" > "$MATCHES"
awk -F'\t' '$6 == "bot"' "$ALL" > "$BOTS"
# The outage check (5xx only) looks at every error on a normal page of a named
# site, bots included: a bot that gets a 502 for the home page means visitors
# get it too. Bare-IP, probe and malformed requests are still left out.
awk -F'\t' '$7 !~ /^(bare-ip|probe|probe-403|bad-request)$/' "$ALL" > "$PAGES"

declare -A CODE_COUNT=()
while read -r n code; do
  [[ -n "$code" ]] && CODE_COUNT[$code]=$n
done < <(cut -f1 "$MATCHES" | sort | uniq -c)

TOTAL_LINES=0
TOTAL_UNPARSED=0
while IFS=$'\t' read -r _ lines unparsed; do
  TOTAL_LINES=$((TOTAL_LINES + lines))
  TOTAL_UNPARSED=$((TOTAL_UNPARSED + unparsed))
done < "$STATS"

if (( TOTAL_LINES >= 20 && TOTAL_UNPARSED * 2 > TOTAL_LINES )); then
  say "Warning: $TOTAL_UNPARSED of $TOTAL_LINES access log lines had no recognisable status code — is the log format combined/common?"
fi

threshold_for() {
  local var="THRESHOLD_$1"
  printf '%s' "${!var:-$ERROR_THRESHOLD}"
}

# top_list <file> <kind regex> <column> <noun> [site] — "`value` (count), ...
# and N other <noun>s" for the busiest values in one column of a match file
# (MATCHES or FORM403), over the rows whose first column matches <kind regex>
# and, if given, whose site (or log, when no site was recorded) is [site]. A
# bare IPv4 address in the site column is flagged, since it means the request
# didn't name a site at all.
top_list() {
  awk -F'\t' -v k="$2" -v col="$3" -v s="${5:-}" \
    '$1 ~ k && (s == "" || ($5 != "" ? $5 : $4) == s) && $col != "" { print $col }' "$1" \
    | sort | uniq -c | sort -rn \
    | awk -v top="$TOP_N" -v noun="$4" -v site_col="$([[ $3 == 5 ]] && echo 1 || echo 0)" '
        NR <= top {
          n = $1; $1 = ""; sub(/^ /, "")
          note = (site_col && $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ? ", the server IP, not a site name" : ""
          printf "%s`%s` (%d%s)", (NR > 1 ? ", " : ""), $0, n, note
        }
        END { if (NR > top) printf " and %d other %s%s", NR - top, noun, (NR - top == 1 ? "" : "s") }'
}

# top_share <code> <column> [file] — percentage of a code's matches (MATCHES,
# or [file]) that come from its single most common value.
top_share() {
  awk -F'\t' -v c="$1" -v col="$2" '
    $1 == c { t++; if ($col != "" && ++n[$col] > m) m = n[$col] }
    END { print (t ? int(m * 100 / t) : 0) }' "${3:-$MATCHES}"
}

# count_in <file> <code> / clients_in <file> <code> — how many rows of a code a
# match file has, and from how many different clients.
count_in() {
  awk -F'\t' -v c="$2" '$1 == c { n++ } END { print n + 0 }' "$1"
}
clients_in() {
  awk -F'\t' -v c="$2" '$1 == c && !seen[$2]++ { n++ } END { print n + 0 }' "$1"
}

# min_clients_for <code> — MIN_CLIENTS_<code> if set (MIN_CLIENTS_403 predates
# the bot filter), else MIN_REAL_CLIENTS.
min_clients_for() {
  local var="MIN_CLIENTS_$1"
  printf '%s' "${!var:-$MIN_REAL_CLIENTS}"
}

# ignored_summary <code> — "214 (92 to scanner paths, 81 to the bare server
# IP, ...)" for a code's rows scored as bots, busiest reason first; empty when
# there are none.
ignored_summary() {
  awk -F'\t' -v c="$1" '$1 == c { r = ($7 == "probe-403") ? "probe" : $7; n[r]++; t++ }
    END { for (r in n) print n[r] "\t" r; if (t) print t "\ttotal" }' "$BOTS" \
    | sort -t$'\t' -k1,1rn \
    | awk -F'\t' '
        $2 == "total" { t = $1; next }
        {
          w = $2
          if (w == "bare-ip") w = "to the bare server IP"
          else if (w == "probe") w = "to scanner paths"
          else if (w == "no-agent") w = "with no user agent"
          else if (w == "tool-agent") w = "from scripts and scan tools"
          else if (w == "bot-agent") w = "from self-declared bots"
          else if (w == "crawler") w = "from search engine crawlers"
          else if (w == "bad-request") w = "malformed requests"
          else if (w == "behaviour") w = "from clients that behaved like bots"
          list = list (list != "" ? ", " : "") $1 " " w
        }
        END { if (t) printf "%d (%s)", t, list }'
}

# code_name <code> — the standard name of an HTTP status code.
code_name() {
  case "$1" in
    400) echo "Bad Request" ;;            401) echo "Unauthorized" ;;
    403) echo "Forbidden" ;;              404) echo "Not Found" ;;
    405) echo "Method Not Allowed" ;;     408) echo "Request Timeout" ;;
    413) echo "Content Too Large" ;;      429) echo "Too Many Requests" ;;
    499) echo "Client Closed Request" ;;  500) echo "Internal Server Error" ;;
    501) echo "Not Implemented" ;;        502) echo "Bad Gateway" ;;
    503) echo "Service Unavailable" ;;    504) echo "Gateway Timeout" ;;
    5*) echo "Server Error" ;;            4*) echo "Client Error" ;;
    *) echo "" ;;
  esac
}

# code_meaning <code> — one plain-English sentence on what the code means.
code_meaning() {
  case "$1" in
    500) echo "The site's code failed while building these pages (for example a PHP fatal error or a broken plugin)." ;;
    502) echo "The web server couldn't get an answer from the app behind it, usually because PHP or the site's container is down or crashing." ;;
    503) echo "The server turned these requests away: it was overloaded or in maintenance mode, or no site is set up for the address that was requested." ;;
    504) echo "The app behind the web server took too long to answer, often because of slow pages, a slow database or all PHP workers being busy." ;;
    404) echo "Requests for pages that don't exist. Spikes are usually bots probing for vulnerable files, or broken links." ;;
    403) echo "Requests blocked by access rules, a firewall or a security plugin." ;;
    429) echo "Visitors were rate-limited for sending too many requests." ;;
    499) echo "Visitors gave up and disconnected before the server answered, which usually means pages are slow." ;;
    5*) echo "The server failed to handle these requests." ;;
    4*) echo "The server rejected these requests." ;;
    *) echo "" ;;
  esac
}

# --- kernel fault check -----------------------------------------------------
KERNEL_LINES="$TMP_DIR/kernel.log"
: > "$KERNEL_LINES"
KERNEL_SOURCE_USED=""

kernel_new_lines() {
  local source="$KERNEL_LOG_SOURCE" ts_file since
  if [[ "$source" == auto ]]; then
    if command -v journalctl >/dev/null 2>&1 && journalctl -k -n 1 -q --no-pager 2>/dev/null | grep -q .; then
      source=journal
    elif [[ -f /var/log/kern.log ]]; then
      source=/var/log/kern.log
    elif [[ -f /var/log/messages ]]; then
      source=/var/log/messages
    else
      say "No kernel log source found (no journal, /var/log/kern.log or /var/log/messages) — skipping kernel check"
      return 0
    fi
  fi
  KERNEL_SOURCE_USED="$source"

  if [[ "$source" == journal ]]; then
    ts_file="$STATE_DIR/kernel_journal.ts"
    since="$(cat "$ts_file" 2>/dev/null || echo "")"
    if [[ -n "$since" ]]; then
      journalctl -k -q --no-pager --since "@$since" --until "@$NOW" 2>/dev/null
    elif [[ "$DRY_RUN" == true ]]; then
      journalctl -k -q --no-pager 2>/dev/null
    else
      log "Baseline for kernel journal at $(date -d "@$NOW" '+%F %T') (first run — earlier faults not counted)"
    fi
    write_state "$ts_file" "$NOW"
  else
    read_new "$source"
  fi
}

SEGFAULTS=0
GPFS=0
if [[ "$CHECK_KERNEL" == true ]]; then
  kernel_new_lines > "$TMP_DIR/kernel_raw.log"
  grep -E "${KERNEL_FAULT_PROCESS}[^[:space:]]*\[[0-9]+\]:? (segfault at|general protection)" \
    "$TMP_DIR/kernel_raw.log" > "$KERNEL_LINES" || true
  SEGFAULTS="$(grep -c 'segfault at' "$KERNEL_LINES" || true)"
  GPFS="$(grep -c 'general protection' "$KERNEL_LINES" || true)"
fi
KERNEL_FAULTS=$((SEGFAULTS + GPFS))

# --- alert state ------------------------------------------------------------
# Each condition has its own state file holding "<last alert epoch> <clear runs>".
# While a condition stays over threshold it re-alerts at most once per
# ALERT_COOLDOWN_MINUTES; once it has been back under for RECOVERY_RUNS runs in
# a row, one recovery message is sent and the state is cleared.
ALERTS=()
RECOVERIES=()

evaluate() {
  local key="$1" triggered="$2" alert_text="$3" recovery_text="$4"
  local f="$STATE_DIR/alert_${key}" last=0 clear=0
  [[ -f "$f" ]] && read -r last clear < "$f"

  if [[ "$triggered" == true ]]; then
    if [[ ! -f "$f" ]] || (( NOW - last >= ALERT_COOLDOWN_MINUTES * 60 )); then
      ALERTS+=("$alert_text")
      last=$NOW
    else
      log "Still over threshold, alert suppressed by cooldown: $key"
    fi
    write_state "$f" "$last 0"
  elif [[ -f "$f" ]]; then
    clear=$((clear + 1))
    if (( clear >= RECOVERY_RUNS )); then
      RECOVERIES+=("$recovery_text")
      [[ "$DRY_RUN" == true ]] || rm -f "$f"
    else
      write_state "$f" "$last $clear"
    fi
  fi
}

# Any code with errors now (real visitors' or, for the outage check, on site
# pages), or that was alerting last time (so it can recover).
mapfile -t CODES_TO_EVALUATE < <(cut -f1 "$ALL" | sort -u)
for f in "$STATE_DIR"/alert_http_*; do
  [[ -f "$f" ]] && CODES_TO_EVALUATE+=("${f##*alert_http_}")
done

# Each code alerts in one of two ways:
#   real    more than its threshold of errors that real visitors got, from at
#           least MIN_REAL_CLIENTS (3) of them, so one visitor (or one bot that
#           got through the filter) hammering a page doesn't alert
#   outage  5xx only: more than OUTAGE_THRESHOLD (100) errors on normal pages of
#           named sites from at least OUTAGE_MIN_CLIENTS (10) clients, bots
#           included. At 3am the only clients may be bots, but a server that
#           answers them with 502s for the home page is down for visitors too.
#           OUTAGE_THRESHOLD=0 turns this off.
CLIENTS_403=$(clients_in "$MATCHES" 403)
FORM403_COUNT=$(wc -l < "$FORM403")
HTTP403_OVER=false
declare -A OVER_HOW=()

SUMMARY=""
BOT_SUMMARY=""
(( SOURCE_COUNT == 0 )) && CODES_TO_EVALUATE=()
for code in $(printf '%s\n' ${CODES_TO_EVALUATE[@]+"${CODES_TO_EVALUATE[@]}"} | sort -u); do
  count="${CODE_COUNT[$code]:-0}"
  clients="$(clients_in "$MATCHES" "$code")"
  threshold="$(threshold_for "$code")"
  min_clients="$(min_clients_for "$code")"
  bots="$(count_in "$BOTS" "$code")"
  SUMMARY+=" ${code}=${count}"
  (( bots > 0 )) && BOT_SUMMARY+=" ${code}=${bots}"
  label="${code} $(code_name "$code")"
  label="${label% }"
  triggered=false
  alert_text=""
  how=""
  if (( count > threshold && clients >= min_clients )); then
    how=real
  elif [[ "$code" == 5* ]] && (( OUTAGE_THRESHOLD > 0 )); then
    pages="$(count_in "$PAGES" "$code")"
    page_clients="$(clients_in "$PAGES" "$code")"
    (( pages > OUTAGE_THRESHOLD && page_clients >= OUTAGE_MIN_CLIENTS )) && how=outage
  fi
  if [[ -n "$how" ]]; then
    triggered=true
    OVER_HOW[$code]="$how"
    [[ "$code" == 403 ]] && HTTP403_OVER=true
    rows="$MATCHES"
    if [[ "$how" == outage ]]; then
      rows="$PAGES"
      alert_text="*HTTP ${label}*: ${pages} on site pages in ${WINDOW_LABEL} from ${page_clients} clients (outage threshold ${OUTAGE_THRESHOLD}), ${count} of them to real visitors"
    elif [[ "$BOT_FILTER" == true ]]; then
      alert_text="*HTTP ${label}*: ${count} to real visitors in ${WINDOW_LABEL} from ${clients} clients (threshold ${threshold})"
    else
      alert_text="*HTTP ${label}*: ${count} in ${WINDOW_LABEL} from ${clients} clients (threshold ${threshold})"
    fi
    meaning="$(code_meaning "$code")"
    [[ -n "$meaning" ]] && alert_text+=$'\n'"_${meaning}_"
    [[ "$how" == outage ]] && alert_text+=$'\n'"_Most of these clients look like bots, but they asked for normal pages of the site and got a server error, so visitors get it too._"
    sites="$(top_list "$rows" "^${code}\$" 5 site)"
    if [[ -n "$sites" ]]; then
      alert_text+=$'\n'"• Top sites: ${sites}"
      [[ "$sites" == *"the server IP, not a site name"* ]] && \
        alert_text+=". Requests to the bare server IP are almost always bots scanning the internet, not real visitors."
    fi
    alert_text+=$'\n'"• Top paths: $(top_list "$rows" "^${code}\$" 3 path)"
    alert_text+=$'\n'"• Top clients: $(top_list "$rows" "^${code}\$" 2 client)"
    share="$(top_share "$code" 2 "$rows")"
    (( $(count_in "$rows" "$code") >= 20 && share >= 80 )) && \
      alert_text+=". ${share}% came from one client, so this is most likely a single bot or scanner."
    if (( SOURCE_COUNT > 1 )); then
      alert_text+=$'\n'"• Top logs: $(top_list "$rows" "^${code}\$" 4 log)"
    fi
    if [[ "$BOT_FILTER" == true && "$how" == real ]]; then
      ignored="$(ignored_summary "$code")"
      [[ -n "$ignored" ]] && alert_text+=$'\n'"• Not counted, as bots: ${ignored}"
    fi
    if [[ "$code" == 403 && "$FORM_403_CHECK" == true ]] && (( FORM403_COUNT > 0 )); then
      alert_text+=$'\n'"• Refused form POSTs: $(top_list "$FORM403" '^form$' 5 site)"
    fi
  fi
  evaluate "http_${code}" "$triggered" "$alert_text" \
    "HTTP ${label} is back under threshold (${count} to real visitors in ${WINDOW_LABEL}, threshold ${threshold})"
done

# --- refused form POSTs ------------------------------------------------------
# A form POST refused with a 403 means a visitor could not send the form, so a
# single one alerts, per site (same cooldown and recovery as everything else).
# Only while 403 is monitored (FORM403 is empty otherwise). While the 403 alert
# above is firing, the refused forms are listed in it instead, so one block is
# never reported twice.
if [[ "$FORM_403_CHECK" == true && "$HTTP403_OVER" != true ]] && (( SOURCE_COUNT > 0 )); then
  FORM_SITES=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && FORM_SITES+=("$s")
  done < <(cut -f5 "$FORM403" | sort -u)
  for f in "$STATE_DIR"/alert_form403_*; do   # sites alerting last time, so they can recover
    [[ -f "$f" && -f "$f.site" ]] && FORM_SITES+=("$(cat "$f.site")")
  done
  for s in $(printf '%s\n' ${FORM_SITES[@]+"${FORM_SITES[@]}"} | sort -u); do
    count=$(awk -F'\t' -v s="$s" '$5 == s' "$FORM403" | wc -l)
    key="form403_$(state_key "$s")"
    triggered=false
    alert_text=""
    if (( count > 0 )); then
      triggered=true
      alert_text="*Form POSTs refused (403) on ${s}*: ${count} in ${WINDOW_LABEL}, visitors cannot submit the form"
      alert_text+=$'\n'"_Visitors sent a form on this site and were refused, so those submissions did not go through._"
      alert_text+=$'\n'"• Top paths: $(top_list "$FORM403" '^form$' 3 path "$s")"
      alert_text+=$'\n'"• Top clients: $(top_list "$FORM403" '^form$' 2 client "$s")"
      write_state "$STATE_DIR/alert_${key}.site" "$s"
    fi
    evaluate "$key" "$triggered" "$alert_text" "Form POSTs on ${s} are no longer refused (none in ${WINDOW_LABEL})"
    [[ -f "$STATE_DIR/alert_${key}" || "$DRY_RUN" == true ]] || rm -f "$STATE_DIR/alert_${key}.site"
  done
fi

if [[ "$CHECK_KERNEL" == true && -n "$KERNEL_SOURCE_USED" ]]; then
  triggered=false
  alert_text=""
  if (( KERNEL_FAULTS >= KERNEL_FAULT_THRESHOLD )); then
    triggered=true
    alert_text="*\`${KERNEL_FAULT_PROCESS}\` process crashes*: ${KERNEL_FAULTS} in ${WINDOW_LABEL} (threshold ${KERNEL_FAULT_THRESHOLD}): ${SEGFAULTS} segmentation fault(s), ${GPFS} general protection fault(s)"
    if [[ "$KERNEL_FAULT_PROCESS" == php* ]]; then
      alert_text+=$'\n'"_The PHP processes that run the site's code are crashing, usually because of a buggy PHP extension or a memory problem. Visitors may see 502 errors or blank pages._"
    fi
    alert_text+=$'\n'"Kernel log excerpt:"$'\n'"\`\`\`$(head -n 3 "$KERNEL_LINES" | cut -c1-220)\`\`\`"
  fi
  evaluate "kernel_faults" "$triggered" "$alert_text" \
    "\`${KERNEL_FAULT_PROCESS}\` crashes are back under threshold (${KERNEL_FAULTS} in ${WINDOW_LABEL}, threshold ${KERNEL_FAULT_THRESHOLD})"
fi

# A monitor watching nothing should say so rather than stay silently green.
if (( SOURCE_COUNT == 0 )); then
  say "No access logs found (ACCESS_LOGS=\"$ACCESS_LOGS\" DOCKER_CONTAINERS=\"$DOCKER_CONTAINERS\")"
  evaluate "config_no_logs" true \
    "*No access logs found* — nothing matched ACCESS_LOGS=\`${ACCESS_LOGS:-(none)}\` and no container in DOCKER_CONTAINERS=\`${DOCKER_CONTAINERS:-(none)}\` exists, so HTTP errors are NOT being monitored. Fix it in ${ENV_FILE}." \
    ""
else
  evaluate "config_no_logs" false "" "Access logs found again (${SOURCE_COUNT} source(s)) — HTTP error monitoring resumed"
fi

# A configured container that has disappeared (removed, renamed by a compose
# project change) is checked separately, since other sources may still be fine.
for name in $DOCKER_CONTAINERS; do
  missing=false
  for m in ${MISSING_CONTAINERS[@]+"${MISSING_CONTAINERS[@]}"}; do
    [[ "$m" == "$name" ]] && missing=true
  done
  evaluate "docker_missing_$(state_key "$name")" "$missing" \
    "*Container \`${name}\` not found* — its access log is NOT being monitored. If it was renamed, update DOCKER_CONTAINERS in ${ENV_FILE}." \
    "Container \`${name}\` is back — monitoring its access log again"
done

log "Checked ${SOURCE_COUNT} log source(s), ${TOTAL_LINES} lines (${TOTAL_UNPARSED} unparsed); codes (real visitors):${SUMMARY:- none}; ignored as bots:${BOT_SUMMARY:- none}; 403: form=${FORM403_COUNT} clients=${CLIENTS_403}; kernel(${KERNEL_SOURCE_USED:-off}): segfault=${SEGFAULTS} gpf=${GPFS}"

# --- report -----------------------------------------------------------------
# by_client <file> [top] — the clients in a match file, busiest first: count,
# client, codes, a site, what the filter made of it (its most common reason,
# with score and signals) and an example path with its user agent.
by_client() {
  awk -F'\t' '
    {
      c = $2; n[c]++
      if (index("," codes[c] ",", "," $1 ",") == 0) codes[c] = codes[c] (codes[c] != "" ? "," : "") $1
      w = ($7 == "-") ? "" : ($7 == "behaviour" ? "bot-like behaviour, " : $7)
      if ($8 != "-") w = w "score " $8
      if ($9 != "-") w = w " (" $9 ")"
      if (++nw[c, w] > best[c]) { best[c] = nw[c, w]; why[c] = w; site[c] = ($5 != "" ? $5 : "-"); path[c] = $3; ua[c] = $11 }
    }
    END { for (c in n) printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", n[c], c, codes[c], site[c], why[c], path[c], ua[c] }' "$1" \
    | sort -t$'\t' -k1,1rn | head -n "${2:-25}" \
    | awk -F'\t' '{ printf "  %5d  %-15s  %-11s  %-24s  %s\n         e.g. %s  \"%s\"\n", $1, $2, $3, $4, $5, $6, $7 }'
}

# explain — for --explain: what the bot filter made of the errors it read.
explain() {
  local code real clients ignored
  echo
  echo "Bot filter (BOT_FILTER=${BOT_FILTER}): a client scoring ${BOT_SCORE_THRESHOLD} or more (BOT_SCORE_THRESHOLD) is a bot."
  echo "These logs were read from up to 5 MB back, so the counts cover more than 5 minutes."
  for code in $(cut -f1 "$ALL" | sort -u); do
    real="$(count_in "$MATCHES" "$code")"
    clients="$(clients_in "$MATCHES" "$code")"
    ignored="$(ignored_summary "$code")"
    echo "  ${code}: ${real} to real visitors from ${clients} client(s); not counted: ${ignored:-none}"
  done
  echo
  echo "Real visitors who got errors, busiest first (count, client, codes, site, score and signals):"
  if [[ -s "$MATCHES" ]]; then by_client "$MATCHES" "$EXPLAIN_TOP"; else echo "  none"; fi
  echo
  echo "Clients scored as bots, busiest first (count, client, codes, site, reason):"
  if [[ -s "$BOTS" ]]; then by_client "$BOTS" "$EXPLAIN_TOP"; else echo "  none"; fi
  echo
}

if [[ "$DRY_RUN" == true ]]; then
  echo "Log sources (${SOURCE_COUNT}):"
  while IFS=$'\t' read -r src lines unparsed; do
    echo "  $src — $lines lines read, $unparsed without a recognisable status code"
  done < "$STATS"
  echo "Monitored codes (${ERROR_CODES}) seen:${SUMMARY:- none}"
  if [[ ",$(tr -d '[:space:]' <<< "$ERROR_CODES" | tr 'X' 'x')," =~ ,(403|4xx), ]]; then
    echo "403s: ${FORM403_COUNT} refused form POST(s), ${CODE_COUNT[403]:-0} refused visitor request(s) in all from ${CLIENTS_403} client(s) (scanner paths not counted)"
  fi
  if [[ "$BOT_FILTER" == true ]]; then
    echo "Errors scored as bots, not counted:${BOT_SUMMARY:- none} (--explain shows why)"
  fi
  for code in $(printf '%s\n' ${OVER_HOW[@]+"${!OVER_HOW[@]}"} | sort); do
    if [[ "${OVER_HOW[$code]}" == outage ]]; then
      echo "  $code is OVER the outage threshold of $OUTAGE_THRESHOLD (errors on site pages, bots included)"
    else
      echo "  $code is OVER its threshold of $(threshold_for "$code")"
    fi
  done
  if [[ "$CHECK_KERNEL" == true ]]; then
    echo "Kernel (${KERNEL_SOURCE_USED:-no source}): ${SEGFAULTS} ${KERNEL_FAULT_PROCESS} segfault(s), ${GPFS} general protection fault(s) (threshold ${KERNEL_FAULT_THRESHOLD})"
  fi
  [[ "$EXPLAIN" == true ]] && explain
  echo "(dry run — nothing sent to Slack, no state saved)"
  exit 0
fi

if (( ${#ALERTS[@]} > 0 )); then
  msg=":rotating_light: *${SITE_LABEL}*: server error alert"
  for a in "${ALERTS[@]}"; do
    msg+=$'\n\n'"$a"
  done
  if send_slack "$msg" >/dev/null 2>>"$LOG_FILE"; then
    log "Sent alert: ${#ALERTS[@]} condition(s)"
  else
    log "Failed to send Slack alert"
  fi
fi

if (( ${#RECOVERIES[@]} > 0 )); then
  msg=":white_check_mark: *${SITE_LABEL}*: back to normal"
  for r in "${RECOVERIES[@]}"; do
    msg+=$'\n'"• $r"
  done
  if send_slack "$msg" >/dev/null 2>>"$LOG_FILE"; then
    log "Sent recovery: ${#RECOVERIES[@]} condition(s)"
  else
    log "Failed to send Slack recovery message"
  fi
fi

echo "$NOW" > "$LAST_RUN_FILE"
exit 0
