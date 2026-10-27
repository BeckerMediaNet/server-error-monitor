#!/usr/bin/env bash
#
# install.sh — installer.
#
# On a new server:
#   curl -fsSL https://raw.githubusercontent.com/BeckerMediaNet/server-error-monitor/main/install.sh -o install-server-error-monitor.sh \
#     && sudo bash install-server-error-monitor.sh
#
# Download it first rather than piping straight into `sudo bash` — piping
# into sudo can detach the controlling terminal on some servers (sudo's
# use_pty and similar settings), which breaks the interactive prompts in
# setup.sh even over a normal SSH session. It is saved under a unique name,
# and the two steps are chained with &&, so a failed download can never fall
# through to running some other project's install.sh left in the same folder
# (e.g. the gf-submission-monitor installer).
#
# This clones (or updates) the repo into /opt/server-error-monitor and hands
# off to setup.sh, which asks the configuration questions interactively.
# Running it again pulls the latest code and re-runs setup (it asks before
# overwriting an existing .env).
#
# Override the directory with:
#   sudo SERVER_ERROR_MONITOR_DIR=/opt/some-other-dir bash install-server-error-monitor.sh
#
set -euo pipefail

REPO_URL="${SERVER_ERROR_MONITOR_REPO_URL:-https://github.com/BeckerMediaNet/server-error-monitor.git}"
BRANCH="${SERVER_ERROR_MONITOR_BRANCH:-main}"
TARGET_DIR="${SERVER_ERROR_MONITOR_DIR:-/opt/server-error-monitor}"

if [[ $EUID -ne 0 ]]; then
  echo "Please run this as root (sudo) — it installs into $TARGET_DIR, reads root-only logs and manages root's cron." >&2
  exit 1
fi

for bin in git curl awk crontab; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin is required and was not found on PATH." >&2; exit 1; }
done

if (( BASH_VERSINFO[0] < 4 )); then
  echo "bash 4 or newer is required (found $BASH_VERSION)." >&2
  exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
  echo "Warning: flock (util-linux) was not found — overlapping runs won't be prevented." >&2
fi

if [[ -d "$TARGET_DIR/.git" ]]; then
  echo "Existing install found at $TARGET_DIR — pulling latest..."
  git -C "$TARGET_DIR" pull --ff-only origin "$BRANCH"
else
  echo "Cloning $REPO_URL into $TARGET_DIR..."
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$TARGET_DIR"
fi

chmod +x "$TARGET_DIR/setup.sh" "$TARGET_DIR/bin/check-server-errors.sh"
mkdir -p "$TARGET_DIR/logs" "$TARGET_DIR/state"
chmod 700 "$TARGET_DIR/state"

exec "$TARGET_DIR/setup.sh"
