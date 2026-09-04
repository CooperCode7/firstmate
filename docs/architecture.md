# Architecture

How firstmate works, in depth.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
firstmate's always-loaded operating contract and routing index for conditional procedures is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies detected wakes in bash, and wakes the first mate only when something is actionable.
Actionable wakes include captain-relevant status signals, no-verb signals whose crew is not provably working, authenticated check output such as PR merge polling, stale panes whose crew is not provably working whether their status log looks terminal or non-terminal, provably-working stale panes that persist past `FM_STALE_ESCALATE_SECS` without their own task worktree being written, declared external waits and verified captain-held transfers that remain declared past `FM_PAUSE_RESURFACE_SECS`, and heartbeat backstop hits.
Repeated provably-working stale escalations on the same unchanged pane add an escalation count to the wake reason and, at `FM_WEDGE_DEMAND_INSPECT_COUNT`, a `demand-deep-inspection` marker.
A pane holding a file newer than the start of its own quiet window, anywhere in the worktree recorded for that task, is deferred instead of escalated, because a crew writing source, then tests, then documentation behind a static pane is liveness that neither pane quietness nor the run step can show.
That deferral re-surfaces on the same `FM_PAUSE_RESURFACE_SECS` cadence as a declared wait, with a reason naming the write evidence rather than a wedge, and it is bounded to one pruned, depth-bounded, wall-clock-bounded walk (`FM_WORKTREE_WRITE_PRUNE`, `FM_WORKTREE_WRITE_MAXDEPTH`, `FM_WORKTREE_WRITE_TIMEOUT`) taken only in the branch that was about to escalate, never on every poll.
Every absence of write evidence, including a missing worktree record, a torn-down worktree, a walk that outlives its wall-clock bound on a hung mount, and a failed walk, leaves the existing escalation schedule untouched, so a crew that writes nothing still escalates exactly as before.
A busy pane is otherwise exempt from staleness, but only until its latest `state/<id>.turn-ended` marker reaches `FM_BUSY_TURN_MAX_SECS`, or its `state/<id>.meta` spawn record reaches that age before any turn completes; past that bound it is routed through the same wedge escalation, with the identical reason, escalation count, worktree-write deferral, and `demand-deep-inspection` marker, for inspection only - never an automatic interrupt, signal, or restart.
A crew that declared an external wait (`paused:`) or a verified captain-held transfer is the one exception to that bound: its busy verdict supplies liveness while identifying the long-running foreground call as the declared wait, so it takes the bounded `FM_PAUSE_RESURFACE_SECS` recheck instead of a wedge escalation.
Lifting the declaration restores the unchanged busy-pane wedge path, while a pane that is no longer busy returns to the existing idle declared-wait classification.
Those actionable wakes are written to a durable local queue (`state/.wake-queue`) only after generation-bound recovery evidence is published, so an interrupted watcher or handling turn can be recovered without losing the queue record.
`tests/fm-wake-queue.test.sh` pins the notification, idempotence, quiet-queue, and byte-for-byte foreign-row preservation guarantees.
When a canonical validated PR poll returns exactly `merged`, the watcher appends that durable notification before publishing a private receipt bound to the poll's registration, bytes, file identities, metadata, provider, URL, and task ID.
The receipt makes retirement safely retryable across restarts: fixed-path recovery revalidates the same evidence, removes the runnable check first, removes its registration and data sidecars, removes the receipt last, and preserves task metadata including `pr=` and `pr_head=`.
`bin/fm-pr-lib.sh` owns the receipt format and strict identity mechanics, while `bin/fm-watch.sh` owns queue-before-retirement ordering.
No-verb wakes, such as `working:` notes and bare turn-ended signals, are benign only when `bin/fm-crew-state.sh` reports positive evidence that the crew is still working: an actively running no-mistakes step attributed to that crew's current code, or an exact busy verdict from the semantic busy-state contract.
A crew that declares `paused:` for a known external wait, or carries a verified `captain-held` transfer, is separately absorbed while idle and re-surfaced only on the longer pause cadence, rather than being treated as a possible wedge.
For an ordinary crew that has stopped, the normal-mode watcher first surfaces one stale wake, then applies that same cadence to an unchanged `paused:` or durable `captain-held` endpoint only when the backend confidently reports its agent dead.
Its initial normal-mode status signal still surfaces through the no-verb path, while away mode self-handles that routine signal and owns the later recheck.
Fresh stale panes use the same current-state read before trusting the status log, so an active run or a proven busy worker outranks an old captain-relevant status-log line left behind before validation.
No-change heartbeats are also benign.
Separately from heartbeat backoff and wedge handling, the watcher poll runs `bin/fm-inactive-reconcile.sh` on its own bounded cadence, while locked session start performs the same bounded local scan immediately.
In each home the scan considers only that home's long-inactive direct ordinary crewmates, excludes captain-held work, and accepts only `done` or `failed` from `bin/fm-crew-state.sh`.
Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or LLM turn.
Each `fm-wake-drain.sh` presentation runs the same liveness guard as the supervision scripts, so a lapsed watcher chain surfaces even on a turn that only handles queued wakes.
Routine watcher polling, supervision no-ops, elapsed waiting time, and absorbed benign wakes stay silent.
A declared external wait or verified captain-held transfer trades that silence for one bounded recheck per pause window, naming which human the wait is on, so neither a forgotten pause nor a forgotten hold can remain invisible indefinitely.
Crew status files are append-only wake-event logs, not current-state fields.
Because of that, a per-wake read of only the latest line can bury an earlier still-open `needs-decision`/`blocked` under later unrelated appends; `fm-wake-drain.sh` prints a separate, fleet-wide OPEN DECISIONS section on every presentation (including the empty-queue path session-start relies on), built through `fm-classify-lib.sh`'s cursor-backed incremental scan using the authoritative `status_open_decisions` fold semantics so the buried decision keeps surfacing until it is explicitly resolved while each presentation folds only new status-log appends.
The drain coordinates that fold and its annotations through a locked fleet-wide snapshot whose `.status-presentation-cursor` manifest records each status file's identity and last-presented byte offset.
A queued signal annotation prints every status line still unread at that cursor, while the fleet-wide UNREAD STATUS section prints `note:` lines and reserved-key pending-reply resolutions once even on an empty-queue drain because those verbs never enter the OPEN DECISIONS fold.
A third bounded section, RECORD DIVERGENCE, prints on the same drains for the opposite failure: the status fold went quiet on a key that the durable captain-held task still shows as open, so the status side reads as complete while the two records contradict each other; `bin/fm-captain-hold.sh diverged` decides what counts and closes nothing, and `docs/captain-hold-lifecycle.md` owns the mechanism.
A failed read, output, or concurrent-replacement check prevents the snapshot cursor from advancing across uncertain bytes, and teardown retires a task's manifest row before that task ID can be reused.
This home's answerer close, pending-reply escalation close, and captain-held transfer use the provenance-guarded append owned by `bin/fm-wake-lib.sh`, so they advance the watcher marker only across their own bytes when all earlier bytes were already announced; pending or interleaved foreign bytes fail toward an ordinary wake.
A turn-ended-only queue row omits its historical status annotation when that status file exactly matches the same seen marker.
Any direct or remaining historical annotation prints every status line unread at the presentation cursor instead of replaying only the latest line.
`bin/fm-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review: it attributes a no-mistakes run, active or terminal, only when it matches the crew's branch and current code identity, then keeps that run-step authoritative even if the pane has closed.
The script header owns the exact run-head ancestry rules.
During no-mistakes' `ci` monitor phase, it also reads the ci step log tail because `axi status` reports both "still waiting on checks" and "checks green, waiting on merge" as `ci,running`.
The most recent recognized ci log marker wins, so checks-green monitoring reports done while a later re-arm, failed-check, or issue marker returns the crew to working.
Only when no matching run exists does it consult semantic busy state; exact busy reports working, exact idle permits fallback to a status-log event whose verb maps to a recognized run-state, and unknown or a dead pane stays unknown instead of trusting a stale log.
Decision-only events such as `resolved` never become current state or leak their prose into the current-state detail.
In that status-log fallback, a declared external wait reports the distinct `paused` state with its reason.
The semantic branch reports working only on an exact busy verdict and names the source that produced it; an unknown verdict never becomes working, never permits the status-log fallback, and never becomes a silent idle.
`bin/fm-fleet-view.sh` renders that snapshot as Markdown for humans, while `bin/fm-bearings-snapshot.sh` provides the bounded bearings projection, so both views consume one structured contract instead of reparsing raw fleet files.
The script header owns the exact JSON schema.

On a Pi primary, supervision is default-on: the watcher extension hands each wholly in-scope ordinary actionable wake, plus each bare fleet-wide `heartbeat` emitted after the cheap bash-level scan flags a possibly captain-relevant finding, to a persistent in-process supervision conversation instead of the captain's, which handles it, stores the outcome durably, and merges an append-only note back.
A captain-facing outcome instead opens exactly one follow-up turn on the captain's conversation without printing or rendering a separate note - that turn is the captain-visible result.

## Busy state is semantic, per adapter

`bin/fm-busy-lib.sh` is the single owner of what "this worker is busy" means, and `bin/fm-busy-event.sh` is the only writer of the per-task records it reads.
Every classification returns a verdict of busy, idle, unknown, or dead together with the source that produced it, so a consumer or a diagnostic can never confuse semantic state with a fallback.

Each converted adapter reports its own turn lifecycle through a machine-readable contract the vendor already exposes, rather than through rendered footer text: Pi and pi-signed through the Firstmate-owned extension's `agent_start` and `agent_settled` confirmed by `ctx.isIdle()`, OpenCode through its plugin's semantic `session.status`, Claude through owned `UserPromptSubmit`, `Stop`, `StopFailure`, and `SessionEnd` hooks, Muse through its session log, and Cursor through its conversation transcript.
Kimi behind Pi inherits Pi's lifecycle.
Codex and standalone Kimi classify unknown behind explicit probes until a semantic source is live-verified for them, and Grok keeps one clearly isolated rendered-tail fallback that can only ever classify a Grok task.

Missing, malformed, stale, untrusted, or unverified semantic state is unknown, never idle, and unknown is never promoted to busy either.
Ordinary task-state consumers act only on an exact busy verdict, so an unreadable worker surfaces for a closer look instead of being absorbed as still-working or written off as finished.
Endpoint death is the only process-level override and yields dead; child processes, CPU, process sleep state, and marker modification times are not state signals.
`state/<id>.turn-ended` files remain wake notifications, not current state.

Each record is bound to an incarnation token minted when the task's wiring is armed, so an event from a superseded incarnation is rejected rather than applied, and a record left behind by one classifies unknown.
All are harness-scoped rather than a global pattern union, and none is a recorded worker state source.

## Runtime session backends

The runtime backend is the session-provider layer below firstmate's scripts.
It owns task endpoint creation, bounded capture, text/key sends, current-path reads for spawn-time worktree discovery when the backend does not create the worktree itself, live-window fallback lookup, agent-process liveness probes where verified, and endpoint teardown.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns new-spawn backend selection precedence and authorization.
Unknown backend names fail loudly.
For compatibility, default tmux tasks do not write `backend=tmux`; every reader treats a missing `backend=` field as `tmux`.
`fm-watch.sh` decides each window's busy state through the semantic contract above rather than by polling the backend for rendered text.
That poll loop is still the default event source for backends with no native push events, so this stays an extraction of the abstraction rather than a watcher rewrite.

## Worktrees, not branches in your checkout

For ship and scout work, `fm-spawn.sh` refuses to launch unless the resolved task path is a real git worktree root that is distinct from the project primary checkout.
`fm-spawn.sh` also owns the base-freshness boundary for every fresh ship and scout: no worker starts until its clean task worktree matches the fetched tip of origin's resolved default branch, and any unsafe or unverifiable base stops the spawn.
Its header owns the exact refusal mechanics, while `tests/fm-spawn-pool-base-freshen.test.sh` owns the portable regression coverage.

The firstmate repo has one extra exposure because it can dispatch crewmates to work on itself.
Its operating checkout (`FM_ROOT`) and the disposable crewmate worktrees are all linked git worktrees of the same repository, so the valid discriminator is branch state, not whether the checkout is linked.
Only a named non-default branch checked out in `FM_ROOT` is a worktree tangle.

`fm-tangle-lib.sh` resolves the default branch from `origin/HEAD`, then local `main` or `master`, and classifies that named non-default primary branch as the tangle.
`fm-guard.sh` prints the repair command on the next mutable fleet action, while `bin/fm-session-start.sh` reports the same condition through bootstrap as a `TANGLE:` line at session start.
If another live session holds the fleet lock, both surfaces keep the alarm but switch to read-only wording with no repair command.
Ship briefs also tell the crewmate to verify `pwd -P` and `git rev-parse --show-toplevel` before creating `fm/<id>`, then stop with a blocked status if it landed in the primary checkout.

## No-mistakes gate authority boundary

Firstmate's own no-mistakes gate runs agents inside a checkout that also contains the fleet-captain identity in `AGENTS.md`, so gate execution needs an authority boundary separate from ordinary crewmate worktree isolation.
The tracked `.no-mistakes.yaml` sets `disable_project_settings: true`; no-mistakes honors that setting only from the trusted default-branch copy, so a pushed branch cannot enable its own project instructions during validation.
Independently, `fm-spawn.sh`, `fm-send.sh`, `fm-control.sh`, and `fm-teardown.sh` source `bin/fm-gate-refuse-lib.sh` and exit with status 3 before fleet mutation when the gate environment marker is present or the current checkout matches the default no-mistakes gate-repository topology.
A normal primary checkout or crewmate worktree has neither signal and remains unaffected.
The helper's header owns the exact signal detection, relocated-home limitation, test-harness bypass, and relationship to no-mistakes' HEAD-continuity guard.

## Two task shapes

Ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tasks leave standalone investigation reports at `data/<id>/report.md` and never push.
The intake and authority contract in `AGENTS.md` owns when separate scout research is warranted.

## Dispatch profiles

Crewmate and scout dispatch can stay on the static crewmate harness resolved by `config/crew-harness`, or it can use local dispatch profiles in `config/crew-dispatch.json`.
The dispatch file is intentionally judgment-based: firstmate reads the natural-language rules at intake, chooses the best matching rule, resolves profile arrays itself from current quota output under the `AGENTS.md` section 4 intake boundary and the `quota-array-dispatch` selection procedure, and passes only concrete `--harness`, `--model`, and `--effort` axes to `fm-spawn.sh`.
The shell scripts validate the JSON shape and verified harness/effort combinations, but they do not parse task intent, match natural-language rules, or own array selection.
The session-start bootstrap step keeps valid dispatch configuration silent unless verbose facts are enabled and surfaces a concise invalid-config line when validation fails.
When the file exists, `fm-spawn.sh` refuses crewmate and scout launches without an explicit harness, so `config/crew-harness` is only automatic when no dispatch profile file is active.
Unsupported effort values are still recorded in task meta when passed to `fm-spawn.sh`, but the launch template omits any effort flag that the selected harness does not accept.
That keeps spawn launch compatible across claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, and muse while preserving the requested profile for later audit.

## Delivery modes are explicit per task

`no-mistakes` tasks run the full validation pipeline, `direct-PR` tasks open PRs without that pipeline, and `local-only` tasks stay local until firstmate performs an approved fast-forward merge.
Each task's mode and `yolo` merge posture are firstmate's decision at intake.
The mode is passed explicitly to `bin/fm-brief.sh`, and both values are passed explicitly to `bin/fm-spawn.sh` and `bin/fm-promote.sh`; each command refuses to guess the values it consumes.
A ship brief records its mode as a fixed machine-readable line and the spawn refuses to launch on a different one, so the worker's instructions and the recorded task delivery cannot diverge.
`data/projects.md` records each project's standing posture and optional `+yolo` merge flag as the captain's default and as context for that decision, including the conditional `no-mistakes-prod-only` policy; a ship spawn that drops below the registered rigor prints a deviation notice and continues.
`bin/fm-project-mode.sh` remains the one registry parser for the mechanical consumers that have no task in hand: fleet sync's `local-only` skip and home seeding's refusal and no-mistakes initialization.
When a selected delivery path calls for a diff, `bin/fm-review-diff.sh` refreshes the authoritative base and, when task meta records `pr=`, always fetches and compares against `refs/pull/<n>/head` by default (recorded `pr_head=` is only an offline fallback) before falling back to the local branch with a warning.
Where a no-mistakes pipeline stores evidence in the repo, it publishes that PR-viewable validation evidence to an orphan evidence branch that shares no history with code branches, so it never enters the crew branch or the default branch.
This repo uses that setting, and its own `.no-mistakes/` directory remains local state that stays gitignored and is rejected by CI if tracked; [`configuration.md`](configuration.md) owns the setting.
PR-based task merges go through `bin/fm-pr-merge.sh`, which records `pr=` and any available `pr_head=` through `bin/fm-pr-check.sh` before calling the forge CLI.
The helper requires a full canonical URL and rejects malformed URLs or repo override flags before recording merge state.
A `https://github.com/<owner>/<repo>/pull/<n>` URL invokes `gh-axi pr merge <n> --repo <owner>/<repo>`, defaults to `--squash`, and preserves explicit merge-method flags.
A `https://<host>/<path>/-/merge_requests/<n>` URL (see [docs/gitlab-merge-watch.md](gitlab-merge-watch.md)) invokes `glab mr merge <n> -R https://<host>/<path>`, so the instance comes from the URL, and adds no merge-method flag because the project's own merge method applies.
That path merges only after one live read of the merge request confirms it is open, mergeable, conflict-free, with blocking discussions resolved and a successful pipeline at the current head, and it binds the merge to that verified head; recorded metadata is never the authority for those conditions because a rebase leaves it stale.
Teardown is fail-closed for ship worktrees: dirty worktrees refuse, and committed work must be landed before the worktree is returned.
[`bin/fm-teardown.sh`](../bin/fm-teardown.sh)'s header owns the landed-work proofs, PR-discovery fallback, and stale-lock recovery procedure.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a real `@AGENTS.md` import pointer.
Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
Each project `AGENTS.md` carries a short `## Maintaining this file` self-governance section; `bin/fm-ensure-agents-md.sh` owns the canonical wording and injects it idempotently when creating the skeleton, promoting an existing `CLAUDE.md`, or reconciling an existing `AGENTS.md` that still lacks it.
It refuses a case-variant real memory file such as a lowercase `agents.md`, so the pointer's `@AGENTS.md` import resolves to a real `AGENTS.md` on a case-sensitive filesystem, and surfaces the mismatch for manual reconciliation.
The full ownership rule - what is project-intrinsic versus fleet-private, and how firstmate keeps the two apart without writing into project clones - is owned by [`AGENTS.md`](../AGENTS.md) (project and knowledge management).

