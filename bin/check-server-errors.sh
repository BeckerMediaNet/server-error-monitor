#!/usr/bin/env bash
#
# check-server-errors.sh
#
# Watches the web server access logs for spikes of HTTP error codes and the
# kernel log for php-fpm segfaults / general protection faults, and posts a
# Slack alert via an Incoming Webhook when either crosses its threshold.
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
ACCESS_LOGS="${ACCESS_LOGS:-/var/log/nginx/*access*log /var/log/apache2/*access*log /var/log/httpd/*access*log}"
ERROR_CODES="${ERROR_CODES:-500,502,503,504}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-50}"
CHECK_KERNEL="${CHECK_KERNEL:-true}"
KERNEL_LOG_SOURCE="${KERNEL_LOG_SOURCE:-auto}"
KERNEL_FAULT_THRESHOLD="${KERNEL_FAULT_THRESHOLD:-3}"
KERNEL_FAULT_PROCESS="${KERNEL_FAULT_PROCESS:-php-fpm}"
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
  if send_slack ":white_check_mark: Test message from the server error monitor on *${SITE_LABEL}* ($(hostname)). Slack connection is working."; then
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
MATCHES="$TMP_DIR/matches.tsv"   # code<TAB>client<TAB>path<TAB>logfile, one row per monitored error
STATS="$TMP_DIR/stats"           # logfile<TAB>lines<TAB>unparsed, one row per access log
: > "$MATCHES"
: > "$STATS"

NOW="$(date +%s)"
LAST_RUN="$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")"
if [[ -n "$LAST_RUN" ]] && (( NOW - LAST_RUN < 120 )); then
  WINDOW_LABEL="the last $(( NOW - LAST_RUN ))s"
elif [[ -n "$LAST_RUN" ]]; then
  WINDOW_LABEL="the last $(( (NOW - LAST_RUN + 30) / 60 ))m"
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
# prints the whole current file so you can see what the parser makes of it.
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
      cat "$file"
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
# the first 3-digit number that follows a closing quote. Written for plain
# POSIX awk (mawk on Debian/Ubuntu) — no gawk extensions.
AWK_PARSE='
BEGIN {
  n = split(codes, list, ",")
  for (i = 1; i <= n; i++) {
    c = tolower(list[i]); gsub(/[ \t]/, "", c)
    if (c ~ /^[1-5]xx$/) cls[substr(c, 1, 1)] = 1
    else if (c != "") exact[c] = 1
  }
}
NF == 0 { next }
{
  total++
  if (!match($0, /" [1-5][0-9][0-9] /)) { unparsed++; next }
  code = substr($0, RSTART + 2, 3)
  if (!(code in exact) && !(substr(code, 1, 1) in cls)) next
  q = index($0, "\"")
  req = substr($0, q + 1, RSTART - q - 1)
  split(req, parts, " ")
  path = (parts[2] != "") ? parts[2] : req
  sub(/\?.*/, "", path)
  if (length(path) > 100) path = substr(path, 1, 100) "..."
  print code "\t" $1 "\t" path "\t" src
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
  read_new "$f" | awk -v codes="$ERROR_CODES" -v src="$f" -v stats="$STATS" "$AWK_PARSE" >> "$MATCHES"
done

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

# top_list <code> <column> — "`value` (count), ..." for the busiest values.
top_list() {
  awk -F'\t' -v c="$1" -v col="$2" '$1 == c { print $col }' "$MATCHES" \
    | sort | uniq -c | sort -rn | head -n "$TOP_N" \
    | awk '{ n = $1; $1 = ""; sub(/^ /, ""); printf "%s`%s` (%d)", (NR > 1 ? ", " : ""), $0, n }'
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
(( ${#LOG_FILES[@]} == 0 )) && CODES_TO_EVALUATE=()
for code in $(printf '%s\n' ${CODES_TO_EVALUATE[@]+"${CODES_TO_EVALUATE[@]}"} | sort -u); do
  count="${CODE_COUNT[$code]:-0}"
  threshold="$(threshold_for "$code")"
  SUMMARY+=" ${code}=${count}"
  triggered=false
  alert_text=""
  if (( count > threshold )); then
    triggered=true
    alert_text="*HTTP ${code}*: ${count} in ${WINDOW_LABEL} (threshold ${threshold})"$'\n'"• Top paths: $(top_list "$code" 3)"$'\n'"• Top clients: $(top_list "$code" 2)"
    if (( ${#LOG_FILES[@]} > 1 )); then
      alert_text+=$'\n'"• Logs: $(top_list "$code" 4)"
    fi
  fi
  evaluate "http_${code}" "$triggered" "$alert_text" \
    "HTTP ${code} is back under threshold (${count} in ${WINDOW_LABEL}, threshold ${threshold})"
done

if [[ "$CHECK_KERNEL" == true && -n "$KERNEL_SOURCE_USED" ]]; then
  triggered=false
  alert_text=""
  if (( KERNEL_FAULTS >= KERNEL_FAULT_THRESHOLD )); then
    triggered=true
    alert_text="*${KERNEL_FAULT_PROCESS} crashes*: ${SEGFAULTS} segfault(s) and ${GPFS} general protection fault(s) in ${WINDOW_LABEL} (threshold ${KERNEL_FAULT_THRESHOLD})"$'\n'"\`\`\`$(head -n 3 "$KERNEL_LINES" | cut -c1-220)\`\`\`"
  fi
  evaluate "kernel_faults" "$triggered" "$alert_text" \
    "No more ${KERNEL_FAULT_PROCESS} segfaults/general protection faults over threshold (${KERNEL_FAULTS} in ${WINDOW_LABEL})"
fi

# A monitor watching nothing should say so rather than stay silently green.
if (( ${#LOG_FILES[@]} == 0 )); then
  say "No access logs matched ACCESS_LOGS=\"$ACCESS_LOGS\""
  evaluate "config_no_logs" true \
    "*No access logs found* — nothing matched ACCESS_LOGS=\`${ACCESS_LOGS}\`, so HTTP errors are NOT being monitored. Fix it in ${ENV_FILE}." \
    ""
else
  evaluate "config_no_logs" false "" "Access logs found again (${#LOG_FILES[@]} file(s)) — HTTP error monitoring resumed"
fi

log "Checked ${#LOG_FILES[@]} log(s), ${TOTAL_LINES} lines (${TOTAL_UNPARSED} unparsed); codes:${SUMMARY:- none}; kernel(${KERNEL_SOURCE_USED:-off}): segfault=${SEGFAULTS} gpf=${GPFS}"

# --- report -----------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  echo "Access logs (${#LOG_FILES[@]}):"
  while IFS=$'\t' read -r src lines unparsed; do
    echo "  $src — $lines lines read, $unparsed without a recognisable status code"
  done < "$STATS"
  echo "Monitored codes (${ERROR_CODES}) seen:${SUMMARY:- none}"
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

HOST="$(hostname)"
if (( ${#ALERTS[@]} > 0 )); then
  msg=":rotating_light: *${SITE_LABEL}* (${HOST}): server error monitor"
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
  msg=":white_check_mark: *${SITE_LABEL}* (${HOST}): recovered"
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
