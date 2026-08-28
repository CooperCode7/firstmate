# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## tmux

Foreground-process behavior was verified on 2026-07-07 with tmux 3.6a on macOS.

```sh
tmux new-session -d -s fmtest -n testwin
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin 'sleep 30' Enter
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin C-c
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
```

Observed output:

```text
zsh
sleep
zsh
```

A persistent parent shell waiting for a child remained reported as the parent process, while a shell that directly execed a simple command changed identity with the process itself.
Pi and pi-signed 0.82.0 were reverified on 2026-07-27 through real isolated `fm-spawn.sh` launches.

### Agent liveness name sources

The earlier record that every harness is observed under its own `#{pane_current_command}` no longer holds and has been replaced by the per-harness evidence below.
In this macOS run that reading reflected a rewritable process title rather than stable executable identity, so it is now one of two independent name sources rather than the sole basis of a verdict.

The seven primary-capable adapters were relaunched on 2026-08-03 with tmux 3.6a on macOS 26.5.2 arm64, each on a private socket in an isolated lab.

```sh
tmux -L "$socket" new-window -d -t "$session:" -n "$harness" -c "$wt" -- "$bin"
tmux -L "$socket" display-message -p -t "$session:$harness" '#{pane_current_command}'
ps -t "${tty#/dev/}" -o pgid=,tpgid=,comm=      # rows where pgid = tpgid
```

Observed identities, and the resulting verdict:

| Harness | Version | `#{pane_current_command}` | Foreground `comm` | Verdict |
| --- | --- | --- | --- | --- |
| claude | 2.1.220 | `2.1.220` | `claude` | alive |
| codex | codex-cli 0.146.0 | `codex` | `codex` | alive |
| opencode | 1.18.11 | `opencode` | `opencode` | alive |
| pi | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| pi-signed | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| grok | 0.2.118 | `grok-0.2.118-ma` | `grok` | alive |
| kimi | 0.31.1 | `kimi` | `kimi` | alive |

Claude Code is the harness whose title no longer attributes it at all; every other adapter is currently attributed by both sources.
Codex reported `codex-aarch64-a` at 0.145.0 and `codex` at 0.146.0, and Kimi Code reported `kimi-code` as its foreground `comm` at 0.29.1 and `kimi` at 0.31.1, so these identities move between ordinary patch releases in both directions.
That is the evidence for treating any single process name as a surface under vendor control rather than a stable contract.

