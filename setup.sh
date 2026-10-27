#!/usr/bin/env bash
#
# setup.sh — interactive configurator for the server error monitor. Run
# directly (from inside the cloned repo) or via install.sh, which clones the
# repo and calls this automatically.
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
CHECK_SCRIPT="$ROOT_DIR/bin/check-server-errors.sh"

no_terminal() {
  echo >&2
  echo "Couldn't read your answer — no usable terminal is attached to this process." >&2
  echo "This happens when the script is piped into bash (stdin is the pipe, not the" >&2
  echo "keyboard), or when running inside something like tmux/screen/a web console" >&2
  echo "that doesn't provide a real controlling terminal." >&2
  echo >&2
  echo "Download it and run it directly instead of piping it in:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/BeckerMediaNet/server-error-monitor/main/install.sh -o install-server-error-monitor.sh \\" >&2
  echo "    && sudo bash install-server-error-monitor.sh" >&2
  exit 1
}

# ask <varname> <prompt> [default]
# Wraps `read` so a real read failure (broken/missing terminal) aborts with
# a clear message instead of silently defaulting or looping forever — only
# an empty ENTER press falls back to the default.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __val
  if ! IFS= read -rp "$__prompt" __val; then
    no_terminal
  fi
  printf -v "$__var" '%s' "${__val:-$__default}"
}

# ask_required <varname> <prompt>
# Like ask, but keeps asking until a non-empty answer is given. A genuine
# read failure still aborts immediately rather than looping.
ask_required() {
  local __var="$1" __prompt="$2" __val=""
  while [[ -z "$__val" ]]; do
    if ! IFS= read -rp "$__prompt" __val; then
      no_terminal
    fi
  done
  printf -v "$__var" '%s' "$__val"
}

# ask_number <varname> <prompt> <default>
# Like ask, but re-asks until the answer is a whole number.
ask_number() {
  local __var="$1" __prompt="$2" __default="$3" __num=""
  while :; do
    ask __num "$__prompt" "$__default"
    [[ "$__num" =~ ^[0-9]+$ ]] && break
    echo "Please enter a whole number." >&2
  done
  printf -v "$__var" '%s' "$__num"
}

# When this script is run via `curl ... | sudo bash`, stdin is the pipe
# carrying the script text itself, not the keyboard. If stdin isn't already
# an interactive terminal, try switching to the real terminal device — but
# only when stdin needs it, so a normal, already-interactive run is left alone.
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
  exec < /dev/tty
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run this as root (sudo) — the monitor reads root-only logs and installs into root's crontab." >&2
  exit 1
fi

# Rotated/compressed copies (access.log.1, access.log.2.gz, access_log-20260101)
# are skipped by the check itself; keep them out of the preview list too.
is_rotated_name() {
  [[ "$1" =~ \.(gz|bz2|xz|zst|zip)$ || "$1" =~ \.[0-9]+$ || "$1" =~ -[0-9]{8}$ ]]
}

# matching_logs <pattern...> — prints the live log files the patterns match.
matching_logs() {
  local pattern f
  shopt -s nullglob
  # shellcheck disable=SC2068 # glob expansion is the point
  for pattern in $@; do
    for f in $pattern; do
      [[ -f "$f" ]] && ! is_rotated_name "$f" && echo "$f"
    done
  done | sort -u
  shopt -u nullglob
}

echo "=================================================================="
echo " Server Error Monitor — setup"
echo " Installing into: $ROOT_DIR"
echo "=================================================================="
echo

if [[ -f "$ENV_FILE" ]]; then
  echo "A .env already exists at $ENV_FILE."
  ask OVERWRITE "Overwrite it with new answers? [y/N]: " "N"
  if [[ ! "$OVERWRITE" =~ ^[Yy] ]]; then
    echo "Keeping existing .env. Re-run with that answer set to 'y' to redo it."
    SKIP_ENV=true
  fi
fi

