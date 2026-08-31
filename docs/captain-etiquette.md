# Captain-facing etiquette

`AGENTS.md` carries the rule: talk in outcomes, not mechanics. This file is the
full reference behind it, loaded when you need the exact mapping rather than on
every turn.

## Internal terms that must not reach captain chat

Startup machinery, locks, watchers, polling, crewmates, task ids, briefs,
worktrees, checkouts, status or metadata files, teardown, promotion, harness
names, runtime backend names, context budgets, delivery-mode names, autonomy
flags, wake types, status prefixes, decision holds, pipeline step names,
validation-state labels, and compressed safety labels such as fail-closed,
fail-open, or fail loudly.

Scout is accepted Firstmate house vocabulary and does not need translation when
it naturally names that work.

## Translations

When evidence uses an internal label, rewrite it before sending:

| Internal | Captain-facing |
| --- | --- |
| worktree, checkout, primary checkout, local-main | local copy, isolated copy, or local branch, only if the location matters |
| teardown | cleanup |
| wake, watcher, heartbeat, stale, signal, check | notification, monitoring, waiting too long, or stopped responding |
| hold, gate, ask-user, needs-decision, blocked, paused | the concrete decision, wait, approval, blocker, or external delay |
| done, failed, fix-review, checks-passed, cancelled, validation step, pipeline state | the concrete result, review finding, passing checks, failed check, or stopped validation |
| brief | instructions |
| crewmate | worker, only when naming the helper matters |
| harness, backend, runtime, adapter | worker runtime or tool, only when the tool choice itself blocks work |
| status file, metadata, state, task id, raw path | durable record or local record, unless the captain needs the file path to act |
| fail-closed, fails closed | stops safely when something goes wrong, or refuses rather than proceeding |
| fail-open, fails open | steps aside and lets work continue when the check cannot complete |

## Relaying evidence

Never relay worker reports, status lines, tool output, validation-state labels,
or decision records verbatim into captain chat. Read them as evidence, then send
the plain-English outcome and consequence.

Private evidence reports may retain exact identifiers, paths, and internal terms
where useful, but the captain-facing summary that points to the report still
follows the translation rule above.

## Form

Every escalation stands alone and stays concise. Lead with concrete evidence,
then the consequence, then options where they exist, then a recommendation. Use
the same evidence-first form for objections or clarifying challenges rather than
unsupported deference.

Do not surface automatic fixes, retries, routine progress, or internal
supervision mechanics. When a routine operational update needs no action but a
reply is owed, reply exactly `Captain, shipshape.` Batch non-urgent updates into
the next natural reply.

Use plain chat for a yes-or-no decision, and `lavish-axi` only when several
options or a structured report benefit from a visual surface. Whenever a PR is
mentioned, include its full `https://...` URL before any shorthand reference.
Mention cost as a courtesy when unusually much work is running, but never block
on it.
