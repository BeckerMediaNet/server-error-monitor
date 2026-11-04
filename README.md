# Server Error Monitor

Server-level watchdog that posts to Slack when:

- **Real visitors get HTTP errors.** Any single monitored status code
  (default `403,500,502,503,504`) went to real visitors **more than 50
  times** since the previous run, from at least 3 of them. Every error is
  scored as bot or real traffic first, so scanners hitting the bare server IP
  or probing for `/.env` never count (see [Bot filter](#bot-filter)). A 403
  only counts when a visitor was refused (see [403s](#403s)).
- **A site is down, whoever noticed.** A 5xx code went to **more than 100**
  requests for normal pages of a named site from 10+ clients, even if most of
  them were bots: at 3am the only clients may be bots, and a 502 for them is
  a 502 for visitors too.
- **A form POST is refused (403).** Any one: a visitor could not send the
  form. Per site. Bots and scanners don't count.
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
   - the site URL for Slack messages (defaults to the DigitalOcean droplet
     name, else the hostname) and the Slack webhook URL
   - which **Docker containers** to watch, if Docker is running. It lists the
     running containers and suggests the reverse proxy (`nginx-proxy`,
     `traefik`) if there is one; see [Docker](#docker) below.
   - which **host access logs** to watch. It auto-detects nginx/Apache logs
     under `/var/log/nginx`, `/var/log/apache2` and `/var/log/httpd`
     (including one level of per-site subfolders) and suggests them as
     wildcards. Enter `none` if everything is in Docker.
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

**On many servers at once**, with no questions: put the servers in a file
(one `[user@]host` per line) and the Slack webhook URL in another, then from
a machine that can SSH to them as root (or a user with passwordless sudo):

```bash
./fleet-install.sh servers.txt webhook.txt
```

Each server runs `install.sh --non-interactive`: access logs and containers
are auto-detected, the Slack label (`SITE_LABEL`) is the DigitalOcean droplet
name (else the hostname) unless you pass `SITE_LABEL=...`, a server with no web access logs or containers is skipped, and a
server that already has an `.env` keeps it and just gets the latest code. The
webhook goes over ssh's stdin, never on a command line. For one server:
`sudo SLACK_WEBHOOK_URL=... bash install-server-error-monitor.sh --non-interactive`
(any other `.env` setting can be given the same way).

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

Each alert gives the code's name, a one-line plain-English explanation of
what it means, and the busiest URLs (query strings dropped) and visitor IPs,
counting only the errors real visitors got. It also says how many errors were
left out as bots, and why. When most of the errors come from one IP, the alert
says it's likely a bot or scanner. The alert also lists the sites, when the
log format includes the hostname (as nginx-proxy's `vhost` format and
Apache's `vhost_combined` do). When several logs are watched, the alert shows
which one the errors came from.

Example:

```
🚨 aai.edu: server error alert

HTTP 503 Service Unavailable: 60 to real visitors in the last 5 minutes from 6 clients (threshold 50)
The server turned these requests away: it was overloaded or in maintenance mode, or no site is set up for the address that was requested.
• Top sites: `aai.edu` (60)
• Top paths: `/programs/` (60)
• Top clients: `203.0.113.61` (10), `203.0.113.62` (10), `203.0.113.63` (10), `203.0.113.64` (10), `203.0.113.65` (10) and 1 other client
• Not counted, as bots: 89 (80 to the bare server IP, 9 from clients that behaved like bots)
```

## Bot filter

Before any threshold is checked, every monitored error is scored as **bot**
or **real** traffic, and only real visitors' errors count. The log line is
all there is to go on, so this looks at what each request asked for and at
what its client (IP address) did across everything it requested since the
last run, errors and successes alike.

**Always a bot**, whatever else the client did:

| Reason | What it means |
|---|---|
| `bare-ip` | sent to the server's IP address, not a site name (needs the hostname in the log, see above) |
| `probe` | a path no visitor asks for: dot files (`/.env`, `/.git/`), backups and config files (`.sql`, `.zip`, `.yml`, `.toml`, a `.json` at the web root), `.php` files other than WordPress's own (`xmlrpc.php` included), `/vendor/`, `/cgi-bin/`, phpMyAdmin, and the files scanners read WordPress and plugin versions from (`readme.html`, `readme.txt`, `license.txt`) |
| `bad-request` | no proper `METHOD /path HTTP/x` request line (TLS sent to port 80, `-`, an unknown method) |
| `no-agent` | no User-Agent |
| `tool-agent` | a script or scan tool: curl, wget, python, Go, Java, zgrab, nuclei, wpscan, headless browsers, ... |
| `bot-agent` | an agent that says it's a bot (`bot/`, `crawl`, `spider`, a URL in it) |
| `crawler` | a search engine (Googlebot, Bingbot, ...): it matters for SEO, but it isn't a visitor |

**Everyone else gets a score**; 3 or more (`BOT_SCORE_THRESHOLD`) is a bot:

| Signal | Points | Why |
|---|---|---|
| `probed` | +3 | the same client also asked for a probe path |
| `enumeration` | +4 | errors on 8+ different paths and under 20% of its requests answered OK: working through a list. Enough that a faked same-site Referer doesn't cancel it out |
| `not-a-browser` | +2 | the agent isn't a browser's `Mozilla/...` string |
| `old-browser` | +2 | Chrome or Firefox older than 100, or Internet Explorer: bots copy old strings, browsers update themselves |
| `head-request` | +2 | `HEAD`: browsers never send one |
| `http1.0` | +2 | `HTTP/1.0`: browsers never send one |
| `all-failed` | +1 | not one of its requests was answered OK |
| `loads-assets` | −3 | loaded 3+ css/js/font/image files: a browser drawing the page |
| `same-site-referer` | −2 | came from one of the site's own pages |

A visitor caught in an outage gets nothing but errors and loads no assets
(`all-failed`, +1), so still counts as real. Not loading assets never counts
against a client: behind a CDN those requests never reach this log.

**Outages still alert when only bots noticed.** For 5xx codes, normal pages of
named sites (bare-IP, probe and malformed requests left out) that got more
than `OUTAGE_THRESHOLD` (100) errors from at least `OUTAGE_MIN_CLIENTS` (10)
clients alert even when most of those clients are bots. `OUTAGE_THRESHOLD=0`
turns this off.

**See what it makes of a server's traffic** before trusting it:

```bash
sudo /opt/server-error-monitor/bin/check-server-errors.sh --explain
./fleet-explain.sh servers.txt          # the same on many servers, one line each
```

`--explain` is a dry run over the last 5 MB of each log (nothing sent, no
state saved). It lists the errors per code split into real and bot, then the
busiest real and bot clients with the reason or score for each. Once a few
servers look right, `ERROR_THRESHOLD` can probably come down from 50, since
the bot noise it was set against is gone.

Every run's log line also records the ignored counts (`ignored as bots:
503=81`). `BOT_FILTER=false` counts every error again, as before the filter
(the 403 rules below still apply).

Limits: with plain `combined` logs (no hostname) `bare-ip` can't be told, so
those scanners are caught by their behaviour instead. Behind Cloudflare or a
load balancer, the client is the visitor only if nginx is set up to log the
real IP; otherwise every visitor looks like one client.

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

## 403s

403 is in the default `ERROR_CODES`, but unlike the other codes only 403s that
refused a visitor are counted. Each one is sorted:

- **Refused form POST**: a `POST` from a browser (`Mozilla/` agent, not one
  that names itself a bot: `compatible;`, a `+http` link, `headless`) that
  carried the page it came from (`Referer`), to `admin-ajax.php`, a form
  plugin's REST route (Gravity Forms, Contact Form 7, WPForms, Formidable,
  Ninja Forms, Forminator) or a page. One is enough to alert, per site, with
  the usual cooldown and recovery. A bot or scanner POST carries no Referer:
  on 10/29, across 13 servers, every real refused form POST had one and no bot
  did. WordPress answering `admin-ajax.php` with its 2-byte `-1`/`0` (a stale
  nonce on a cached page) is not a block and is left out.
- **Visitor refused**: any other 403 on a path a visitor could ask for.
- **Not counted at all**: scanner paths, where bots get refused all day: dot
  files (`/.env`, `/.git/`), `.php` files other than `index.php`,
  `wp-login.php`, `xmlrpc.php`, `/wp-admin/`, backups and archives, and POSTs
  with no Referer.

The counted 403s (form POSTs and visitors) then go through the
[bot filter](#bot-filter) and alert like any other code, above
`THRESHOLD_403` (default `ERROR_THRESHOLD`, 50) from at least
`MIN_CLIENTS_403` (default `MIN_REAL_CLIENTS`, 3) different clients, so one
bot hammering a page doesn't. While that alert is firing, any refused form POSTs are listed in it
instead of alerting separately, so one block is never reported twice.

To stop monitoring 403s, refused form POSTs included, remove `403` from
`ERROR_CODES`. `FORM_403_CHECK=false` keeps the count but drops the
single-form alert. Servers installed before 403 monitoring have
`ERROR_CODES=500,502,503,504` in their `.env`; re-running the installer (or
`fleet-install.sh`) adds 403 to exactly that list and leaves any other list
alone. With Docker, watch the proxy (below): it is the one that logs the 403s
its sites answer.

## Docker

Containers built on nginx-proxy or the official `nginx`/`httpd` images log
requests to **stdout**, so their access logs exist only in Docker's
per-container log, not under `/var/log`. List them by name in
`DOCKER_CONTAINERS`.

- **With Docker's default `json-file` log driver**, the monitor reads the
  container's log file (`docker inspect -f '{{.LogPath}}'`) directly, with
  the same position tracking as host logs. That stays cheap even for a
  proxy with months of unrotated logs; `docker logs --since` would rescan
  the whole file every 5 minutes. Only stdout is read (access log). stderr
  (error log) is ignored.
- **If the container is recreated** (new container ID, e.g. after
  `docker compose up` pulls a new image), its new log is read from the
  start.
- **Other log drivers** (`local`, `journald`, ...) fall back to
  `docker logs --since <last run>`.
- **If a listed container disappears** (removed, or renamed by a compose
  project change), that's alerted, and a recovery is sent when it's back.

**Watch the front proxy only.** On a server like this:

```
NAMES                     IMAGE
aai_production_httpd      f866a0531752
aai_production_php        aai-production-wordpress
production-mysql          mysql:8.0
nginx-proxy-letsencrypt   nginxproxy/acme-companion
nginx-proxy               jwilder/nginx-proxy
```

set `DOCKER_CONTAINERS=nginx-proxy`. The proxy sees every request for
every site, and it's the only place the 502/503s show up when a site's
`httpd` or `php` container is down or unhealthy. Adding
`aai_production_httpd` as well would count each request twice and halve
the effective threshold. The alert's "Top sites" line shows which site
the errors are for.

php-fpm crashes inside containers need nothing extra: containers share the
host kernel, so their segfaults land in the host's kernel log.

## Repo layout

```
install.sh                   one-command entry point (clone/update + hand off to setup.sh)
fleet-install.sh             install/update on many servers over SSH, no questions
fleet-explain.sh             what the bot filter makes of each server's traffic (--explain over SSH)
test/run.sh                  the checks against crafted log lines, in a throwaway container (needs docker)
setup.sh                     interactive configurator (writes .env, tests Slack, dry run, installs cron)
bin/check-server-errors.sh   the actual check, run by root's cron every 5 minutes
.env.example                 reference list of every config value, for manual editing
.gitignore                   keeps .env, state/, logs/ out of git
```

## Requirements per server

- Linux with bash 4+, GNU coreutils (`stat -c`), `awk` (mawk/gawk both fine),
  `curl`, `git`, `cron`; `flock` (util-linux) recommended
- for container logs: `docker` on root's PATH
- root access (the logs are usually root/adm-readable only)
- A Slack Incoming Webhook URL for the alert channel
  (Slack → your workspace → search "Incoming Webhooks" → add to channel)

## Manual test / re-test

```bash
sudo /opt/server-error-monitor/bin/check-server-errors.sh --test-slack
sudo /opt/server-error-monitor/bin/check-server-errors.sh --dry-run   # counts only, no Slack, no state saved
sudo /opt/server-error-monitor/bin/check-server-errors.sh --explain   # dry run over the last 5 MB: bot vs real, and why
sudo /opt/server-error-monitor/bin/check-server-errors.sh             # real check, once
tail /opt/server-error-monitor/logs/server-error-monitor.log
```

`--dry-run` reads from the saved positions. For a log with no saved
position yet, it reads the last 5 MB of the file (the current boot for the
journal), which is handy for checking the log format parses.

Automated: `test/run.sh` runs the checks (403 form POSTs, visitor 403s, the
existing HTTP error alert, the bot filter and outage check, `--explain`,
cooldown/recovery, `setup.sh --non-interactive`)
against crafted log lines in a throwaway Debian container with a fake Slack.

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

- **404s are noisy.** The bot filter drops the scanners probing `/.env` and
  the like, but real visitors following broken links still add up. If you
  monitor `4xx` or `404`, give it its own higher threshold
  (`THRESHOLD_404=300`).
- **One busy site can mask another**: the thresholds are per code across
  all watched logs combined. The "Top sites" / "Top logs" lines in the alert
  show where the errors came from.
- The threshold is per run. If cron is stopped for an hour, the next run
  counts the whole hour's worth of new lines.
