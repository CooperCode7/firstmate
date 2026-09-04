<h1 align="center">firstmate</h1>
<p align="center">
  <a href="https://img.shields.io/badge/runs-Docker%20only-blue?style=flat-square"
    ><img
      alt="Runs in Docker"
      src="https://img.shields.io/badge/runs-Docker%20only-blue?style=flat-square"
  /></a>
  <a href="docker/squid.conf"
    ><img
      alt="Egress"
      src="https://img.shields.io/badge/egress-default--deny-critical?style=flat-square"
  /></a>
  <a href="https://github.com/kunchenguid/firstmate"
    ><img
      alt="Fork"
      src="https://img.shields.io/badge/fork%20of-kunchenguid%2Ffirstmate-lightgrey?style=flat-square"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a crew. Sealed in a container.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.png" width="100%" />
</p>

> This is a fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate),
> locked down to run entirely inside Docker. It has no access to the host filesystem, no
> access to host credentials, and no route to any network destination outside a fixed
> allowlist. The upstream README's "clone it and launch your harness" workflow does not
> apply here: see [How this fork differs](#how-this-fork-differs).

## What it is

You can run one coding agent easily. The moment you want three project tasks done in
parallel you become a tab-juggler, babysitting sessions and forgetting which terminal had
the failing test.

firstmate flips the model. You talk to a single agent, the first mate, and it runs the crew
for you: spawning autonomous agents in a visible tmux session, giving each a clean git
worktree, supervising them to completion, and handing you finished PRs or standalone
investigation reports. It is not a model, a harness, or an app. It is an agent distro: a
directory of instructions, skills, tooling, and state conventions that turns a
general-purpose agent into a specialized one. Launching Claude Code inside it instantiates
your first mate, and makes you the captain.

This fork adds one thing: the isolation is structural rather than configured. Agents can
read and change code without being able to reach anything else on the machine. Upstream
firstmate runs with full host access, where every repository under your home directory and
every host credential is reachable by any agent it spawns. No setting fixes that, so this
fork puts the fleet in a container instead.

## How this fork differs

| | Upstream | Here |
| --- | --- | --- |
| Install | clone the repo, launch a harness on the host | `docker compose build && up -d`, then attach |
| The clone you are reading | the working firstmate home | build context only. None of the toolchain is installed on the host |
| Harness | 7 verified, Claude/Grok/Pi co-primary | Claude Code only. It is the only one in the image |
| Projects | cloned under `projects/` on your machine | cloned inside the container, never mounted from the host |
| GitHub identity | your `gh auth login` | the container's own scoped token |
| Network | your machine's network | 12 allowlisted domains, everything else refused |
| Away-mode alert | macOS notification | a ClickUp comment that mentions you |

Removed or unavailable in this fork:

- **The X and Discord relay is deleted**, not feature-flagged. It was the one path where a
  stranger's public text became agent instruction, so no activation path was left behind.
- **The voice relay is deleted.** It needed host audio the sealed container does not have.
- **Heroku is unreachable** by construction, as are all production data sources.

## Quick start

You need Docker, and a `.env` beside `docker-compose.yml`. Copy
[`.env.example`](.env.example) and fill it in. `GH_TOKEN` is the only variable that must be
set: compose refuses to start without it.

```sh
cp .env.example .env    # then edit it
docker compose build
docker compose up -d
docker compose exec firstmate tmux attach -t firstmate
```

If you left `ANTHROPIC_API_KEY` empty, run `claude` once inside the container. It prints a
URL to open in your own browser and takes the resulting code back, so the headless
container needs no browser of its own. The sign-in is written to the `fmhome` volume and
survives restarts.

To confirm the seal is doing its job, see
[Verifying the seal](docs/docker.md#verifying-the-seal).

## The daily loop

```sh
docker compose exec firstmate tmux attach -t firstmate
```

Window 0 is your primary session, where you talk to the first mate. Windows 1 and up are
crewmates, one per task, and you can watch or type into any of them. Detach with the tmux
prefix followed by `d`; the fleet keeps working.

Claude Code runs `bin/fm-session-start.sh` for you through the tracked session hook, so a
fresh attach opens with the fleet digest already printed. Run it yourself if that digest is
not there.

Then just talk:

```
> ahoy! fix the flaky login test in stern-liability and add dark mode

  PR ready for review, captain: https://github.com/SternRiskPartners/stern-liability/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

Every service is `restart: unless-stopped`, and all fleet state lives on the `fmhome`
volume, so a container restart reconciles rather than resets. The same is true of your
sign-in and your cloned projects. Only `docker compose down -v`, which deletes the volumes,
starts you over.

## What lives where

```
 you (the captain)
   │  docker compose exec firstmate tmux attach -t firstmate
═══╪═══════════════════════════════ container boundary ═══════════════
   ▼
 ┌──────────────────────────────────────────────────────┐
 │ firstmate            tmux window 0                   │
 │ FM_HOME=/home/fm/fmhome        on the fmhome volume  │
 │   data/  state/  config/  projects/                  │
 └──┬───────────────┬───────────────┬───────────────────┘
    ▼               ▼               ▼
 ┌────────┐    ┌────────┐      ┌────────┐
 │fm-task1│    │fm-task2│  ... │fm-taskN│   tmux windows 1..N
 │crewmate│    │crewmate│      │crewmate│   one agent each, own worktree
 └───┬────┘    └───┬────┘      └───┬────┘
     └─────────────┴───────────────┘
                   │
                   ├─ ship:  a PR for you to review and merge
                   └─ scout: a report at data/<id>/report.md

 on the same sealed network, none of them with a route out:

   proxy         squid, default-deny. The only way anything reaches the internet
   postgres:17   the Rails database, on the pgdata volume
   redis:7       Sidekiq and any direct Redis client
   /seed/claude  host ~/.claude, mounted read-only. Guardrails in, nothing out
```

The clone you are reading is the build context. The real firstmate home is
`FM_HOME=/home/fm/fmhome` inside the container, on a named volume, and the repo itself is
baked into the image at `/opt/firstmate`. Nothing on the host is mounted read-write, so
nothing in the container can reach back out to your machine.

## Projects

Project code is cloned fresh inside the container. No host repository is mounted, and the
container authenticates to GitHub as itself with the token you scoped, so agents can only
reach the repositories you granted. Currently cloned: `stern-liability`, `stern-etl`,
`stern-dbt-motherduck`, and `stern-omni`.

The image is a working Ruby on Rails environment, built against `stern-liability`'s pins:
Ruby 3.3.6, Node 24, Yarn 1.22.22, PostgreSQL 17 client tools, and the toolchain native
gems need. The `postgres` and `redis` sidecars back it, reached through `PGHOST`, `PGUSER`,
and `REDIS_URL`. The database is local and starts empty, so the first step in a fresh
container is the usual `rails db:create db:schema:load`. Production data is never a source
here, because nothing outside the allowlist is reachable.

Why each version was chosen is in
[docs/docker.md](docs/docker.md#ruby-and-rails).

## Credentials

Every credential arrives as an environment variable from your local `.env` and is passed by
reference. None is read from the host's `~/.claude`.
[`.env.example`](.env.example) is the authoritative list of what the container reads.

Scope `GH_TOKEN` deliberately. It can push wherever it has reach, so a repository that must
never be written should be granted read access or left out entirely.

The host's `~/.claude` is mounted read-only at `/seed/claude`, and the entrypoint copies
guardrail material out of it on every start: `CLAUDE.md`, settings, keybindings, `agents/`,
`skills/`, and the whole `plugins/` tree. Edit any of those on the host and restart to
propagate the change. Credentials and session transcripts are never copied, and the mount
is read-only, so nothing in the container can write back to the host.

The ClickUp and MotherDuck MCP servers are declared by the entrypoint from those variables
rather than copied from the host, and both are installed in the image, so starting one needs
no package registry.

## Notifications

Linux has no equivalent of the macOS notification the away-mode alarm uses, so the container
reaches you through ClickUp instead.
[`bin/fm-clickup-notify.sh`](bin/fm-clickup-notify.sh) posts a comment on the task named by
`FM_CLICKUP_TASK` and mentions `FM_CLICKUP_MENTION_USER_ID` so ClickUp sends its email. The
entrypoint wires it in as the away-mode alarm automatically.

```sh
bin/fm-clickup-notify.sh "PR ready for review: <url>"
```

## Troubleshooting

**Something that should reach the network does not.** It is almost always a host nobody
thought to list. The proxy names it:

```sh
docker compose exec proxy grep DENIED /var/log/squid/access.log | awk '{print $7}' | sort -u
```

Add it to [`docker/squid.conf`](docker/squid.conf) only if it belongs there, then
`docker compose restart proxy`.

**A client that ignores `HTTP_PROXY`** has no route at all, since external names do not even
resolve. Those need an `extra_hosts` loopback mapping and a tunnel entry;
[docs/docker.md](docs/docker.md#clients-that-ignore-the-proxy) has the procedure.

**`entrypoint: /seed/claude holds none of the expected guardrail files`** means the seed
mount is empty or pointed somewhere wrong. Check `CLAUDE_SEED_DIR`. The container will start
without any of your guardrails if you ignore it.

**Session start reports a tool version floor.** The axi family tracks its latest published
release, so a long-lived image eventually falls behind. Rebuild with
`docker compose build --no-cache firstmate`.

**Your Claude sign-in is gone.** Only `docker compose down -v` removes it, because it lives
on the `fmhome` volume. `down` without `-v` is safe.

## Built-in skills

| Skill | What it does |
| ----- | ------------ |
| `/afk` | Enter away-mode supervision: routine notifications are handled in bash, captain-relevant events are escalated as batched digests, and a stuck delivery raises an active alert |
| `/ahoy` | Recap session events since your last message plus any unanswered decisions, then walk you through the open ones in impact order |
| `/bearings` | A concise four-section digest of fleet state. `/bearings file` also writes a dated report, and `include PRs` adds live PR enrichment |
| `/stow` | Sweep the session for durable knowledge, persist open work records, curate tiered startup memory, and report what is safe to reset |
| `/updatefirstmate` | Fast-forward this firstmate to the latest from origin, then re-read instructions |

Agent-only reference skills live under `.agents/skills/` and are loaded at the trigger points
named in [`AGENTS.md`](AGENTS.md). Skills under `skills/` are public and installer-facing,
meant to be installed standalone into any project independent of firstmate.

## Documentation

Start here:

- [docs/docker.md](docs/docker.md) - the seal itself: what is sealed, the allowlist, the Rails
  environment, host guardrails, verification, and proxy-blind clients.
- [`AGENTS.md`](AGENTS.md) - the always-loaded operating contract and routing index.
- [docs/architecture.md](docs/architecture.md) - the crew, supervision, worktrees, and project modes.
- [docs/configuration.md](docs/configuration.md) - `FM_HOME`, the config files you set, and harness support.
- [docs/tmux-backend.md](docs/tmux-backend.md) - the backend this fork runs on.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - the away-mode alert, which the entrypoint points at ClickUp here.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the "no turn ends blind" supervision backstop.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered watcher protocols per harness.
- [CONTRIBUTING.md](CONTRIBUTING.md) - workflow, repo conventions, and how to run the tests.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - which audience each doc
  serves, and the machine-checked placement boundary that keeps it honest.

Inherited from upstream and **not applicable to this fork**, linked so a cherry-pick has
[GitLab merge watching](docs/gitlab-merge-watch.md).

## Relationship to upstream

Forked from [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate). The fork's
changes are the sealed container, the deletion of the public-mention relay, and a Rails
toolchain for `stern-liability`. Upstream fixes are cherry-picked occasionally rather than
tracked continuously, so expect this README and `docs/docker.md` to diverge.

## License

MIT - see [LICENSE](LICENSE).
