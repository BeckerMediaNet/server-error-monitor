#!/usr/bin/env bash
#
# fleet-explain.sh — see what the bot filter makes of each server's real
# traffic before relying on it: runs check-server-errors.sh --explain (a dry
# run over the last 5 MB of each access log: nothing sent to Slack, no state
# changed) on many servers over SSH.
#
# Usage:
#   ./fleet-explain.sh servers.txt
#
# servers.txt  one "[user@]host" per line ("# comments" ok), as for
#              fleet-install.sh. A bare host logs in as root; any other user
#              needs passwordless sudo. The servers need the current code
#              first (./fleet-install.sh pulls it).
#
# Prints one line per server with how many errors went to real visitors and
# how many were scored as bots; each server's full report (busiest real and
# bot clients, with the reason for each) is saved under logs/explain-<time>/.
# 8 servers at a time.
#
set -uo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 servers.txt" >&2
  exit 2
fi
SERVERS="$1"
CHECK=/opt/server-error-monitor/bin/check-server-errors.sh
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs/explain-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# explain_one <[user@]host> — prints one summary line; the full report goes to $OUT/<host>.txt
explain_one() {
  local target="$1" host sudo="" result real bots
  [[ "$target" == *@* ]] || target="root@$target"
  host="${target#*@}"
  [[ "$target" == root@* ]] || sudo="sudo -n"
  # shellcheck disable=SC2029 # $CHECK is meant to expand here, on this side
  ssh -o BatchMode=yes -o ConnectTimeout=20 "$target" "$sudo $CHECK --explain" > "$OUT/$host.txt" 2>&1 < /dev/null
  case $? in
    0) if ! grep -q '^Bot filter' "$OUT/$host.txt"; then
         result="FAILED: no bot filter report (old code? run fleet-install.sh first)"
       else
         real="$(sed -n 's/^Monitored codes ([^)]*) seen: *//p' "$OUT/$host.txt")"
         bots="$(sed -n 's/^Errors scored as bots, not counted: *\(.*\) (--explain.*/\1/p' "$OUT/$host.txt")"
         result="real visitors: ${real:-none}   bots: ${bots:-none}"
       fi ;;
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
  explain_one "$target" &
  running=$((running + 1))
  if (( running >= 8 )); then
    wait -n
    running=$((running - 1))
  fi
done < "$SERVERS"
wait
echo "Full report per server: $OUT"