The crewmate-only Muse Code 0.1.0-R708.1 adapter was verified separately on 2026-08-05 against tmux on macOS arm64.
Its installed `muse-bin-0.1.0-R708.1` foreground identity classified `alive`, while `musescore`, `amuse`, `muse-binary`, and `muse-bind` remained ambiguous in the portable regression.
[`muse.md`](muse.md#process-identity) owns the artifact identity and launcher evidence for that verification.

Bounded observed output:

```text
foreground comms:
  zsh
  .../instbin/muse-bin-0.1.0-R708.1
classify each:
  zsh                            -> shell
  muse-bin-0.1.0-R708.1          -> agent
fm_backend_agent_state tmux museliv:zsh
alive
```

`#{pane_current_command}` and foreground `ps -o comm=` read different name fields, but which one preserves executable identity is platform-dependent.
On macOS the pane command reflected the rewritable title while the full install path could survive in `ps -o comm=`; in the Linux portable regression those roles reversed for the version-named native executable, with the identifying path retained in argv[0].
The classifier therefore accepts a harness basename first, then an exact harness path component in the full executable path, then the same component in argv[0], without depending on which field carries it on a given platform.

The portable regression is CI-enforced, while the real-harness drift guard is opt-in under the policy in `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the live guard after any harness upgrade and before trusting or refreshing the table above:

```sh
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

Bounded output from the run that produced the table:

```text
ok - harness liveness: claude 2.1.220 (Claude Code) classifies alive
# claude 2.1.220 (Claude Code): title='2.1.220' foreground=[claude ]
# checked 7 installed harness(es)
```

Installed-wrapper checks:

```sh
basename "$(command -v pi-signed)"
pi-signed --version
pi --version
```

Observed bounded output:

```text
pi-signed
0.82.0
0.82.0
```

The isolated process and endpoint checks used:

```sh
tmux display-message -p -t "$target" '#{pane_current_command}'
ps -o comm= -p "$wrapper_pid"
ps -o comm= -p "$engine_pid"
FM_HOME="$fixture_home" bin/fm-crew-state.sh "$task_id"
```

Observed bounded shapes:

```text
pi-launcher
.../pi-signed
.../Pi Launcher.app/Contents/Resources/pi/pi
state: done ...
```

Both launches executed a submitted tool instruction and touched the generated `turn_end` marker.
The pi-signed launch retained `harness=pi-signed`, while the plain comparison retained `harness=pi`.
The exact wrapper ancestry was `pi-signed` parent to Pi engine child, and the plain Pi Launcher path also traversed the signed wrapper on this installation.
That shared plain-Pi path is retained as disconfirming evidence against using ancestry as runtime-selection authority.
Firstmate therefore sets the exact `FM_PI_HARNESS` selection marker on both worker launch paths, while an unmarked Pi-family process remains `pi`.
Both recorded runtime identities now classify the exact `pi-launcher` foreground command as `alive`.

Backend applicability was reviewed across every spawn adapter.
Tmux needs the exact `pi-launcher`, `pi-signed`, `pi`, and `Pi` process identities for recovery-grade liveness.

The current classifier matrix and its refresh guard are recorded in [Composer classification matrix](#composer-classification-matrix), with portable shape coverage in `tests/fm-composer-lib.test.sh` and `tests/fm-composer-ghost.test.sh`.
Kimi pointer delivery and OpenCode 1.18.4 busy-queue behavior remain pinned by `tests/fm-kimi-harness.test.sh`, `tests/fm-tmux-submit-busy.test.sh`, and `tests/fm-composer-lib.test.sh`.

### Cleanup endpoint identity

The cleanup identity boundary was validated on 2026-07-28 with tmux 3.6a and metadata fixtures for the supported backend.

```sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-teardown.test.sh
```

Bounded output from the incident regression:

```text
ok - fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call
ok - cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses
ok - tmux backend: direct empty target returns nonzero without invoking tmux
ok - process cleanup: creation-time PID identity removes only the exact child and preserves the control child
ok - fm-teardown: dedicated-socket invalid cleanup preserves target/control and valid cleanup removes only the exact target
```

The dedicated tmux cell removed ambient tmux variables, required a socket-bound wrapper, kept one target and one independent control window, and proved the wrapper was not called for invalid metadata or a direct empty target.
Valid cleanup removed only the exact task-bound target and left the control window live.
Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, and Muse share that backend cleanup boundary; their harness-specific hook files, tokens, transcript bindings, and session-log sidecars are cleaned only after it, so no harness needs a separate endpoint parser.

## Composer classification matrix

The shared composer classifier (`bin/fm-composer-lib.sh`, `fm_composer_classify_screen`) owns every composer shape fleet-wide; each backend contributes only a capture and a capability descriptor.
The live half of that guarantee was verified on 2026-08-10 from an already-trusted checkout at the branch's final validated head, against every installed harness then covered by the empty-composer matrix on tmux 3.6a, macOS arm64, on an isolated private socket, with no prompt submitted to any harness.
An earlier untrusted-worktree run left Claude, Grok, and Muse unverified because the guard treats first-launch trust dialogs as an unreadable-composer state and never confirms them; this trusted-checkout rerun supersedes those missing results.

The live guard that produced this record ran only on the zellij backend and was removed with it; the results below stand as the dated evidence, and the portable byte-capture regressions in `tests/fm-composer-lib.test.sh` are what now hold the classifier to them.

Observed output:

```text
ok - claude (2.1.227 (Claude Code)): real idle composer classifies empty
ok - codex (codex-cli 0.146.0): real idle composer classifies empty
ok - opencode (1.14.46): real idle composer classifies empty
ok - pi (0.84.0): real idle composer classifies empty
ok - grok (grok 1.0.0 (3cd0d0cbcebe)): real idle composer classifies empty
# harness absent, not verified here: kimi
ok - muse (Muse Code 0.1.0 (0.1.0-R708.1)): real idle composer classifies empty
ok - strict posture live: a blank shell row classifies unknown and injection defers
ok - zellij (zellij 0.44.0): unrelated pane change never confirms delivery (verdict: unknown)
ok - live composer-matrix guard verified 8 live surface(s)
```

All six installed harnesses' real idle composers reached a proven `empty` (Claude auto-updated to 2.1.227 between the audit and this rerun, so the shipped classifier is proven against the newer release as well), including Pi through the tmux foreground-process identity probe, Grok through the titled-bottom-border tolerance, and OpenCode through the left-bar shape; Codex and OpenCode first parked on vendor update-available modals that the strict classifier correctly refused until the guard's single non-submitting Escape dismissed them.
Kimi was not installed on the verification machine; its bordered shape is pinned by the portable byte-capture regressions in `tests/fm-composer-lib.test.sh`, which also carry the other five adapters' capability profiles for every harness under both a UTF-8 locale and `LC_ALL=C`.
Treat the versions above as a snapshot rather than a standing guarantee across releases.
Known staleness: on 2026-08-23 the steering-inbox doorbell run observed grok 1.0.5's idle composer classifying `unknown` (and sometimes pending-family), never `empty`, so the grok row above is stale for 1.0.5 and owes a refresh; steering is unaffected because the send path's composer check is advisory, but empty-requiring consumers (away-daemon injection, spawn readiness) should not trust the 1.0.0 grok result.
Cursor is deliberately outside this cursor-anchored empty-composer matrix because its terminal cursor is parked outside the composer; tmux's Cursor-specific, process-identity-gated cursorless fallback is covered by the [Cursor Agent CLI](#cursor-agent-cli) section's separate live evidence and drift guard.

## Steering-inbox doorbell

The steering channel's one behavioral assumption - a real worker agent follows the constant self-describing doorbell line (list the inbox, read and act on its records in numeric order, then `mv` each into `handled/`) - was verified on 2026-08-23 against every installed verified harness, on tmux 3.6a, macOS arm64, on an isolated private socket, driving the REAL `bin/fm-send.sh` end to end (durable record plus doorbell, with one mid-wait re-ring playing the watcher's role).

```sh
FM_SEND_INBOX_LIVE_E2E=1 tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

Observed output (combined across the full run and the grok rerun after the advisory-skip narrowing landed):

```text
ok - claude (2.1.241 (Claude Code)): the doorbell reached a real worker, which acted and acked with the mv
ok - codex (codex-cli 0.147.0): the doorbell reached a real worker, which acted and acked with the mv
ok - opencode (1.18.21): the doorbell reached a real worker, which acted and acked with the mv
ok - pi (0.84.1): the doorbell reached a real worker, which acted and acked with the mv
# grok (grok 1.0.5 (5115b46bc909) [stable]): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)
ok - grok (grok 1.0.5 (5115b46bc909) [stable]): the doorbell reached a real worker, which acted and acked with the mv
# harness absent, not verified here: kimi
ok - muse (Muse Code 0.2.1 (0.2.1-R1215.1)): the doorbell reached a real worker, which acted and acked with the mv
```

All six installed harnesses honored the doorbell contract with real model turns: each listed the inbox named by the doorbell, read its record, executed the instruction inside it, and acknowledged with the atomic `mv`.
Two findings from the run shaped the shipped behavior: an OpenCode vendor update modal swallowed the first doorbell and the single re-ring recovered it, which is exactly the watcher ladder's job; and grok 1.0.5's idle composer never classifies `empty` (a classifier drift owned by the [Composer classification matrix](#composer-classification-matrix) guard, whose refresh for grok 1.0.5 is still owed), which is why the ring's advisory pre-check skips only on an exact proven `pending` verdict - a doorbell into an ambiguous composer is a recoverable constant line, while skipping on ambiguity would starve steering for any harness the classifier cannot positively identify.
Kimi was not installed on the verification machine; its receive path is the same one-line-plus-shell contract, and the portable ladder and enqueue regressions in `tests/fm-task-inbox.test.sh` and `tests/fm-send-inbox.test.sh` cover every harness-independent half.
This guard is the refresh command after any harness upgrade; it spends a small number of real tokens per installed harness, reports an absent harness explicitly, and refuses a run that verified nothing.

## Cursor Agent CLI

The evidence below was produced on 2026-08-11 against the installed signed CLI on macOS 26.5.2 arm64 with tmux 3.6a, running as `kunchenguid`, and extended on 2026-08-13 with the tmux composer verdict below.

- Binary: `~/.local/bin/cursor-agent`, canonicalizing into `~/.local/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent`.
- Version: `cursor-agent --version` reported `2026.08.11-e8db854`, and `cursor-agent status` reported a logged-in account.
- Both installed names, `cursor-agent` and the legacy alias `agent`, resolve into that same versioned install tree.

Resolution prints the STABLE launcher rather than the canonical target, because the canonical path carries a version the CLI replaces on its own auto-update.

### Process identity

`#{pane_current_command}` and `ps -o comm=` disagree for cursor, which is why identity reads both:

| Source | Observed value |
| --- | --- |
| `#{pane_current_command}` | `node` |
| `ps -o comm=` | `/Users/<user>/.local/bin/cursor-agent` |
| child argv | `.../bin/cursor-agent --use-system-ca .../versions/2026.08.11-e8db854/index.js --trust --yolo` |

`node` matches no harness name pattern, so a cursor pane is identified from Cursor's own name or install tree in the path or argv[0].
An unrelated `node` or `agent` matches neither and classifies `other`, which the liveness callers fold into `ambiguous` rather than `dead`.
A live cursor pane returned `alive`; a plain shell pane in the same run returned `dead`.

### Environment markers and detection ordering

Read from the live agent process and from a tool subprocess it spawned:

| Marker | Where observed |
| --- | --- |
| `CURSOR_INVOKED_AS=cursor-agent` | the agent process itself, and its children |
| `CURSOR_AGENT=1` | child/tool processes only |
| `CURSOR_CONVERSATION_ID=<uuid>` | child/tool processes |
| `AGENT_TRANSCRIPTS=<projects-root>/<slug>/agent-transcripts` | child/tool processes |

Cursor does not clear an inherited `CLAUDECODE`, so ordering decides the verdict.
With both markers set, `bin/fm-harness.sh` reports `cursor`; with `CLAUDECODE` alone it still reports `claude`.

### Composer

Cursor's composer is a BARE row whose prompt glyph is `→` (U+2192); there is no border.
Its idle placeholder is `Plan, search, build anything` in a fresh session and `Add a follow-up` after a completed turn.

The styled capture of an idle composer row was:

```
ESC[48;2;21;21;21m ESC[2m→ ESC[0;7mESC[48;2;21;21;21mPESC[0;2mESC[48;2;21;21;21mlan, search, build anythingESC[0m
```

The glyph and the placeholder tail are dim (SGR 2), but the cell under the terminal cursor is reverse video (SGR 0;7).
Reverse video is neither dim nor a dark foreground, so ghost stripping leaves a lone `P` and an idle composer read `pending` before the fix.
After teaching the shared classifier the glyph, both placeholders, and the plain-row remnant rule, the same captures read `empty` on the styled cursorless backends, while real typed text - including text typed to exactly match the placeholder - still read `pending`.
An unstyled capture has no ghost-strip proof and correctly stays `unknown`.

#### tmux composer verdict, corrected 2026-08-13

The 2026-08-11 record that a Cursor pane's tmux composer verdict is `unknown` in every state described the cursor-ANCHORED read, which remains true: `#{cursor_y}` was 25 with `#{cursor_flag}` 0 on an idle pane, pointing below the footer, so tmux's cursor row is not a composer locator for Cursor.
Read cursorlessly, the same live capture classifies correctly, so the composite verdict is no longer `unknown`:

```text
cursor_y=25  cursor_flag=0
with-cursor : unknown      cursorless : empty     (idle composer)
with-cursor : unknown      cursorless : pending   (real typed text, not submitted)
with-cursor : unknown      cursorless : unknown   (agent exited to a shell)
```

`bin/fm-tmux-lib.sh` therefore reclassifies cursorlessly only when the pane's foreground process group is provably Cursor, so every other harness keeps the strict blank-cursor-row posture.
That supplies the genuine composer-empty proof required for away-mode escalation delivery.
A live injection through `bin/fm-supervise-daemon.sh`'s own `inject_msg` into a real Cursor pane returned 0 and the pane processed the typed `FIRSTMATE_OP: v1 away-supervisor:` escalation.

`tests/fm-tmux-agent-liveness.test.sh` pins this with real processes and no Cursor installed: it asserts the cursor-anchored source is blind, that the composite still reads `empty` idle and `pending` with typed text, that an identical screen stays `unknown` when the pane is not Cursor, and that a stale Cursor screen over a dead shell never reads `empty`.

### Busy state

Cursor writes a per-conversation transcript at `<projects-root>/<workspace-slug>/agent-transcripts/<conversation-id>/<conversation-id>.jsonl`.
Each turn is bracketed by a `role:user` open and a typed `{"type":"turn_ended","status":...}` close.
Observed closes: `success` for a completed turn, and `aborted` with `"error":"User aborted/interrupted manually."` after a single Escape.

The trailing close landed 0 seconds after the pane's busy footer cleared on a normal turn.
The transcript does NOT accumulate one close per turn, so a count of closes is not a progress signal; only the trailing record is.
After an interrupt the aborted close was observed within seconds in some runs and not within twenty seconds in others, so `bin/fm-control-lib.sh` deliberately claims no cancellation acknowledgement for cursor.

Binding never reconstructs cursor's workspace-slug directory name, which collapses path separators.
Cursor records the exact absolute workspace path in each project directory's `.workspace-trusted`, and the binding matches on that value.

### Rendered busy token, delivery only

Mid-turn the pane showed a braille spinner plus a verb, and `ctrl+c to stop` on the composer row; both the verb line and that token were absent the instant the turn ended.
The same version rendered `Working` in one turn and `Running` in the next, so the TOKEN is matched and the verb is not.
This row is a delivery guard for submit acknowledgement only; recorded worker state comes from the transcript fold.

### Launch, lifecycle, and skills

| Fact | Observed |
| --- | --- |
| Workspace trust | `--trust` suppressed the prompt; `--yolo` alone did NOT, and the prompt blocks a fresh worktree |
| Autonomy | `--yolo` (alias of `--force`); the footer renders `Run Everything` |
| Worktree | `-w/--worktree` allocates a SECOND worktree under `~/.cursor/worktrees` and is never passed |
| Effort | no effort flag exists; requested effort stays in task metadata |
| Interrupt | single Escape; the pane showed `Cancelled` and the composer returned to its placeholder, so no clear key is needed |
| Exit | `/exit` |
| Skill invocation | `/<skill>`; cursor discovers firstmate's user-level skills, and `/no-mistakes` autocompleted with firstmate's own description and invoked the skill |
| Slash popup | real: the first Enter closes the popup and a SECOND Enter submits, the same hazard as grok, covered by the submit core's retried Enter |

### End-to-end

A throwaway scout was spawned through `bin/fm-spawn.sh --scout --backend tmux` on a real cursor worker and driven to completion:

1. the launch delivered its brief positionally and the agent executed it;
2. `state/<id>.cursor-session` was written with the task worktree;
3. the transcript fold read `busy` mid-turn and `idle` after it;
4. `bin/fm-send.sh` delivered a steer through the then-current typed path and exited 0;
5. `bin/fm-control.sh <id> interrupt` cancelled a running turn;
6. `bin/fm-control.sh <id> exit` stopped the agent;
7. `bin/fm-teardown.sh` refused until the scout's report and decision gate were satisfied, then removed the session record.
