# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `FM_HOME` contains private operational directories.
`data/` holds durable private fleet records such as the project registry, captain preferences, learnings, backlog, briefs, and scout reports.
`state/` holds runtime records such as task metadata, append-only status events, endpoint signals, watcher and wake-queue coordination, inactive terminal-outcome receipts under `state/terminal-outcomes/`, away-mode state, and per-task steering-inbox records under `state/<id>.inbox/` (`bin/fm-task-inbox-lib.sh`).
`config/` holds local gitignored operating choices, and `projects/` holds the local project clones that Firstmate reads but changes only through the narrow guarded and concrete captain-approved exceptions in `AGENTS.md`.
Untracked files and directories whose names begin with `scratchpad` are also gitignored, so temporary scratch does not make porcelain-based guards treat a home as dirty.

`bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.
The producing PR helpers own the fields they append, `bin/fm-classify-lib.sh` owns status-event vocabulary, and `bin/fm-crew-state.sh` owns current-state reconciliation.
Wake, watcher, and away-mode state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

`bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`bin/fm-startup-network.sh`'s header owns the deferred network stage that keeps every external-network call off that digest's blocking path, including its state files and the safety argument for running them later.
`docs/sessionstart-nudge.md` owns the native session-open adapter tiers that run or nudge the digest command, and the source routing between them.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.
Dead-direct-report recovery is owned by `stuck-crewmate-recovery`.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the installed build passes the shared version and feature probe owned by [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh), including the atomic multi-ID move required by handoff delegation.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

## Runtime backend (config/backend / FM_BACKEND)