## Operational memory routing

`/stow` sweeps the current session for durable knowledge that only exists in conversation and routes each finding to the most specific disk home.
Home-domain captain preferences go to `data/captain.md`, cross-domain shared captain preferences go to the primary home's `data/captain-shared.md`, fleet-local operational facts and gotchas go to home-local `data/learnings.md`, project-intrinsic knowledge goes through normal crewmate delivery into that project's committed `AGENTS.md`, and task-scoped notes or undone next steps go to the backlog.
Memory writes use inspect-then-update rather than blind append; the internal [`stow` skill](../.agents/skills/stow/SKILL.md) owns tier markers, decay, cold archival, and offload.
The same pass also persists open-work record state the session is holding - filing a thread that was never recorded and correcting one the session knows went stale - bounded to the open work that session is actually holding.
It is deliberately not a reconciliation of durable records against repository or PR reality: its input is the volatile context, so it can only preserve what the session still knows, and no reconciliation that outlives a session exists today.
Task-scoped notes use `tasks-axi show <id> --full` followed by `tasks-axi update <id> --body-file <path>`, adding `--archive-body` when the prior body should remain recoverable.
The stow pass never writes a skill, but a separately executed, captain-approved migration may move conditional knowledge into a user-owned local skill excluded from the Firstmate clone; changes to Firstmate's tracked skills remain deliberate repository work through the normal PR pipeline.