if [[ "${SKIP_ENV:-false}" != true ]]; then
  ask SITE_LABEL "Server label for Slack messages (e.g. 'Acme Co - web01') [$(hostname)]: " "$(hostname)"
  ask_required SLACK_WEBHOOK_URL "Slack Incoming Webhook URL: "

  # --- Docker containers ---
  DOCKER_CONTAINERS=""
  if command -v docker >/dev/null 2>&1 && [[ -n "$(docker ps -q 2>/dev/null)" ]]; then
    echo
    echo "Docker is running on this server. Sites in containers (nginx-proxy, the"
    echo "official nginx/httpd images, ...) usually log to stdout, so their access"
    echo "logs live in Docker rather than /var/log and are watched by container name."
    echo
    echo "Running containers:"
    docker ps --format '  {{.Names}}   ({{.Image}})'
    CONTAINER_LIST="$(docker ps --format '{{.Names}} {{.Image}}')"
    SUGGESTED="$(awk 'tolower($2) ~ /nginx-proxy|traefik/ { print $1 }' <<< "$CONTAINER_LIST" | paste -sd' ' -)"
    echo
    if [[ -n "$SUGGESTED" ]]; then
      echo "Suggested: $SUGGESTED — the reverse proxy in front of every site. It logs"
      echo "every request, including the 502/503s it returns when a site's container"
      echo "is down. Don't also add the web server containers behind it, or the same"
      echo "request gets counted twice."
    else
      SUGGESTED="$(awk 'tolower($0) ~ /nginx|httpd|apache|openresty/ && tolower($0) !~ /acme|letsencrypt/ { print $1 }' <<< "$CONTAINER_LIST" | paste -sd' ' -)"
      [[ -n "$SUGGESTED" ]] && echo "Suggested (web server containers): $SUGGESTED"
    fi
    while :; do
      ask DOCKER_CONTAINERS "Containers to watch, space-separated ('none' to skip) [${SUGGESTED:-none}]: " "${SUGGESTED:-none}"
      if [[ "$DOCKER_CONTAINERS" == none ]]; then
        DOCKER_CONTAINERS=""
        break
      fi
      BAD=""
      for name in $DOCKER_CONTAINERS; do
        docker inspect "$name" >/dev/null 2>&1 || BAD+=" $name"
      done
      [[ -z "$BAD" ]] && break
      echo "No such container:$BAD" >&2
    done
  fi

  # --- host access logs ---
  echo
  echo "Looking for web server access logs on the host..."
  DETECTED_PATTERNS=()
  for pattern in "/var/log/nginx/*access*log" "/var/log/nginx/*/*access*log" \
                 "/var/log/apache2/*access*log" "/var/log/apache2/*/*access*log" \
                 "/var/log/httpd/*access*log" "/var/log/httpd/*/*access*log"; do
    if [[ -n "$(matching_logs "$pattern")" ]]; then
      DETECTED_PATTERNS+=("$pattern")
    fi
  done

  if (( ${#DETECTED_PATTERNS[@]} > 0 )); then
    DEFAULT_ACCESS_LOGS="${DETECTED_PATTERNS[*]}"
    echo "Found these access logs:"
    matching_logs "$DEFAULT_ACCESS_LOGS" | sed 's/^/  /'
  elif [[ -n "$DOCKER_CONTAINERS" ]]; then
    DEFAULT_ACCESS_LOGS="none"
    echo "None in the usual nginx/Apache locations — fine if the containers above cover every site."
  else
    DEFAULT_ACCESS_LOGS="/var/log/nginx/*access*log"
    echo "No access logs found in the usual nginx/Apache locations — you'll need to enter the path."
  fi
  echo
  echo "Enter host access log paths to watch, space-separated ('none' to skip)."
  echo "Wildcards are fine and are re-checked on every run, so new per-site logs"
  echo "get picked up automatically."
  while :; do
    ask ACCESS_LOGS "Access logs [${DEFAULT_ACCESS_LOGS}]: " "$DEFAULT_ACCESS_LOGS"
    if [[ "$ACCESS_LOGS" == none ]]; then
      ACCESS_LOGS=""
      [[ -n "$DOCKER_CONTAINERS" ]] && break
      echo "No containers were chosen either, so nothing would be monitored — enter at least one log path." >&2
      continue
    fi
    MATCHED="$(matching_logs "$ACCESS_LOGS")"
    if [[ -n "$MATCHED" ]]; then
      echo "That matches $(wc -l <<< "$MATCHED" | tr -d ' ') file(s)."
      break
    fi
    echo "Nothing currently matches '$ACCESS_LOGS'."
    ask KEEP_ANYWAY "Use it anyway (e.g. the log doesn't exist yet)? [y/N]: " "N"
    [[ "$KEEP_ANYWAY" =~ ^[Yy] ]] && break
  done

  # --- HTTP error codes ---
  echo
  echo "Which HTTP status codes should be monitored? Comma-separated exact codes"
  echo "and/or whole classes, e.g. '500,502,503,504' or '5xx,404,429'."
  ask ERROR_CODES "Error codes [500,502,503,504]: " "500,502,503,504"
  ERROR_CODES="$(tr -d '[:space:]' <<< "$ERROR_CODES")"

  ask_number ERROR_THRESHOLD "Alert when a single code is seen MORE than this many times in one 5-minute run [50]: " "50"

  echo
  echo "Optional: different thresholds for specific codes, e.g. '404=300,429=100'."
  THRESHOLD_LINES=""
  while :; do
    ask THRESHOLD_OVERRIDES "Per-code thresholds (blank for none): " ""
    THRESHOLD_OVERRIDES="$(tr -d '[:space:]' <<< "$THRESHOLD_OVERRIDES")"
    THRESHOLD_LINES=""
    valid=true
    IFS=',' read -ra PAIRS <<< "$THRESHOLD_OVERRIDES"
    for pair in ${PAIRS[@]+"${PAIRS[@]}"}; do
      if [[ "$pair" =~ ^([1-5][0-9][0-9])=([0-9]+)$ ]]; then
        THRESHOLD_LINES+="THRESHOLD_${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"$'\n'
      else
        echo "Couldn't understand '$pair' — use code=number, e.g. 404=300." >&2
        valid=false
      fi
    done
    [[ "$valid" == true ]] && break
  done

  # --- kernel faults ---
  echo
  ask KERNEL_ANSWER "Also watch the kernel log for php-fpm segfaults / general protection faults? [Y/n]: " "Y"
  if [[ "$KERNEL_ANSWER" =~ ^[Nn] ]]; then
    CHECK_KERNEL=false
    KERNEL_FAULT_THRESHOLD=3
  else
    CHECK_KERNEL=true
    ask_number KERNEL_FAULT_THRESHOLD "Alert when there are at least this many php-fpm faults since the last run [3]: " "3"
  fi

  echo
  ask_number ALERT_COOLDOWN_MINUTES "Minutes before repeating an alert for a problem that's still ongoing [60]: " "60"

  cat > "$ENV_FILE" <<EOF
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
SITE_LABEL="${SITE_LABEL}"
ACCESS_LOGS="${ACCESS_LOGS}"
DOCKER_CONTAINERS="${DOCKER_CONTAINERS}"
ERROR_CODES=${ERROR_CODES}
ERROR_THRESHOLD=${ERROR_THRESHOLD}
${THRESHOLD_LINES}CHECK_KERNEL=${CHECK_KERNEL}
KERNEL_LOG_SOURCE=auto
KERNEL_FAULT_THRESHOLD=${KERNEL_FAULT_THRESHOLD}
KERNEL_FAULT_PROCESS=php-fpm
ALERT_COOLDOWN_MINUTES=${ALERT_COOLDOWN_MINUTES}
RECOVERY_RUNS=2
TOP_N=5
STATE_DIR=
EOF
  chmod 600 "$ENV_FILE"
  echo
  echo "Wrote $ENV_FILE"
fi

chmod +x "$CHECK_SCRIPT"
mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/state"

echo
ask DO_TEST "Send a Slack test message now? [Y/n]: " "Y"
if [[ ! "${DO_TEST:-Y}" =~ ^[Nn] ]]; then
  "$CHECK_SCRIPT" --env "$ENV_FILE" --test-slack
fi

echo
echo "Dry run against the current logs, to confirm they parse (nothing is sent"
echo "to Slack — the counts below cover up to the last 5 MB of each log, not 5 minutes):"
echo
"$CHECK_SCRIPT" --env "$ENV_FILE" --dry-run

echo
echo "Recording the starting point (from now on only new log lines are counted)..."
if "$CHECK_SCRIPT" --env "$ENV_FILE"; then
  echo "Done. See $ROOT_DIR/logs/server-error-monitor.log for details."
else
  echo "Check reported a problem — review the output above and $ROOT_DIR/logs/server-error-monitor.log before relying on this." >&2
fi

CRON_LINE="*/5 * * * * $CHECK_SCRIPT --env $ENV_FILE >> $ROOT_DIR/logs/cron.log 2>&1"
echo
ask DO_CRON "Install a cron job to run this every 5 minutes as root? [Y/n]: " "Y"
if [[ ! "${DO_CRON:-Y}" =~ ^[Nn] ]]; then
  ( crontab -u root -l 2>/dev/null | grep -vF "$CHECK_SCRIPT" ; echo "$CRON_LINE" ) | crontab -u root -
  echo "Installed cron job for root:"
  echo "  $CRON_LINE"
else
  echo "Skipped. Add it yourself later with:"
  echo "  crontab -u root -e"
  echo "  $CRON_LINE"
fi

echo
echo "Setup complete. Config: $ENV_FILE"
