# Dokploy Deployment Troubleshooting Log

Notes from deploying this fork on Dokploy (Docker Compose app, Traefik reverse
proxy, domain fronted by Cloudflare). Kept for whoever redeploys this next.

## 1. Crash loop: `read config.yaml: is a directory`

**Symptom:** container restarts forever, logs show
`failed to read config file: read /CLIProxyAPI/config.yaml: is a directory`.

**Cause:** `docker-compose.yml` bind-mounted a single file
(`./config.yaml:/CLIProxyAPI/config.yaml`). `config.yaml` is gitignored, so on
a fresh clone it doesn't exist on the host. Docker's bind-mount behavior:
if the host source path doesn't exist, it creates a **directory** there
instead of a file. The app then fails to open a directory as YAML.

**Fix:** mount a directory instead of a single file, and let the container
bootstrap the real file inside it (`docker-entrypoint.sh` + `Dockerfile`
`ENTRYPOINT`, `docker-compose.yml` volume `config-data`). The entrypoint
copies `config.example.yaml` into the mounted dir on first boot and symlinks
it to the path the app expects. Directory-to-directory binds don't have this
failure mode, which is why `auths/`, `logs/`, `plugins/` never hit it.

## 2. Fork's own code never ran

**Symptom:** after fixing #1, container started but logs showed
`Version: v7.3.11` (a tagged release) instead of `dev` — i.e. changes made
in this fork weren't taking effect.

**Cause:** `docker-compose.yml` had `pull_policy: always` with
`image: eceasy/cli-proxy-api:latest`. Compose pulled that published image
on every `up`, ignoring the local `build:` section entirely.

**Fix:** `pull_policy: build` — forces Compose to always build from the
local `Dockerfile`, never pull.

## 3. Config and auth files reset on every redeploy

**Symptom:** manual fixes to `config.yaml` (see #4/#5 below) disappeared
after clicking Redeploy in Dokploy.

**Cause:** Dokploy re-clones the git repo into `code/` on every deploy.
Anything living under `./config.yaml`, `./auths/`, etc. (relative to that
directory, which is also the default in `docker-compose.yml`) is wiped and
recreated from scratch each time.

**Fix:** point the compose volumes at paths **outside** the `code/` checkout,
via the existing `CLI_PROXY_CONFIG_DIR` / `CLI_PROXY_AUTH_PATH` env vars
(already read by `docker-compose.yml` with `./config` / `./auths` as
fallback defaults):

- Created `/etc/dokploy/persistent/cli-proxy-api/{config,auths}` on the host.
- Set `CLI_PROXY_CONFIG_DIR` and `CLI_PROXY_AUTH_PATH` to those paths.

Important: this must be set in **Dokploy's Environment tab for the app**,
not by hand-editing the `.env` file over SSH — Dokploy regenerates `.env`
from its own stored variables on every deploy, so a manually-added line
gets silently dropped on the next redeploy.

## 4. Management API returns 404 for everything under `/v0/management`

**Symptom:** `GET /v0/management/config` → `404 page not found`.

**Cause:** `remote-management.secret-key` was empty. Per the app's own
config comment: "Leave empty to disable the Management API entirely
(404 for all `/v0/management` routes)."

**Fix:** set a non-empty `secret-key`.

## 5. Management API returns 403 `remote management disabled`

**Symptom:** after fixing #4, requests through the public domain returned
`{"error":"remote management disabled"}`.

**Cause:** `remote-management.allow-remote` defaults to `false` — only
localhost can use the Management API, and requests through Traefik don't
look like localhost to the app.

**Fix:** set `allow-remote: true` (the `secret-key` is still required on
every request, localhost or not).

## 6. Config edits to `secret-key`/`allow-remote` don't take effect without a restart

**Cause:** the app has a config file watcher for hot-reload, but it only
reloads clients/auth state — HTTP routes (including the whole
`/v0/management/*` group, which is registered conditionally at boot based
on whether a secret key is configured) are wired up once at startup.

**Fix:** `docker restart` (or a fresh container) after changing anything in
the `remote-management` block. A plain file edit is not enough.

## 7. Everything except `/management.html` returns 404 (from Traefik, not the app)

**Symptom:** `/management.html` loads fine (200), but `/healthz`,
`/v1/models`, `/v0/management/*` all 404 — even though hitting the
container directly on its published port works.

**Cause:** the app's Dokploy **Domain** settings had a `Path` field set to
`/management.html`. Dokploy generates the Traefik router rule from that
field, producing `Host(...) && PathPrefix(\`/management.html\`)` instead of
a plain `Host(...)` rule. Traefik then has no router matching any other
path on that host, so it falls back to its own 404 for everything else —
this never reaches the container, so app-side fixes do nothing for it.

**Fix:** clear the `Path` field on the domain in Dokploy so the rule goes
back to `Host(...)` only.

## 8. `MANAGEMENT_PASSWORD` set in Dokploy's env was silently ignored

**Cause:** two gaps stacked:
1. `docker-compose.yml`'s `environment:` block only passed `DEPLOY` through
   to the container — `MANAGEMENT_PASSWORD` from Dokploy's `.env` never
   reached the process.
2. Even if it had, the app reads `secret-key` straight from `config.yaml`
   with no environment-variable support.

**Fix:** pass `MANAGEMENT_PASSWORD` through in `docker-compose.yml`, and
have `docker-entrypoint.sh` write it into the config's `secret-key` field
(via `sed`, escaping `/` and `&`) on every boot, before the app starts and
hashes it in place. This makes the Dokploy env var the source of truth —
change it there and redeploy, no more manual `config.yaml` edits.

## 9. OAuth login (Codex, etc.) redirects to `http://localhost:1455/auth/callback` and fails

**Symptom:** clicking "Start Codex Login" in the management panel, completing
login with the provider, then getting redirected to a `localhost` URL that
the browser can't connect to.

**Cause:** this is expected, not a bug. The OAuth redirect URI is a loopback
address meant for the machine actually running the CLIProxyAPI process. On a
remote deployment, the browser (on your own machine) and the server are not
the same machine, so the redirect can never load — by design, per the
upstream "remote browser mode" flow (see `docs/management-devin-oauth.md`,
which documents the same pattern for Devin and applies generally).

**Fix:** no code change needed. In the OAuth Login page, after the failed
redirect, copy the **full URL** from the browser's address bar (including
`?code=...&state=...`) and paste it into the "Callback URL" field for that
provider, then "Submit Callback URL". This posts to
`/v0/management/oauth-callback` and completes the flow without needing the
loopback port reachable.

## Final working setup

- `pull_policy: build` in `docker-compose.yml` — always builds this fork's
  `Dockerfile`, never pulls the upstream image.
- `docker-entrypoint.sh` bootstraps `config.yaml` into a mounted directory
  and syncs `MANAGEMENT_PASSWORD` into `secret-key` on every boot.
- `CLI_PROXY_CONFIG_DIR` / `CLI_PROXY_AUTH_PATH` env vars (set in Dokploy's
  Environment tab) point at `/etc/dokploy/persistent/cli-proxy-api/*` on the
  host, so config and auth survive redeploys.
- `remote-management.allow-remote: true` in `config.yaml`, with
  `secret-key` driven by the `MANAGEMENT_PASSWORD` env var.
- Domain in Dokploy has no `Path` restriction — Traefik rule is a plain
  `Host(...)`.
