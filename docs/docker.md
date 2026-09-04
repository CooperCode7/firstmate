# Sealed container

Runs firstmate and its crew inside Docker with no access to the host filesystem, host credentials, or any network destination outside a fixed allowlist.
Use it when agents should be able to read and change code without being able to reach anything else on the machine.

## What is sealed

The `firstmate` service sits on an `internal: true` Docker network, so it has no route off the host at all.
Its only path outward is the `proxy` sidecar, which runs Squid with a default-deny allowlist ([`docker/squid.conf`](../docker/squid.conf)).
A destination that is not listed is unreachable, and nothing needs to be named to block it.

Currently allowed: Anthropic (including `claude.com`, which Claude Code signs in against), GitHub, ClickUp, MotherDuck, the DuckDB extension host, Omni (`sternrisk.omniapp.co`), RubyGems, and the npm and Yarn registries.
Everything else is refused.
Each tool the container needs is installed at build time so a normal session never asks for one.
The three package registries are the deliberate runtime exception: a project's dependencies come from its own `Gemfile.lock` and `yarn.lock`, which no image can be built ahead of.

Project code is cloned fresh inside the container.
No host repository is mounted, and the container authenticates to GitHub as itself.

## Ruby and Rails

Ruby 3.3.6 is copied in from the official `ruby:3.3.6-slim-bookworm` image, so the version matches what a Rails project like stern-liability pins and Bundler accepts.
The base image is Node 24 for the same reason: stern-liability's `package.json` declares `"node": "24.x"` and Yarn refuses to install against anything older.
The image also carries the toolchain native gems need (`build-essential`, `pkg-config`, `libpq-dev`, `libyaml-dev`, `libffi-dev`, `libssl-dev`, `zlib1g-dev`, `libgmp-dev`, `libreadline-dev`), PostgreSQL 17's `psql` and `pg_dump`, and the Node base image's own Yarn 1.22.22, the version stern-liability pins.
`GEM_HOME` is `/usr/local/bundle`, owned by the runtime user, so `bundle install` works without elevation.

Two sidecars back the Rails environment, both on the sealed internal network with no route anywhere:

| Service | Reached as | Wired in by |
| --- | --- | --- |
| `postgres` (17-alpine, trust auth, `pgdata` volume) | `PGHOST=postgres`, `PGUSER=postgres` | Rails picks these up for the `development` and `test` databases, which name no host of their own |
| `redis` (7-alpine) | `REDIS_URL=redis://redis:6379/0` | Sidekiq and any direct Redis client |

Postgres 17 is deliberate: stern-liability's `db/structure.sql` is dumped from a version 17 server and sets `transaction_timeout`, which older servers reject outright.
The client tools and `libpq` come from the PostgreSQL project's own apt repository rather than Debian's, whose version 15 refuses that dump.
The database is local and empty on first start; create and migrate it the usual way.
Heroku is unreachable from the sealed network and remains out of bounds, so production data is never a source here.

## Credentials

Every credential arrives as an environment variable and is passed by reference; none is read from the host's `~/.claude`.

| Variable | Purpose |
| --- | --- |
| `GH_TOKEN` | **Required.** A fine-grained token limited to the repositories agents may touch. |
| `ANTHROPIC_API_KEY` | Claude authentication. Leave it empty to sign in interactively instead (see below). |
| `CLICKUP_API_KEY`, `CLICKUP_TEAM_ID` | ClickUp MCP tools and captain notifications. |
| `MOTHERDUCK_TOKEN` | MotherDuck MCP tools. |
| `FM_CLICKUP_TASK` | Task that captain notifications comment on. |
| `FM_CLICKUP_MENTION_USER_ID` | Mentioned on each notification so ClickUp sends alert mail. |
| `OMNI_API_TOKEN`, `OMNI_BASE_URL` | Omni access, for which the allowlist permits `sternrisk.omniapp.co`. |

Scope the GitHub token deliberately: it can push wherever it has reach, so a repository that must never be written should be granted read access or left out entirely.

## Setup

