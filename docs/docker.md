# Sealed container

Runs firstmate and its crew inside Docker with no access to the host filesystem, host credentials, or any network destination outside a fixed allowlist.
Use it when agents should be able to read and change code without being able to reach anything else on the machine.

## What is sealed

The `firstmate` service sits on an `internal: true` Docker network, so it has no route off the host at all.
Its only path outward is the `proxy` sidecar, which runs Squid with a default-deny allowlist ([`docker/squid.conf`](../docker/squid.conf)).
A destination that is not listed is unreachable, and nothing needs to be named to block it.

Currently allowed: Anthropic, GitHub, ClickUp, MotherDuck, and the DuckDB extension host.
Everything else, including every package registry at runtime, is refused.
Each tool the container needs is installed at build time so a normal session never asks for one.

Project code is cloned fresh inside the container.
No host repository is mounted, and the container authenticates to GitHub as itself.

## Credentials

Every credential arrives as an environment variable and is passed by reference; none is read from the host's `~/.claude`.

| Variable | Purpose |
| --- | --- |
| `GH_TOKEN` | **Required.** A fine-grained token limited to the repositories agents may touch. |
| `ANTHROPIC_API_KEY` | Claude authentication. Omit to log in interactively inside the container instead. |
| `CLICKUP_API_KEY`, `CLICKUP_TEAM_ID` | ClickUp MCP tools and captain notifications. |
| `MOTHERDUCK_TOKEN` | MotherDuck MCP tools. |
| `FM_CLICKUP_TASK` | Task that captain notifications comment on. |
| `FM_CLICKUP_MENTION_USER_ID` | Mentioned on each notification so ClickUp sends alert mail. |

Scope the GitHub token deliberately: it can push wherever it has reach, so a repository that must never be written should be granted read access or left out entirely.

## Setup

Put the variables above in a local `.env` beside `docker-compose.yml` (it is gitignored), then:

```sh
docker compose build
docker compose up -d
docker compose exec firstmate tmux attach -t firstmate
```

Inside the session, start firstmate the usual way with `bin/fm-session-start.sh`.

## Host guardrails

`~/.claude` is mounted read-only at `/seed/claude`, and [`docker/entrypoint.sh`](../docker/entrypoint.sh) copies the guardrail material out of it on every start: `CLAUDE.md`, `settings.json`, `settings.local.json`, `keybindings.json`, `agents/`, `skills/`, and the whole `plugins/` tree, so installed plugins load exactly as they do on the host.
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

If a permitted service fails, read the proxy's request log with `docker compose exec proxy tail -f /var/log/squid/access.log` and add the destination to the allowlist only if it belongs there.

## Limits

The container runs the tmux backend; the cmux and orca backends are macOS-only and unavailable.
Pinned tool versions age: the axi family tracks its latest published release, so a long-lived image eventually reports a version floor at session start and needs a rebuild.