The runtime session-provider backend controls where task endpoints are created, captured, sent to, watched, and killed.
`tmux` is the only backend (see [`docs/tmux-backend.md`](tmux-backend.md)), and Treehouse is the worktree provider.
New spawns resolve it in this order: an explicit `--backend` flag that current authority for that exact task alone has authorized (a present captain instruction or the task's own accepted brief; never later-task precedent by analogy), then `FM_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then detection from `$TMUX`, then default `tmux`.
Any other value is rejected until another adapter is implemented and verified.
A spawn refusal from a missing dependency or version gate is terminal; firstmate surfaces it as a blocker instead of silently retrying.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`.
Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its runtime endpoint.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.
Legacy tmux metadata remains cleanup-compatible when its exact window name is `fm-<id>`; opaque non-tmux endpoints require their recorded `endpoint_task_id=` binding.

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned.
It supports only `tmux` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly.
Without overrides, backend detection uses `$TMUX_PANE`, then falls back to `tmux`.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then the legacy `firstmate:0` tmux fallback with a warning.
Selecting any other supervisor backend refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the current channel reference, [`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) for active evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` sets `test.evidence.store_in_repo: true` and pins `commands.lint` to `bin/fm-lint.sh` so local lint matches CI.
Storing evidence in the repo publishes each run's test artifacts to the orphan `no-mistakes/evidence` branch and links them from the PR body, instead of keeping them on local disk under the no-mistakes home.
That branch shares no history with code branches, so evidence never enters a pushed feature branch or the default branch; the worktree's `.no-mistakes/` stays local and CI rejects tracked entries under that path.
It does not set `commands.test` to a complete `tests/*.test.sh` walk.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the firstmate-specific local test policy and entry points.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Before changing it, inspect the current file and curate the matching bullet in place under the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) tiering and archive contract; add a new bullet only for a genuinely new durable preference.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) aging-tier and cold-archive contract: inspect the current file first and curate it instead of appending forever.
There is no shared learnings file by captain decision.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-home allowance for the startup prompt-memory surface: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` together.
The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.
The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.
Use `bin/fm-startup-memory-budget.sh read` to validate and print the effective value, or `bin/fm-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.
The helper's header owns exact parsing, publication, and report output mechanics.

## Stow pass horizon (config/stow-pass-horizon)

`config/stow-pass-horizon` is an optional local, gitignored presence flag that opts this home in to the pass-count decay horizon in the internal [`/stow` skill](../.agents/skills/stow/SKILL.md).
Without it a `/stow` pass decays memory entries on their wall-clock horizons alone - 30 days for `aging`, 7 days for `perishable` - which is the default and unchanged behavior.
With it, an entry is also stale after 10 passes (`aging`) or 3 passes (`perishable`) that evaluated it without reinforcing it, whichever horizon it reaches first.
Opt in for a home that stows often enough that entries never sit unreinforced for a wall-clock horizon, so memory only grows against the startup-memory budget above; a home that stows rarely already exceeds its date horizon on a single pass and gains nothing.
Only the file's presence is read, so its contents are ignored; remove it to return to the default contract on the next pass.
The skill text owns the marker spelling, the tick order, and the reinforcement rule.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
Before `fm-brief.sh`, `fm-spawn.sh`, or `fm-afk-launch.sh` persists a path or passes it to another process, it resolves each applicable relative `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` directory against the caller's working directory, preserves absolute spellings unchanged, and rejects an unresolvable relative directory with the offending variable named.

## Harness support

muse also needs a worker-reachable credential before spawning, and the portable fleet path is the `<config>/muse/auth.json` credential stored by `muse login`, because a caller-only `META_API_KEY` does not cross a long-lived backend daemon.
New harnesses get verified through a supervised trial task before joining the set.
The verified adapter evidence - each harness's busy-state source, interrupt and exit behavior, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
The executable interrupt and exit mechanics live in [`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh), and [`docs/agent-control.md`](agent-control.md) owns their lifecycle-control architecture.
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
Pi-family launches adapt the regular-TUI safeguard to the installed CLI's capabilities; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact version-safe launch mechanics.
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) owns its separate captain-approved crew wake hook.
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Cursor's stop hook parks on the watcher, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When pi-signed is selected, Firstmate preserves `FM_PI_HARNESS=pi-signed` and refuses the launch if the selected executable is unavailable rather than falling back to pi; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns executable resolution and launch mechanics.
Plain Pi launches set `FM_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi crews, `fm-spawn.sh` runs `fm-kimi-turnend-hook.sh install`, drops a per-task `.fm-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.
Kimi continues to use the captain's normal Kimi home, including the existing config, skills, and memory; Firstmate does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the captain's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.
Its `remove` action excises only the marker-delimited Firstmate region and removes Firstmate's hook files.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best matching rule with judgment, resolves its profile object or array under the operating contract in `AGENTS.md` section 4 and `quota-array-dispatch`, and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the completion-aware profile-array selection procedure.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`.
If no dispatch rule fits, firstmate resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
If a selected profile carries an effort value the chosen harness does not accept, `fm-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `CREW_DISPATCH` diagnostic when it is visible in the file.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
While the file remains present, no crewmate or scout spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, no-mistakes v1.31.2 or newer, compatible gh-axi, chrome-devtools-axi, compatible lavish-axi, compatible tasks-axi per "Backlog backend" above, and compatible quota-axi.
[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns the axi-family floor policy and the gh-axi and lavish-axi floors, while [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) and [`bin/fm-quota-axi-lib.sh`](../bin/fm-quota-axi-lib.sh) hold their own tools' floor constants.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, no-mistakes runs the validation pipeline, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
`tasks-axi` and `quota-axi` are required bootstrap tools in every profile, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)`; when `config/backlog-backend` is not `manual` and compatible `tasks-axi` is on `PATH`, bootstrap stays silent and firstmate uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
An absent or incompatible `gh-axi` reports `MISSING: gh-axi (install: npm install -g gh-axi && gh-axi setup hooks)`.
An absent or incompatible `lavish-axi` reports `MISSING: lavish-axi (install: npm install -g lavish-axi && lavish-axi setup hooks)`.
An absent or too-old `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)`; firstmate cannot resolve a profile array without a compatible binary.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
The locked session-start deferred network stage runs bootstrap's best-effort project clone refresh through `fm-fleet-sync.sh`; [`fm-bootstrap.sh`'s header](../bin/fm-bootstrap.sh) owns the exact clone-refresh overlap, liveness-before-convergence, per-mate concurrency, ordered diagnostic replay, and sequential-fallback contract.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The same deferred network stage performs guarded tracked-file sync and propagates declared inherited local material into each validated live home under that sequencing contract.
Local routes use direct guarded filesystem operations, while remote routes delegate sync and allowlisted transfer through their configured SSH host without probing any unconfigured fleet.
When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
A changed remote home instead receives one durably recorded marked re-read instruction after the allowlisted bytes have transferred because primary-local generation paths are not meaningful on another host.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/fm-procevent.sh` owns the generic contract; `bin/fm-procevent-lavish.sh` is the first adapter and wraps only the currently published `lavish-axi poll` interface.
That adapter, and only that adapter, retries the one exact transient response a cut-short listener returns while its marks remain available (`error: Lavish Editor poll response was interrupted` with `code: SERVER_ERROR`), up to 12 times at 5 second intervals, so an internal retry never reaches the runner as a captured result.
Real feedback, ended and missing sessions, any other `SERVER_ERROR`, and that same interruption still standing once the bound is spent are all captured and announced normally; `FM_LAVISH_POLL_RETRY_DELAY` is a bounded 0 to 60 second test override for the interval only, and the runner itself stays adapter-agnostic.
An already-armed Lavish source keeps its registered listener command until it is retired and armed again, so re-arm a live board once to adopt this retry policy.

The `when` adapter (`bin/fm-procevent-when.sh`) turns this channel into a condition->action primitive: it registers a deterministic condition and a deterministic action once, its blocking child polls the condition without waking firstmate, and a stable true fires the action at most once before one terminal outcome is durably captured and published as a wake that remains eligible for re-announcement until handled.
The (condition, action) spec is stored privately under `state/when/` and hash-bound by a trust record the same way `bin/fm-check-register.sh` binds a custom check, while the spec separately binds the resolved action executable's bytes; a mutated or unregistered spec or a changed action executable is refused before the action runs.
Every failure path - a mutated spec or action executable, a condition error past its budget, an expired deadline, a failed action, or an earlier fire whose outcome was never captured - produces a terminal captured outcome that wakes firstmate rather than a silent retry, and a durable single-fire marker claimed before the action makes restarts and re-polls unable to fire it twice.
The adapter automates only the exact deterministic subset: anything needing judgment, and anything destructive, irreversible, or security-sensitive, keeps the ordinary check-fires-then-firstmate-decides flow, and the adapter's header and `--help` own its commands, flags, and outcome document.

This section is the single owner of the runner's operating contract.
Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before any announcement or event can reference it.
By default, results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable wake queue, so the runner adds no second notification control plane.
The self-announcing adapter exception and its fail-safe ordering are defined below.
The watcher delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a default or fallback publication reaches firstmate through the same rewake path every other wake uses and never waits for a manual drain.
A queued `check` delivery is reported at most once per captured source and sequence while any records for that key remain queued.
A durable handled acknowledgement stops future source re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain's sequence-bound post-handling acknowledgement consumes it.

Discovery is never a timer.
Each registered source has its own child process blocking on that source, and the watcher's per-cycle `reconcile` republishes every captured result with no durable handled acknowledgement yet - regardless of any earlier publication - restarts a source whose owner is gone, and stops this home's runner when reconciliation runs after its registration disappeared unexpectedly.
In supported steady state, a home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

Whether a captured result ends its source is adapter knowledge, never the runner's.
After capture - and after initial `check` publication for the default ordering - the runner calls `bin/fm-procevent-<adapter>.sh terminal <result-file>` and retires the registration on exit 0 alone, dropping only the exact registration generation captured by its claim and releasing that claim only after removal succeeds under one source boundary; a missing command, an error, or any other exit keeps the source armed, so an adapter with no notion of ending needs no change.
A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work, while explicit `retire` stays the supported and idempotent path afterwards.
For Lavish that verdict covers an ended session, a missing session, and the final feedback of a `Send & End` review, which the published poll marks with `session_ended` before it returns only empty ended sessions.

Applying a captured result is adapter knowledge too, and some results carry no judgement at all: they must simply be applied idempotently to this home's own durable state.
Leaving that to a handler means it can silently not happen, so immediately after the terminal check above the runner calls `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` and lets the adapter apply and acknowledge its own result.
That call runs strictly after terminal retirement, because a handling adapter re-arms its own next source and retiring afterwards would drop that fresh registration and leave the source silently dead.
Exit 0 means the adapter fully applied and acknowledged the result; a missing command, an error, or any other exit is not a capture failure but leaves the result unacknowledged and therefore still eligible for re-announcement, so a handler receives it exactly as before and an adapter with no such command needs no change.
Announcement ordering is adapter-declared through `bin/fm-procevent-<adapter>.sh self-announcing`: an adapter that answers exit 0 declares that every result its autohandle fully applies is announced through a durable downstream channel of its own, so the runner applies first and publishes a `check` wake only for what remains unhandled afterwards; every other adapter keeps the strict publish-before-apply order, and its autohandle runs only when this capture's own wake was successfully appended to the durable queue.

Keyed captain answers use one more seam of the same kind, and the runner still decides nothing about them.
Some sources carry the captain's answer to a captain-held task, and what such an answer means is owned once by `bin/fm-captain-hold.sh`'s keyed-answer intake rather than by any channel.
A source bound with `bin/fm-captain-hold.sh bind` therefore has each captured result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints is piped straight into that intake.
A binding can select one decision origin or the script's cross-origin mode; the command header owns the exact forms and key interpretation.
The adapter reports only what the captain chose; the intake owns every rule about what happens next, so the runner names no adapter, parses no result, and carries no decision rule, and a future source needs nothing here beyond an `answers` command and a binding.
Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, because recording the answer is transcription while acting on it is firstmate's judgement.
An unbound source, an adapter with no `answers` command, and a failure on either side all leave the capture untouched and still announced.

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.
Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`).
Each claim binds its home and runner PID to a process identity, unique claim generation, and exact registration-file generation.
Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.
Retirement and orphan reconciliation signal a runner process group only while its recorded process identity still matches, or when the recorded leader is gone and only its own owned group survives.
A runner leads its own process group, so a claim counts as reclaimable only when that whole generation is gone: a crashed leader whose group still has members is not stale, and reconcile stops that surviving group and releases its generation before starting any replacement.
If identity cannot be established for a live PID, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
A live PID whose identity no longer matches is a reused PID, so it is treated as stale and its process group is never signalled.

If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
The sweep retires local registrations and machine-wide claims physically owned by that home through the same identity-checked, generation-bound retirement path, and leaves foreign-home claims untouched.
Teardown refuses with the home, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.
Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.

`FM_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.
`bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
Default and fallback `check` publication is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
The published `lavish-axi poll` clears feedback destructively before returning it, so a result lost between that clearing and the runner reading process output is unrecoverable.
Never describe this path as at-least-once, no-loss, or lossless.
`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

## Captain inbox (config/inbox-*)

The model-backed subcommands of `bin/fm-inbox.sh` reach a paid API in a named account, so no region, model id or AWS profile is shipped as a tracked default.
Each is one line in a local, gitignored `config/` file, with an environment variable that overrides it for a single run, and a missing required value refuses with the path to write rather than falling back to a value that belongs to another home.
That configuration is the whole opt-in: an unconfigured home cannot run `fm-inbox.sh say` or `ask`, while `note`, `status`, `list` and `drain` need no configuration at all because they make no model call.

| File | Environment | Holds |
| --- | --- | --- |
| `config/inbox-region` | `FM_INBOX_REGION` | AWS region for `fm-inbox.sh say` and `ask`. |
| `config/inbox-stt-model` | `FM_INBOX_STT_MODEL` | Speech-to-text model id, required by `fm-inbox.sh say`. |
| `config/inbox-ask-model` | `FM_INBOX_ASK_MODEL` | Side-question model id, required by `fm-inbox.sh ask`. |
| `config/inbox-profile` | `FM_INBOX_PROFILE` | AWS profile for those two calls; absent, or an explicitly empty variable, means whatever credentials are already in the environment. |

Each account and model file above is read as its first line that is not blank and not a `#` comment, so a comment above the value is fine.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity reads in fm-wake-lib.sh and fm-teardown.sh, mainly for tests
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest; each line is capped by bin/fm-line-cap-lib.sh
FM_SESSION_START_QUEUED_LIMIT=20   # plain queued backlog rows in the session-start digest; in-flight, held, and blocked rows are never bounded and done rows are never listed
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_BOOTSTRAP_NETWORK=all   # internal session-start phase split: all, skip (local steps only), or only (network steps only); see bin/fm-bootstrap.sh
FM_STARTUP_NETWORK_TIMEOUT=120   # seconds bounding the whole deferred network stage; hitting it prints an actionable NETWORK_CHECKS line
FM_TASKS_AXI_COMPATIBLE=   # internal one-hop handoff of an already-computed tasks-axi compatibility verdict (0 or 1); consumed when bin/fm-tasks-axi-lib.sh is sourced
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_INACTIVE_RECONCILE_SECS=900  # 60..1800-second watcher cadence and inactivity threshold; locked session start also scans immediately
FM_INACTIVE_RECONCILE_BUDGET_SECS=10  # 1..30-second scan deadline; wedged-scan kill backstop follows one second later
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls or custom checks)
FM_TASK_INBOX_GRACE_SECS=90   # seconds an unhandled steering-inbox message may sit before the watcher attempts doorbell delivery on an idle pane; also the minimum spacing between attempts
FM_TASK_INBOX_RING_MAX=3      # watcher delivery attempts without an acknowledgement before the task surfaces as a stale wake for recovery
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_TOOL_UPDATE_INTERVAL=900   # seconds between watched-tool probe sweeps; 0 probes on every run, other values must be 60..86400
FM_TOOL_UPDATE_PROBE_SECS=5   # 1..30 seconds allowed for one version or git probe
FM_TOOL_UPDATE_BUDGET_SECS=20   # 1..120 seconds allowed for a whole watched-tool sweep; cut to fit FM_CHECK_TIMEOUT, and the cut is reported
FM_TOOL_UPDATE_NOW=     # test override for the watched-tool sweep clock; the sweep budget still uses real time
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
FM_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/firstmate/procevent-claims
FM_WHEN_OUTPUT_TAIL_BYTES=8192          # bound on the command-output tail inside one condition->action outcome document
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_TEARDOWN_NM_TIMEOUT=10    # seconds allowed per no-mistakes query or abort inside fm-teardown.sh
FM_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes run rows scanned when axi status cannot be attributed to the current code
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
FM_CLAUDE_AUTOARM_ATTEMPTS=2   # bounded Stop-owned arm attempts per Claude auto-arm cycle; accepted values are 1, 2, or 3
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for watcher health, a role-verified Stop auto-arm claim, or a fresh epoch before deciding recovery ownership or failure progression
FM_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm outcome remains eligible for the current event epoch's recovery or failure decision
FM_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before the verified one-time attended fail-open; safely below Claude Code's 8-block override
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED; default 30 on Git Bash/MSYS
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows to stay above the MSYS confirm budget
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows to stay above the MSYS confirm budget
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates; stale panes whose crew is not provably working surface immediately unless they declare the pause verb
FM_BUSY_TURN_MAX_SECS=3600         # maximum age of a busy pane's latest state/<id>.turn-ended marker, or its state/<id>.meta spawn record before any turn completes, before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart; a declared external wait or verified captain-held transfer takes the FM_PAUSE_RESURFACE_SECS recheck below instead
FM_PAUSE_RESURFACE_SECS=3600       # seconds before the watcher re-surfaces a declared external wait or verified captain-held transfer for a recheck, including a live busy pane past FM_BUSY_TURN_MAX_SECS; the away-mode daemon uses the same setting for a declared external wait or verified captain-held transfer
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WORKTREE_WRITE_PRUNE='.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'   # directory names the wedge detector's task-worktree write probe skips; the default keeps .git out so a supervisor's own read-only git command can never look like crew progress; set it to the empty string to prune nothing, which widens the probe to the whole depth-bounded tree rather than disabling it
FM_WORKTREE_WRITE_TIMEOUT=10       # wall-clock seconds that one walk may take, so a worktree on a hung mount cannot stall the watcher poll that started it; hitting the bound reads as no write evidence, which leaves the escalation schedule exactly as it was; a value that is not a positive integer falls back to the default
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
FM_COMPOSER_IDLE_RE=    # optional fleet-wide idle-placeholder regex override (bin/fm-composer-lib.sh); a match alone does not prove emptiness because shape-specific position and ANSI de-emphasis safety gates still apply
FM_COMPOSER_CAPTURE_LINES=20   # fleet-wide bound for tail-capture composer reads; tmux instead supplies its bounded visible pane, while the other adapters use this small window so stale scrollback banners stay out of the candidate set
FM_COMPOSER_PI_MAX_LINES=8     # fleet-wide: maximum rows admitted between Pi's identity-corroborated separator pair; taller or ambiguous candidates stay unknown
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send typed-plane Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send typed-plane submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful typed-plane submit; 0 disables
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
FM_VOICE_REGION=        # overrides config/voice-region for one relay run
FM_VOICE_MODEL=         # overrides config/voice-model for one relay run
FM_VOICE_PROFILE=       # overrides config/voice-profile; explicitly empty forces ambient credentials
FM_VOICE_ID=            # overrides config/voice-id; matthew when neither is set
FM_VOICE_PYTHON=python3 # laptop-side interpreter used to start the relay over ssh
FM_INBOX_REGION=        # overrides config/inbox-region for fm-inbox.sh say and ask
FM_INBOX_STT_MODEL=     # overrides config/inbox-stt-model for fm-inbox.sh say
FM_INBOX_ASK_MODEL=     # overrides config/inbox-ask-model for fm-inbox.sh ask
FM_INBOX_PROFILE=       # overrides config/inbox-profile; explicitly empty forces ambient credentials
```

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
