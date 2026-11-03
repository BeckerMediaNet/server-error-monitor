#!/usr/bin/env bash
#
# check-server-errors.sh
#
# Watches the web server access logs (host log files and/or the stdout logs
# of Docker containers) for spikes of HTTP error codes and the kernel log for
# php-fpm segfaults / general protection faults, and posts a Slack alert via
# an Incoming Webhook when either crosses its threshold.
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
#   ./check-server-errors.sh --env /path/.env # use a specific .env file
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
TEST_SLACK=false
DRY_RUN=false

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
ERROR_CODES="${ERROR_CODES:-500,502,503,504}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-50}"
CHECK_KERNEL="${CHECK_KERNEL:-true}"
KERNEL_LOG_SOURCE="${KERNEL_LOG_SOURCE:-auto}"
KERNEL_FAULT_THRESHOLD="${KERNEL_FAULT_THRESHOLD:-3}"
KERNEL_FAULT_PROCESS="${KERNEL_FAULT_PROCESS:-php-fpm}"
FORM_403_CHECK="${FORM_403_CHECK:-true}"
SPIKE_403_THRESHOLD="${SPIKE_403_THRESHOLD:-50}"
SPIKE_403_MIN_CLIENTS="${SPIKE_403_MIN_CLIENTS:-3}"
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
MATCHES="$TMP_DIR/matches.tsv"   # code<TAB>client<TAB>path<TAB>source<TAB>site, one row per monitored error
STATS="$TMP_DIR/stats"           # source<TAB>lines<TAB>unparsed, one row per log source
FORM403="$TMP_DIR/403.tsv"       # form|visit<TAB>client<TAB>path<TAB>source<TAB>site, one row per sorted 403
: > "$MATCHES"
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
# prints the last 5 MB so you can see what the parser makes of it.
read_new() {
  local file="$1" offset_file inode size old_inode="" old_offset="" old_head="" old_head_len=0 rotated head_len
  offset_file="$STATE_DIR/offset_$(state_key "$file")"

  if [[ ! -r "$file" ]]; then
    say "Cannot read $file — skipping (run as root?)"
    return 0
  fi
  read -r inode size < <(stat -c '%i %s' "$file" 2>/dev/null) || return 0
  [[ -f "$offset_file" ]] && read -r old_inode old_offset old_head old_head_len < "$offset_file"

  if [[ -z "$old_offset" ]]; then
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
# Every 403 is also sorted into the 403 file (f403), whatever ERROR_CODES says:
#   form   a visitor's form POST was refused: a POST from a browser that carried
#          the page it came from (Referer) to admin-ajax.php, a form plugin's REST
#          route, or a page. Bots and scanners send no Referer (checked against
#          13 servers' logs, 10/29: every real refused form POST had one, no bot
#          did). WordPress's own 2-byte "-1"/"0" reply on admin-ajax.php is a stale
#          nonce on a cached page, not a block, and is left out.
#   visit  any other 403 on a path a visitor could ask for: counts toward the 403
#          spike. Scanner paths (dot files, .php other than index.php, wp-login,
#          xmlrpc, wp-admin, backups) never count: bots get refused there all day.
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
  watched = (code in exact) || (substr(code, 1, 1) in cls)
  if (!watched && code != "403") next
  after = substr($0, RSTART + RLENGTH)
  q = index($0, "\"")
  req = substr($0, q + 1, RSTART - q - 1)
  split(req, parts, " ")
  url = (parts[2] != "") ? parts[2] : req
  path = url
  sub(/\?.*/, "", path)
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
  if (code == "403" && f403 != "") {
    ref = ""; ua = ""; rest = after; nq = 0
    while (match(rest, /"[^"]*"/)) {
      nq++
      if (nq == 1) ref = substr(rest, RSTART + 1, RLENGTH - 2)
      else { ua = substr(rest, RSTART + 1, RLENGTH - 2); break }
      rest = substr(rest, RSTART + RLENGTH)
    }
    k = kind403(parts[1], url, after, ua, ref)
    if (k != "") print k "\t" client "\t" path "\t" src "\t" site >> f403
  }
  if (watched) print code "\t" client "\t" path "\t" src "\t" site
}
END { print src "\t" (total + 0) "\t" (unparsed + 0) >> stats }
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
  read_new "$f" | awk -v codes="$ERROR_CODES" -v src="$f" -v stats="$STATS" -v f403="$FORM403" "$AWK_PARSE" >> "$MATCHES"
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
    if [[ -n "$since" ]]; then
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
    read_container "$name" | awk -v codes="$ERROR_CODES" -v src="docker:$name" -v stats="$STATS" -v f403="$FORM403" "$AWK_PARSE" >> "$MATCHES"
  else
    say "Container $name not found"
    MISSING_CONTAINERS+=("$name")
  fi