Copy [`.env.example`](../.env.example) to a local `.env` beside `docker-compose.yml` (it is gitignored) and fill it in.
`GH_TOKEN` is the only variable compose requires; the rest are optional and documented in that template.

The build and attach commands, and the daily working loop, live in the [README's quick start](../README.md#quick-start).

### Signing in without an API key

Leave `ANTHROPIC_API_KEY` empty and run `claude` once inside the container.
It prints a URL to open in your own browser and takes the resulting code back, so the headless container needs no browser of its own.
The allowlist already permits the sign-in hosts.

The credentials are written under the container's home directory, which is a named volume, so the sign-in survives restarts and `docker compose up` cycles.
Only `docker compose down -v`, which deletes the volume, requires signing in again.
The guardrail sync deliberately never removes them.

## Host guardrails

`~/.claude` is mounted read-only at `/seed/claude`, and [`docker/entrypoint.sh`](../docker/entrypoint.sh) copies the guardrail material out of it on every start: `CLAUDE.md`, `settings.json`, `settings.local.json`, `keybindings.json`, `agents/`, `skills/`, `hooks/`, and the whole `plugins/` tree, so installed plugins load exactly as they do on the host.
Hooks are synced because a `PreToolUse` guard that exists only on the host would leave the container unprotected where agents hold live tokens, and because `settings.json` references its scripts by path.
Editing any of those on the host and restarting the container propagates the change.

Credentials and session transcripts are never copied.
The mount is read-only, so nothing in the container can write back to the host.
Point `CLAUDE_SEED_DIR` at another directory to seed from somewhere else.

## Captain notifications

Linux has no equivalent of the macOS notification the away-mode alarm uses, so the container reaches the captain through ClickUp instead.
[`bin/fm-clickup-notify.sh`](../bin/fm-clickup-notify.sh) posts a comment on the configured task and mentions the captain so ClickUp sends its email.
The entrypoint wires it in as the away-mode alarm when `FM_CLICKUP_TASK` is set.

```sh
bin/fm-clickup-notify.sh "PR ready for review: <url>"
```

## Verifying the seal

From inside the container:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com   # expect 2xx/4xx from GitHub
curl -sS https://example.com                                        # expect a proxy denial
ls /                                                                # no host paths
gh auth status                                                      # only the scoped token identity
```

A service that should work but does not is usually a host nobody thought to list.
The proxy names it immediately:

```sh
docker compose exec proxy grep DENIED /var/log/squid/access.log | awk '{print $7}' | sort -u
```

If a permitted service fails, read the proxy's request log with `docker compose exec proxy tail -f /var/log/squid/access.log` and add the destination to the allowlist only if it belongs there.

## Clients that ignore the proxy

A few clients open sockets directly and never read `HTTP_PROXY`. In the sealed
network that leaves them with no route at all, since there is no egress and
external names do not resolve. The DuckDB MotherDuck extension is one.

[`docker/proxy-tunnel.py`](../docker/proxy-tunnel.py) fronts those hosts. Each
one is mapped to a loopback address by `extra_hosts` in the compose file, the
tunnel listens there, and every connection is forwarded through the proxy with
an ordinary `CONNECT`. Bytes are relayed untouched, so TLS stays end to end and
nothing is decrypted.

Listing a host grants it nothing. The allowlist still decides: a `CONNECT` the
proxy refuses fails the connection exactly as a direct attempt would, so a
tunneled host that is not in `squid.conf` simply does not work.

To front another host, add an `extra_hosts` entry with an unused `127.0.0.x`
address (avoid `127.0.0.11`, Docker's own resolver), pass the same mapping to
the tunnel in [`docker/entrypoint.sh`](../docker/entrypoint.sh), and make sure
the hostname is allowlisted. MotherDuck needs two, `api.` and `ext.`, the second
serving the implementation extension it downloads on first connect.

The service holds `NET_BIND_SERVICE` for this, and nothing else: binding
loopback ports 80 and 443 as a non-root user. `cap_drop: ALL` still applies to
everything else.

## Limits

Pinned tool versions age: the axi family tracks its latest published release, so a long-lived image eventually reports a version floor at session start and needs a rebuild.
