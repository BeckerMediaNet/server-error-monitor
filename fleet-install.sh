#!/usr/bin/env bash
#
# fleet-install.sh — install or update the monitor on many servers at once,
# over SSH, with no questions (setup.sh --non-interactive on each server).
#
# Usage:
#   ./fleet-install.sh servers.txt webhook.txt
#
# servers.txt  one "[user@]host" per line ("# comments" ok). A bare host logs
#              in as root; any other user needs passwordless sudo.
# webhook.txt  the Slack Incoming Webhook URL on one line. It reaches each
#              server on ssh's stdin, never on a command line (where `ps` or
#              shell history would show it).
#
# Each server downloads install.sh from GitHub and runs it. A new server gets
# an .env with its access logs and containers auto-detected and its droplet
# name as the label; a server with no web access logs or containers (a
# database box) is skipped; one that already has the monitor keeps its .env
# and gets the latest code. 8 servers at a time; each server's output is saved
# under logs/fleet-<time>/ here.
#
set -uo pipefail

if [[ $# -ne 2 || ! -f "$1" || ! -f "$2" ]]; then
  echo "Usage: $0 servers.txt webhook.txt" >&2
  exit 2
fi
SERVERS="$1"
WEBHOOK_FILE="$2"
grep -q '^https://hooks.slack.com/' "$WEBHOOK_FILE" || { echo "$WEBHOOK_FILE does not hold a Slack webhook URL." >&2; exit 2; }

RAW="${SERVER_ERROR_MONITOR_RAW:-https://raw.githubusercontent.com/BeckerMediaNet/server-error-monitor/main/install.sh}"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs/fleet-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# install_one <[user@]host> — prints one summary line; the full output goes to $OUT/<host>.txt
install_one() {
  local target="$1" host sudo="" result
  [[ "$target" == *@* ]] || target="root@$target"
  host="${target#*@}"
  [[ "$target" == root@* ]] || sudo="sudo -n"
  # shellcheck disable=SC2029 # $RAW is meant to expand here, on this side
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$target" \
    "$sudo bash -c 'read -r SLACK_WEBHOOK_URL; export SLACK_WEBHOOK_URL; cd /root \
      && curl -fsSL $RAW -o install-server-error-monitor.sh \
      && bash install-server-error-monitor.sh --non-interactive'" < "$WEBHOOK_FILE" > "$OUT/$host.txt" 2>&1
  case $? in
    0) if grep -q 'Nothing to monitor here' "$OUT/$host.txt"; then result="skipped (no web access logs or containers)"
       elif grep -q 'Keeping existing .env' "$OUT/$host.txt"; then result="updated (kept its .env)"
       else result="installed"; fi ;;
    255) result="FAILED: could not connect" ;;
    *) result="FAILED: see $OUT/$host.txt" ;;
  esac
  printf '%-18s %s\n' "$host" "$result"
}

running=0
while read -r line; do
  line="${line%%#*}"
  read -r target _ <<< "$line"
  [[ -z "${target:-}" ]] && continue
  install_one "$target" &
  running=$((running + 1))
  if (( running >= 8 )); then
    wait -n
    running=$((running - 1))
  fi
done < "$SERVERS"
wait
echo "Full output per server: $OUT"