done
SOURCE_COUNT=$(( ${#LOG_FILES[@]} + ${#CONTAINERS[@]} ))

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

# top_list <code> <column> <noun> — "`value` (count), ... and N other <noun>s"
# for the busiest values. A bare IPv4 address in the site column is flagged,
# since it means the request didn't name a site at all.
top_list() {
  awk -F'\t' -v c="$1" -v col="$2" '$1 == c && $col != "" { print $col }' "$MATCHES" \
    | sort | uniq -c | sort -rn \
    | awk -v top="$TOP_N" -v noun="$3" -v site_col="$([[ $2 == 5 ]] && echo 1 || echo 0)" '
        NR <= top {
          n = $1; $1 = ""; sub(/^ /, "")
          note = (site_col && $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ? ", the server IP, not a site name" : ""
          printf "%s`%s` (%d%s)", (NR > 1 ? ", " : ""), $0, n, note
        }
        END { if (NR > top) printf " and %d other %s%s", NR - top, noun, (NR - top == 1 ? "" : "s") }'
}

# top_share <code> <column> — percentage of a code's matches that come from
# its single most common value.
top_share() {
  awk -F'\t' -v c="$1" -v col="$2" '
    $1 == c { t++; if ($col != "" && ++n[$col] > m) m = n[$col] }
    END { print (t ? int(m * 100 / t) : 0) }' "$MATCHES"
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

# Any code that's over threshold now, or was alerting last time (so it can recover).
CODES_TO_EVALUATE=(${CODE_COUNT[@]+"${!CODE_COUNT[@]}"})
for f in "$STATE_DIR"/alert_http_*; do
  [[ -f "$f" ]] && CODES_TO_EVALUATE+=("${f##*alert_http_}")
done

SUMMARY=""
(( SOURCE_COUNT == 0 )) && CODES_TO_EVALUATE=()
for code in $(printf '%s\n' ${CODES_TO_EVALUATE[@]+"${CODES_TO_EVALUATE[@]}"} | sort -u); do
  count="${CODE_COUNT[$code]:-0}"
  threshold="$(threshold_for "$code")"
  SUMMARY+=" ${code}=${count}"
  label="${code} $(code_name "$code")"
  label="${label% }"
  triggered=false
  alert_text=""
  if (( count > threshold )); then
    triggered=true
    alert_text="*${label}*: ${count} responses in ${WINDOW_LABEL} (alerts above ${threshold})"
    meaning="$(code_meaning "$code")"
    [[ -n "$meaning" ]] && alert_text+=$'\n'"_${meaning}_"
    sites="$(top_list "$code" 5 site)"
    if [[ -n "$sites" ]]; then
      alert_text+=$'\n'"• Sites affected: ${sites}"
      [[ "$sites" == *"the server IP, not a site name"* ]] && \
        alert_text+=". Requests to the bare server IP are almost always bots scanning the internet, not real visitors."
    fi
    alert_text+=$'\n'"• Most-requested URLs: $(top_list "$code" 3 URL)"
    alert_text+=$'\n'"• Visitor IP addresses: $(top_list "$code" 2 IP)"
    share="$(top_share "$code" 2)"
    (( count >= 20 && share >= 80 )) && \
      alert_text+=". ${share}% came from one IP, so this is most likely a single bot or scanner."
    if (( SOURCE_COUNT > 1 )); then
      alert_text+=$'\n'"• Found in logs: $(top_list "$code" 4 log)"
    fi
  fi
  evaluate "http_${code}" "$triggered" "$alert_text" \
    "${label} responses are back under the alert level (${count} in ${WINDOW_LABEL}, alerts above ${threshold})"
done

# --- 403 checks -------------------------------------------------------------
# A form POST refused with a 403 means a visitor could not send the form, so a
# single one alerts, per site (same cooldown and recovery as everything else).
# A spike of 403s on paths visitors ask for (scanner paths never count) from
# several clients means a firewall or block rule is turning people away.
# top_403 <kind regex> <column> [site] — like top_list, over the 403 file.
top_403() {
  awk -F'\t' -v k="$1" -v col="$2" -v s="${3:-}" \
    '$1 ~ k && (s == "" || ($5 != "" ? $5 : $4) == s) && $col != "" { print $col }' "$FORM403" \
    | sort | uniq -c | sort -rn | head -n "$TOP_N" \
    | awk '{ n = $1; $1 = ""; sub(/^ /, ""); printf "%s`%s` (%d)", (NR > 1 ? ", " : ""), $0, n }'
}
FORM403_COUNT=$(awk -F'\t' '$1 == "form"' "$FORM403" | wc -l)
REFUSED_COUNT=$(awk -F'\t' '$1 == "form" || $1 == "visit"' "$FORM403" | wc -l)
REFUSED_CLIENTS=$(awk -F'\t' '$1 == "form" || $1 == "visit" { print $2 }' "$FORM403" | sort -u | wc -l)
if [[ "$FORM_403_CHECK" == true ]] && (( SOURCE_COUNT > 0 )); then
  FORM_SITES=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && FORM_SITES+=("$s")
  done < <(awk -F'\t' '$1 == "form" { print ($5 != "" ? $5 : $4) }' "$FORM403" | sort -u)
  for f in "$STATE_DIR"/alert_form403_*; do   # sites alerting last time, so they can recover
    [[ -f "$f" && -f "$f.site" ]] && FORM_SITES+=("$(cat "$f.site")")
  done
  for s in $(printf '%s\n' ${FORM_SITES[@]+"${FORM_SITES[@]}"} | sort -u); do
    count=$(awk -F'\t' -v s="$s" '$1 == "form" && ($5 != "" ? $5 : $4) == s' "$FORM403" | wc -l)
    key="form403_$(state_key "$s")"
    triggered=false
    alert_text=""
    if (( count > 0 )); then
      triggered=true
      alert_text="*Form POSTs refused (403) on ${s}*: ${count} in ${WINDOW_LABEL}, visitors cannot submit the form"
      alert_text+=$'\n'"• Top paths: $(top_403 '^form$' 3 "$s")"$'\n'"• Top clients: $(top_403 '^form$' 2 "$s")"
      write_state "$STATE_DIR/alert_${key}.site" "$s"
    fi
    evaluate "$key" "$triggered" "$alert_text" "Form POSTs on ${s} are no longer refused (none in ${WINDOW_LABEL})"
    [[ -f "$STATE_DIR/alert_${key}" || "$DRY_RUN" == true ]] || rm -f "$STATE_DIR/alert_${key}.site"
  done
fi
if (( SPIKE_403_THRESHOLD > 0 && SOURCE_COUNT > 0 )); then
  triggered=false
  alert_text=""
  if (( REFUSED_COUNT > SPIKE_403_THRESHOLD && REFUSED_CLIENTS >= SPIKE_403_MIN_CLIENTS )); then
    triggered=true
    alert_text="*HTTP 403 refusing visitors*: ${REFUSED_COUNT} in ${WINDOW_LABEL} from ${REFUSED_CLIENTS} clients (threshold ${SPIKE_403_THRESHOLD}; scanner paths not counted)"
    sites="$(top_403 '^(form|visit)$' 5)"
    [[ -n "$sites" ]] && alert_text+=$'\n'"• Top sites: ${sites}"
    alert_text+=$'\n'"• Top paths: $(top_403 '^(form|visit)$' 3)"$'\n'"• Top clients: $(top_403 '^(form|visit)$' 2)"
  fi
  evaluate "spike403_visitors" "$triggered" "$alert_text" \
    "403s refusing visitors are back under threshold (${REFUSED_COUNT} in ${WINDOW_LABEL}, threshold ${SPIKE_403_THRESHOLD})"
fi

if [[ "$CHECK_KERNEL" == true && -n "$KERNEL_SOURCE_USED" ]]; then
  triggered=false
  alert_text=""
  if (( KERNEL_FAULTS >= KERNEL_FAULT_THRESHOLD )); then
    triggered=true
    alert_text="*\`${KERNEL_FAULT_PROCESS}\` process crashes*: ${KERNEL_FAULTS} in ${WINDOW_LABEL} (alerts at ${KERNEL_FAULT_THRESHOLD} or more): ${SEGFAULTS} segmentation fault(s), ${GPFS} general protection fault(s)"
    if [[ "$KERNEL_FAULT_PROCESS" == php* ]]; then
      alert_text+=$'\n'"_The PHP processes that run the site's code are crashing, usually because of a buggy PHP extension or a memory problem. Visitors may see 502 errors or blank pages._"
    fi
    alert_text+=$'\n'"Kernel log excerpt:"$'\n'"\`\`\`$(head -n 3 "$KERNEL_LINES" | cut -c1-220)\`\`\`"
  fi
  evaluate "kernel_faults" "$triggered" "$alert_text" \
    "\`${KERNEL_FAULT_PROCESS}\` crashes are back under the alert level (${KERNEL_FAULTS} in ${WINDOW_LABEL})"
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

log "Checked ${SOURCE_COUNT} log source(s), ${TOTAL_LINES} lines (${TOTAL_UNPARSED} unparsed); codes:${SUMMARY:- none}; 403: form=${FORM403_COUNT} visitors=${REFUSED_COUNT} from ${REFUSED_CLIENTS}; kernel(${KERNEL_SOURCE_USED:-off}): segfault=${SEGFAULTS} gpf=${GPFS}"

# --- report -----------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  echo "Log sources (${SOURCE_COUNT}):"
  while IFS=$'\t' read -r src lines unparsed; do
    echo "  $src — $lines lines read, $unparsed without a recognisable status code"
  done < "$STATS"
  echo "Monitored codes (${ERROR_CODES}) seen:${SUMMARY:- none}"
  echo "403s: ${FORM403_COUNT} refused form POST(s), ${REFUSED_COUNT} refused visitor request(s) from ${REFUSED_CLIENTS} client(s) (spike threshold ${SPIKE_403_THRESHOLD}, scanner paths not counted)"
  for code in $(printf '%s\n' ${CODE_COUNT[@]+"${!CODE_COUNT[@]}"} | sort); do
    threshold="$(threshold_for "$code")"
    (( CODE_COUNT[$code] > threshold )) && echo "  $code is OVER its threshold of $threshold"
  done
  if [[ "$CHECK_KERNEL" == true ]]; then
    echo "Kernel (${KERNEL_SOURCE_USED:-no source}): ${SEGFAULTS} ${KERNEL_FAULT_PROCESS} segfault(s), ${GPFS} general protection fault(s) (threshold ${KERNEL_FAULT_THRESHOLD})"
  fi
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
