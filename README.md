# Server Error Monitor

Server-level watchdog that posts to Slack when:

- **HTTP errors spike.** Any single monitored status code (default
  `500,502,503,504`) shows up **more than 50 times** in the web server access
  logs since the previous run.
- **php-fpm is crashing.** The kernel log shows **3 or more** php-fpm
  segfaults / general protection faults (combined) since the previous run.

It runs from root's cron every 5 minutes and only counts what's new since
the last run, so "50" means "50 in about five minutes".

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/BeckerMediaNet/server-error-monitor/main/install.sh -o install-server-error-monitor.sh \
  && sudo bash install-server-error-monitor.sh
```

Download-then-run, not `curl | sudo bash`: piping into `sudo` can detach
the controlling terminal depending on the server's sudo config (`use_pty`
and similar), which breaks the interactive prompts.

The download is saved as `install-server-error-monitor.sh` (not
`install.sh`), and `&&` means the installer only runs if the download
succeeded. Without both, a failed download on a server that already has
the gf-submission-monitor would quietly run *its* leftover `install.sh`.

That command:

1. Clones this repo into `/opt/server-error-monitor` (or pulls the latest if
   it's already there).
2. Hands off to `setup.sh`, which asks for:
   - a server label for Slack messages and the Slack webhook URL
   - which access logs to watch. It auto-detects nginx/Apache logs under
     `/var/log/nginx`, `/var/log/apache2` and `/var/log/httpd` (including one
     level of per-site subfolders) and suggests them as wildcards.
   - which status codes to monitor, the threshold, and optional per-code
     thresholds (e.g. `404=300`)
   - whether to watch the kernel log for php-fpm faults, and that threshold
   - the alert cooldown
3. Offers to send a Slack test message.
4. Does a **dry run** over the current logs so you can see they parse
   (lines read, lines without a recognisable status code, counts per code).
5. Runs the real check once to record the starting point.
6. Offers to install the root cron job (`*/5 * * * *`).

Re-running the same command later pulls the latest code and re-runs setup
(it asks before overwriting an existing `.env`).

## How it works

**Access logs**: for each file matched by `ACCESS_LOGS`, the monitor stores
the inode, byte offset and a checksum of the first bytes, then reads only
what was appended since the last run.
- logrotate (rename): the rest of the old file (`access.log.1`) is read,
  then the new file from the start.
- `copytruncate`: detected by the file shrinking or its first bytes
  changing, then read from the start.
- Rotated/compressed copies (`.1`, `.gz`, `-20260101`) are never matched.
  Wildcards are re-expanded every run, so new per-site logs get picked up.
  A log seen for the first time is only baselined; its existing contents
  aren't counted.

The status code is the first 3-digit number after a closing quote
(`"GET / HTTP/1.1" 502 ...`). That matches nginx's default `combined`
format and Apache's `combined`/`common`. A custom format still works if it
keeps that `"request" status` shape. If most lines don't parse, the
monitor logs a warning, and the setup dry run shows it.

`ERROR_CODES` takes exact codes and whole classes: `500,502,503,504`,
`5xx`, `5xx,404,429`. Each code is counted and thresholded separately.
`THRESHOLD_<code>` lines in `.env` override `ERROR_THRESHOLD` for one code.

The alert lists the busiest paths (query strings dropped), client IPs and,
when several logs are watched, which log files the errors came from.

**Kernel log**: it uses the systemd journal (`journalctl -k --since
@<last run>`) when available, otherwise `/var/log/kern.log` or
`/var/log/messages` with the same offset tracking as the access logs. It
matches lines like:

```
php-fpm8.2[1234]: segfault at 0 ip ... error 4 in libphp.so
traps: php-fpm8.2[1234] general protection fault ip:... error:0
```

Set `KERNEL_FAULT_PROCESS` to watch a different process name prefix.
`journalctl -k` only covers the current boot, so faults just before a
reboot are not counted after it.

**Alerting**: all conditions that fire in a run go into one Slack message.
- A condition that stays over threshold re-alerts at most once per
  `ALERT_COOLDOWN_MINUTES` (default 60).
- Once it has been back under for `RECOVERY_RUNS` runs in a row (default 2,
  so ~10 minutes), a single ✅ recovery message is sent.
- If `ACCESS_LOGS` matches nothing, that's alerted too, so the monitor
  never sits silently green while watching nothing.

A lock (`flock`) stops a slow run from overlapping the next cron tick.

## Repo layout

```
install.sh                   one-command entry point (clone/update + hand off to setup.sh)
setup.sh                     interactive configurator (writes .env, tests Slack, dry run, installs cron)
bin/check-server-errors.sh   the actual check, run by root's cron every 5 minutes
.env.example                 reference list of every config value, for manual editing
.gitignore                   keeps .env, state/, logs/ out of git
```

## Requirements per server

- Linux with bash 4+, GNU coreutils (`stat -c`), `awk` (mawk/gawk both fine),
  `curl`, `git`, `cron`; `flock` (util-linux) recommended
- root access (the logs are usually root/adm-readable only)
- A Slack Incoming Webhook URL for the alert channel
  (Slack → your workspace → search "Incoming Webhooks" → add to channel)

## Manual test / re-test

```bash
sudo /opt/server-error-monitor/bin/check-server-errors.sh --test-slack
sudo /opt/server-error-monitor/bin/check-server-errors.sh --dry-run   # counts only, no Slack, no state saved
sudo /opt/server-error-monitor/bin/check-server-errors.sh             # real check, once
tail /opt/server-error-monitor/logs/server-error-monitor.log
```

`--dry-run` reads from the saved positions. For a log with no saved
position yet, it reads the whole current file (whole current boot for the
journal), which is handy for checking the log format parses.

To reset everything (e.g. after changing `ACCESS_LOGS`), delete
`/opt/server-error-monitor/state/`. The next run re-baselines.

## Publishing this repo

Like gf-submission-monitor, this is meant to be **public** on GitHub
(`BeckerMediaNet/server-error-monitor`). Nothing sensitive lives in the
code: the Slack webhook and per-server settings are written to a local
`.env` by `setup.sh` and are `.gitignore`'d. The remote is already
configured in this folder:

```bash
git add .
git commit -m "Server error monitor"
git push -u origin main
```

## Notes / things worth deciding per server

- **404s are noisy.** Bots probing `/wp-login.php`, `/.env` and so on can
  easily produce 50+ 404s in 5 minutes. If you monitor `4xx` or `404`, give
  it its own higher threshold (`THRESHOLD_404=300`).
- **One busy site can mask another**: the thresholds are per code across
  all watched logs combined. The "Logs" line in the alert shows which site
  the errors came from.
- The threshold is per run. If cron is stopped for an hour, the next run
  counts the whole hour's worth of new lines.