## Local clones stay fresh

The locked session-start deferred network stage, PR-based teardown, and merged-PR wake handling refresh remote-backed project clones when the clone is safe to move.
Clean default-branch clones fast-forward to `origin/<default>`, and a clean detached HEAD that holds no unique commits is re-attached to the default branch before the same fast-forward path runs.
Dirty clones, non-default branches, detached HEADs with unique commits, diverged defaults, and default branches checked out in another worktree are reported as `STUCK:` with their behind count and left untouched.
Fetches blocked by an orphaned `.git/packed-refs.lock` use bounded retries and remove the lock only when the shared staleness proof can prove it abandoned; [configuration.md](configuration.md#toolchain) owns the recovery details and tuning knobs.
Local-only projects, clones without an origin remote, and fetch failures remain benign skips.
The refresh also prunes local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

For a remote route, the configured code root updates from its own origin on that host before the persistent home fast-forwards to the code-root commit.
The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
Local homes share the guarded fast-forward helper, while remote updates delegate the same safety decision to the configured host through the generic transport.
The mechanics are owned by the `/updatefirstmate` skill and firstmate's operating manual in [`AGENTS.md`](../AGENTS.md) (self-update).

## Restart-proof

Use `/stow` before an intentional reset when the conversation may hold durable knowledge that has not yet been written to disk; after that, the next firstmate session can reconcile and carry on.

## Development notes

The current watcher reliability work combines always-on bash triage with a durable queue for actionable wakes, generation-bound post-handling acknowledgement, deterministic re-arm recovery after watcher downtime, a race-proof singleton lock, duplicate self-eviction, drain-time liveness assertion, and a self-verifying tracked-child arm wrapper.
The presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) provides walk-away supervision via the `/afk` skill while reusing the same shared wake classifier as the always-on watcher.
