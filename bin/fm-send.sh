#!/usr/bin/env bash
# Steer a task by durable record: write the message into the task's steering
# inbox and ring a constant doorbell line into its terminal, best-effort.
# Usage: fm-send.sh <target> [--resolve-key <key>]... <text...>
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit well-formed backend
#   target. fm-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: fm-send.sh <target> --key Enter
#
# Two data planes:
#
# INBOX - the default for text to a task recorded in this home, local and
# remote alike. The message is appended as a durable sequenced record under
# the task's steering inbox (newlines are legal) - state/<id>.inbox/ for a
# self-describing doorbell line plus Enter, best-effort. The durable record IS
# the delivery, so the record's fate alone governs the exit: 0 = the steer is
# durably sent (recorded); nonzero = nothing was confirmed delivered and a
# resend is appropriate (unresolvable target, an endpoint that cannot be
# locked and revalidated or that retired or changed, an unwritable record, a
# failed or lost remote transport) or a decision-close append failed after
# delivery (the error then carries the exact manual close). The remote enqueue
# is idempotent: the remote leg deduplicates an exact re-run of the same
# request onto the existing record (bin/fm-task-inbox-lib.sh), so after a lost
# transport (ssh exit 255, completion unknown) fm-send retries the same leg
# once itself. A later re-run is idempotent only through the printed
# correlation, body, and record, while a plain re-run mints a new correlation
# and delivers a separate record. A still-unconfirmed marked request keeps its
# reply expectation preserved for the record that may have landed.
# nonzero: with the recovery marker stored the watcher reconciles it silently,
# and with both the commit and the marker lost the send prints a distinct
# "reply-tracking-degraded (steer delivered, do not resend)" warning instead,
# because a resend-inviting status there would duplicate a delivered
# instruction. There is no delivered-unconfirmed
# outcome on this plane: "did the doorbell land" is no longer the question -
# "was the message acted on" is, and that is answered asynchronously by the
# worker's acknowledgement move into handled/, with the watcher re-ringing an
# unacknowledged message and escalating a stuck one. bin/fm-task-inbox-lib.sh
# owns the record format, the doorbell line, and the re-ring ladder. The
# composer pre-check before the ring is ADVISORY only: when the composer
# visibly holds pending text the ring is skipped with a notice and the watcher
# re-rings later; no composer verdict is delivery proof on this plane, and a
# failed ring never fails the send.
#
# TYPED - the LOCAL text that must reach the terminal itself: a harness-native
# invocation (a leading "/", or a leading "$" to a codex target) must reach
# the harness's own parser, and an explicit backend target names an endpoint,
# not a task, so it stays typed even when local metadata happens to match it
# (the same boundary that keeps it unmarked and outside --resolve-key). These
# type the literal
# text through the target backend's verified submit core: typed ONCE, then
# Enter retried (never retyped) until the backend confirms a submit or reports
# an inconclusive send. Typed-plane exit contract: 0 = submit confirmed;
# 3 = the text was typed into the live endpoint and
# Enter was sent, but the submit read-back stayed unconfirmed (verify the pane
# before any resend, and never re-type blindly; a marked request's
# failure); any other nonzero = the send failed and nothing may be assumed
# delivered. Submission dispatches through the target's recorded backend; the
# tmux adapter shares its composer/submit core with the away-mode daemon via
# bin/fm-tmux-lib.sh. Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP
# (0.4). Slash commands, and codex `$...` skill invocations resolved through
# harness meta, get a longer pre-Enter settle so completion popups do not
# reaches the harness as marker-prefixed chat rather than a parser command, so
# routing a remote "/..." or "$..." through the record changes nothing the
# parser would have seen); only --key still crosses to the remote pane as a
# keystroke.
#
# Stage-1 compatibility boundary: classification uses the original pre-marker
# as marker-prefixed chat rather than executing as a parser command. This is a
# pre-existing interaction retained for byte compatibility in this local-inbox
# stage; do not move the marker behind the invocation or omit it here. Follow-up
#
# From-firstmate marker: when the resolved target is a task selector whose meta
# routes its reply via its status file or a status-pointed doc instead of
# stranding it in chat the main firstmate never reads. On the inbox plane the
# marker travels verbatim inside the recorded body. A crewmate/scout target,
# an explicit backend-target escape-hatch target, and the --key path are never
# marked - their behavior is unchanged.
#
# also receives a privacy-safe correlation id and a durable parent record under
# success and reply success are separate facts: delivery never resolves the
# expectation. On the inbox plane the durable enqueue IS delivery to the task's
# record, so the expectation is marked delivered at enqueue time; when that
# bookkeeping commit fails after its durable recovery marker is stored, the
# send remains successful and watcher reconciliation owns the repair, and when
# the commit and marker are BOTH lost the send still remains successful with a
# reply-tracking-degraded warning naming the expectation an operator must
# inspect (it can no longer reconcile or escalate on its own). Only a
# failed enqueue discards the expectation. On the typed plane an unconfirmed submit (exit 3) keeps
# it armed rather than dropping it, and only a proven send failure discards it.
# for an already-open expectation so a second record is not created. Direct
# unmarked captain input never creates one.
#
# durable record into the remote home's steering inbox and rings the remote
# doorbell, best-effort. The remote record is the delivery, exactly as it is
# locally: leg exit 0 means durably recorded (fm-send then exits 0, marks the
# decisions), and any real remote failure fails loudly with the remote leg's
# own stderr attached. Transport loss (ssh exit 255) means completion unknown,
# so fm-send retries the identical leg once - safe because the remote write
# deduplicates the same request onto the same record - and a still-lost
# transport exits nonzero while preserving a marked request's reply
# expectation, since the record may have landed. Its error prints the exact
# and makes a later remote enqueue deduplicate onto that same record. The
# remote host runs no re-ring ladder of
# its own: a swallowed remote doorbell surfaces through the parent's
# remote doorbell when it is enqueued.
#
# Decision closure (answerer-closes): pass --resolve-key <key> (repeatable,
# before the message) when this send answers an open keyed needs-decision: or
# blocked: record in the target task's state/<id>.status. fm-send itself
# appends the closing "resolved [key=<key>]: answered: <capped excerpt>" line
# to that status file, so the captain-facing OPEN DECISIONS record closes at
# answer time and never depends on the busy worker writing a matching resolved
# line. On the inbox plane the close happens at ENQUEUE time, because enqueue
# is durable delivery to the task's record; the worker reading the answer late
# is covered by the acknowledgement re-ring ladder. On the typed plane it
# still waits for the confirmed submit. The close is a LOCAL append for every
# - because the open-decision ledger fm-wake-drain folds lives in this home's
# own state dir (a remote mate's escalations reach it through the
# parent-replies ingest); only the answer message crosses the backend or
# remote transport.
#
# Chat is also a channel that carries keyed captain answers, so the same flag
# feeds bin/fm-captain-hold.sh's one keyed-answer intake for any key that names
# a captain-held task in this home - the key as a task id itself, or through
# the legacy `<task>-decision-<key>` identity for pre-collapse rows. fm-send
# closes nothing itself; it hands the intake `<task-id>\t<answer>\t<label>`
# exactly as every other channel does, and the intake owns what that means.
# This is what lets an answer reach a decision that has already been
# transferred from the live status log to its durable captain-held task, which
# the status ledger alone can no longer close.
#
# Each named key must therefore currently be open in ONE of the two ledgers: open
# in this home's status log per status_open_decisions (bin/fm-classify-lib.sh), or
# a still-open captain-held task resolved as above. A key in neither is refused
# before sending, so a mistyped key cannot deliver an answer while silently
# orphaning the decision. A failed or unconfirmed send never closes a key; a
# delivered answer whose closing append fails exits nonzero with the exact
# manual close command, leaving the decision open to re-surface (the safe
# direction). A send without the flag never closes anything: a routine steer,
# working:, or done: event still cannot clear a captain decision. The flag is
# refused with --key, with an explicit backend target (no task ledger in this
# home), and with an empty message.
#
# After a successful TYPED-plane submit fm-send pauses FM_SEND_SETTLE seconds
# (default 1, 0 disables) before returning: submit confirmation only proves the
# text was accepted, but the harness needs a beat to spin up the turn before its
# busy footer appears, so an immediate peek would otherwise see the stale idle
# pane. The pause is typed-plane-only; the inbox plane, the shared submit core
# (used by the away-mode daemon, which only needs "submitted"), and the --key
# path do not pay it.
set -eu

FM_SEND_ORIGINAL_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never steer
# a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-send cannot resolve this home's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-send cannot resolve targets for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the requested message WILL still be sent.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() {  # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

# fm_send_clear_after_interrupt: muse RESTORES the interrupted prompt back into
# the composer when Escape cancels a turn, as real bright text (verified: fg
# 38;2;204;211;219, luminance ~210, muse 0.1.0-R708.1), not de-emphasised ghost
# text. Classifying that as pending input is correct - the text really is
# unsubmitted - but leaving it there means the NEXT steer types onto the end of
# it and submits both as one garbled message. Ctrl-U clears the composer
# (verified), so the interrupt is not complete until it has been sent. A failed
# clear is loud rather than silent, because the alternative is a corrupted steer.
# WHICH adapters need that clear, and which key clears them, comes from the one
# control-plane capability table (bin/fm-control-lib.sh) rather than a second
# copy here - the same table bin/fm-control.sh's interrupt verb reads.
fm_send_clear_after_interrupt() {  # <key>
  local key=$1 family clear
  [ "$key" = Escape ] || return 0
  family=$(fm_control_harness_family "$TARGET_HARNESS") || return 0
  clear=$(fm_control_interrupt_clear_key "$family") || return 0
  [ -n "$clear" ] || return 0
  [ "$TARGET_BACKEND" != remote ] || return 0
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$clear" "$EXPECTED_LABEL"; then
    echo "error: Escape reached $T, but the $TARGET_HARNESS composer could not be cleared; it still holds the restored prompt. Clear it before sending the next message." >&2
    return 1
  fi
}

fm_send_normalize_key() {  # <key>
  case "$1" in
    Escape|escape|Esc|esc) printf '%s' Escape ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_send_record_interrupt() {  # <key>
  local key=$1 id gen
  [ "$key" = Escape ] || return 0
  case "$TARGET_HARNESS" in claude*) : ;; *) return 0 ;; esac
  [ -n "$TARGET_META" ] || return 0
  id=$(fm_send_id_from_meta "$TARGET_META")
  [ -f "$STATE/$id.busy-gen" ] || return 0
  gen=$(fm_meta_get "$TARGET_META" busy_gen)
  if [ -n "$gen" ]; then
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --gen "$gen" --source fm-interrupt --event interrupt
  else
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --current-gen --source fm-interrupt --event interrupt
  fi || {
    echo "error: key '$key' reached $T, but the Claude interrupt state could not be recorded for $id" >&2
    return 1
  }
}


fm_send_resolve_target() {  # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
    fm-*:*)
      # session:pane target on the validated backend-target path below rather
      # than mistaking it for an unresolved task selector.
      ;;
    fm-*)
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#fm-}.meta; backend=none"
      echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this firstmate home" >&2
      return 1
      ;;
  esac


  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
    *:*)
      assumed=tmux
      if ! fm_backend_target_exists "$assumed" "$raw"; then
        echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
        return 1
      fi
      RESOLVED_TARGET=$raw
      TARGET_BACKEND=$assumed
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
      return 0
      ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use fm-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}

RAW_TARGET=$1
fm_send_resolve_target "$RAW_TARGET" || exit 1
T=$RESOLVED_TARGET
shift

# Supervision lease guard: a steer is overlap territory between the two Pi
# supervision actors, so refuse while the OTHER actor holds this task's live
# lease. A home with no supervision branch has no lease files and passes
# untouched (contract: bin/fm-lease-lib.sh).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
if [ -n "$TARGET_META" ]; then
  LEASE_GUARD_TASK=$(fm_send_id_from_meta "$TARGET_META")
  if [ -n "$LEASE_GUARD_TASK" ]; then
    fm_lease_guard "$LEASE_GUARD_TASK" "steer (fm-send)"
    trap 'fm_lease_guard_release' EXIT
  fi
fi

# Collect --resolve-key flags (answerer-closes; see the header contract). They
# must precede --key or the message text; everything after the last flag is the
# message exactly as before, so ordinary sends are byte-identical.
RESOLVE_KEYS=
fm_send_add_resolve_key() {  # <key>
  local k=$1
  case "$k" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: --resolve-key '$k' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)" >&2
      return 1
      ;;
  esac
  case " $RESOLVE_KEYS " in
    *" $k "*)
      echo "error: duplicate --resolve-key '$k'" >&2
      return 1
      ;;
  esac
  RESOLVE_KEYS="${RESOLVE_KEYS}${RESOLVE_KEYS:+ }$k"
}
while :; do
  case "${1:-}" in
    --resolve-key)
      [ $# -ge 2 ] || { echo "error: --resolve-key requires a key" >&2; exit 1; }
      fm_send_add_resolve_key "$2" || exit 1
      shift 2
      ;;
    --resolve-key=*)
      fm_send_add_resolve_key "${1#--resolve-key=}" || exit 1
      shift
      ;;
    *) break ;;
  esac
done

if [ "$TARGET_BACKEND" != remote ]; then
  fm_backend_validate "$TARGET_BACKEND" || exit 1
fi


# Validate the answerer-closes request before any durable mutation or send: the
# target must have a task ledger in THIS home, the send must carry an answer
# message, and every named key must be open right now in that ledger per the
# ONE authoritative fold (status_open_decisions). Refusing here, before the
# send, is what keeps a mistyped key loud instead of delivering an answer that
# silently leaves its decision open.
RESOLVE_STATUS_FILE=
# Which ledger each answered key belongs to. A key still open in the status log
# is owned by the status log: fm-captain-hold's `complete` closes that live copy
# at the moment it transfers a decision to its durable captain-held task, so
# "still open in status" and "already held" are the two sides of one transfer,
# never both at once. Checking the backlog only for keys the status log no
# longer owns also keeps the common path free of any backlog read.
RESOLVE_STATUS_KEYS=
RESOLVE_HOLD_KEYS=

# Resolve a --resolve-key key that the status log no longer owns to the
# captain-held task that carries it: the key as a task id itself (the collapsed
# identity - a captain call IS a task held for the captain), then the legacy
# derived `<task>-decision-<key>` identity for pre-collapse rows. Answerable
# means not closed and still carrying the captain-hold annotations tasks-axi
# preserves even past a hold-until date.
fm_send_hold_resolved_id() {  # <task-id> <decision-key>
  local show id state hold_kind
  command -v tasks-axi >/dev/null 2>&1 || return 1
  for id in "$2" "$1-decision-$2"; do
    show=$( (cd "$FM_HOME" && tasks-axi show "$id" --full) 2>/dev/null ) || continue
    state=$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)
    hold_kind=$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: //p' | head -1)
    [ "$state" != "done" ] || continue
    [ "$hold_kind" = captain ] || continue
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

if [ -n "$RESOLVE_KEYS" ]; then
  if [ -z "$TARGET_SELECTOR" ] || [ -z "$TARGET_META" ]; then
    echo "error: --resolve-key needs a task selector resolved through this home's metadata; an explicit backend target has no decision ledger here" >&2
    exit 1
  fi
  if [ "${1:-}" = "--key" ]; then
    echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
    exit 1
  fi
  if [ -z "$*" ]; then
    echo "error: --resolve-key requires a nonempty answer message" >&2
    exit 1
  fi
  RESOLVE_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
  RESOLVE_STATUS_FILE="$STATE/$RESOLVE_TASK_ID.status"
  resolve_open_set=$(status_open_decisions "$RESOLVE_STATUS_FILE")
  for k in $RESOLVE_KEYS; do
    case "$resolve_open_set" in
      "$k"$'\t'*|*$'\n'"$k"$'\t'*)
        RESOLVE_STATUS_KEYS="${RESOLVE_STATUS_KEYS}${RESOLVE_STATUS_KEYS:+ }$k"
        continue
        ;;
    esac
    # Not open in the status log. A decision already transferred to its durable
    # captain-held task is exactly this case, and it is answerable - just
    # through the other ledger - so check there before refusing.
    if resolved_hold_id=$(fm_send_hold_resolved_id "$RESOLVE_TASK_ID" "$k"); then
      RESOLVE_HOLD_KEYS="${RESOLVE_HOLD_KEYS}${RESOLVE_HOLD_KEYS:+ }$resolved_hold_id"
      continue
    fi
    echo "error: --resolve-key '$k': no open decision or blocker with that key in $RESOLVE_STATUS_FILE, and no captain-held task '$k' or '$RESOLVE_TASK_ID-decision-$k' still open (already closed or mistyped). Re-check the OPEN DECISIONS listing, then resend without that key or with the right one; nothing was sent." >&2
    exit 1
  done
fi

# Close each answered decision in this home's ledger, only after the answer is
# durably sent: enqueued on the inbox plane, submit-confirmed on the typed
# plane. An append failure exits nonzero with the manual close
# command; the decision then stays open and re-surfaces, never silently lost.
# The close is this home's own bookkeeping, written by the very turn that
# answered the decision, so it goes through the guarded self-announced append
# (bin/fm-wake-lib.sh) and does not wake this same session again; any
# concurrent foreign status bytes leave the watcher's wake path untouched.
fm_send_close_resolved_keys() {  # <answer-text>
  local note=$1 k line append_rc
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_STATUS_KEYS; do
    line="resolved [key=$k]: answered: $note"
    fm_cap_line_var "$line"
    append_rc=0
    fm_wake_status_append_self_announced "$STATE" "$RESOLVE_STATUS_FILE" "$FM_LINE_CAP_LINE" || append_rc=$?
    if [ "$append_rc" -eq 2 ]; then
      echo "error: the answer was delivered to $T, but decision key '$k' could not be closed in $RESOLVE_STATUS_FILE. Close it manually with: echo 'resolved [key=$k]: <how it was answered>' >> $RESOLVE_STATUS_FILE - do not resend the answer." >&2
      return 1
    fi
  done
}

# Feed the answered captain-held tasks to the ONE keyed-answer intake, as keyed
# lines, exactly the way every other channel does. fm-send decides nothing here:
# it does not build a decision record or choose a close path; the keys were
# already resolved to task ids above, so the intake needs no legacy origin.
fm_send_feed_resolved_holds() {  # <answer-text>
  local note=$1 k lines=''
  [ -n "$RESOLVE_HOLD_KEYS" ] || return 0
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_HOLD_KEYS; do
    lines="${lines}${k}"$'\t'"${note}"$'\t'$'\n'
  done
  if ! printf '%s' "$lines" | "$SCRIPT_DIR/fm-captain-hold.sh" answers \
    --source "a firstmate answer sent to $RESOLVE_TASK_ID" >/dev/null 2>&1; then
    echo "error: the answer was delivered to $T, but this captain-held task could not be closed: ${RESOLVE_HOLD_KEYS}. Close it with fm-captain-hold.sh answer - do not resend the answer." >&2
    return 1
  fi
}

if [ "${1:-}" = "--key" ]; then
  case "$*" in
    *--resolve-key*)
      echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
      exit 1
      ;;
  esac
  key=$2
  semantic_key=$(fm_send_normalize_key "$key")
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$key" "$EXPECTED_LABEL"; then
    echo "error: key '$key' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  fm_send_clear_after_interrupt "$semantic_key" || exit 1
  fm_send_record_interrupt "$semantic_key" || exit 1
else
  MESSAGE=$*
  # The pre-marker answer text, kept for the closing resolved note so the
  # durable ledger records the plain answer without marker or corr bytes.
  RESOLVE_ANSWER_TEXT=$MESSAGE
  # Data-plane selection (see the header): text addressed to a task selector
  # resolved through this home's metadata rides the inbox plane, unless it is
  # a LOCAL harness-native invocation that must reach the harness's own parser
  # - a leading "/" (slash command), or a leading "$" to a codex target (skill
  # requests are marked, and a marked request reaches the harness as
  # marker-prefixed chat rather than a parser command anyway, so no remote
  # text has a typed plane to lose. An explicit backend target stays typed
  # even when it happens to match local metadata: it names an endpoint, not a
  # task, the same boundary that keeps it unmarked and outside --resolve-key.
  # and a plain crewmate steer classify identically. It deliberately does NOT
  # command: the pre-existing marker-first wire bytes are retained in stage 1.
  INBOX_PLANE=0
  if [ -n "$TARGET_SELECTOR" ]; then
    if [ "$TARGET_BACKEND" = remote ]; then
      INBOX_PLANE=1
    else
      case "$RESOLVE_ANSWER_TEXT" in
        /*) ;;
        \$*) [ "$TARGET_HARNESS" = codex ] || INBOX_PLANE=1 ;;
        *) INBOX_PLANE=1 ;;
      esac
    fi
  fi
  if [ "$INBOX_PLANE" = 1 ]; then
    INBOX_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
    INBOX_META_LOCK=$(fm_meta_lock_path "$TARGET_META") || exit 1
    if ! fm_task_inbox_lock_acquire "$INBOX_META_LOCK"; then
      echo "error: steer not sent to $INBOX_TASK_ID: its task metadata could not be locked for final delivery validation" >&2
      exit 1
    fi
    CURRENT_INBOX_TARGET=
    CURRENT_INBOX_BACKEND=
    if [ -f "$TARGET_META" ]; then
      CURRENT_INBOX_TARGET=$(fm_backend_target_of_meta "$TARGET_META")
      CURRENT_INBOX_BACKEND=$(fm_backend_of_meta "$TARGET_META")
    fi
    if [ "$CURRENT_INBOX_TARGET" != "$T" ] \
      || [ "$CURRENT_INBOX_BACKEND" != "$TARGET_BACKEND" ] \
      || [ -n "$(fm_meta_get "$TARGET_META" remote_host)" ]; then
      fm_lock_release "$INBOX_META_LOCK"
      echo "error: steer not sent to $INBOX_TASK_ID: the task retired or changed endpoint during target resolution" >&2
      exit 1
    fi
    if ! INBOX_RECORD=$(fm_task_inbox_write "$STATE" "$INBOX_TASK_ID" "$MESSAGE"); then
      fm_lock_release "$INBOX_META_LOCK"
      echo "error: steer not sent to $INBOX_TASK_ID: its inbox record could not be written under $STATE/$INBOX_TASK_ID.inbox" >&2
      exit 1
    fi
    fm_lock_release "$INBOX_META_LOCK"
    # Enqueue IS durable delivery to the task's record: mark the pending
    # expectation delivered now, without resolving it - only a correlated
    # parent report acknowledges the request.
    # The answer is durably sent: close each answered decision at enqueue time
    # (answerer-closes; see the header contract).
    if [ -n "$RESOLVE_KEYS" ]; then
      fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
      fm_send_feed_resolved_holds "$RESOLVE_ANSWER_TEXT" || exit 1
    fi
    # Ring the doorbell, best-effort: no ring outcome changes the exit status,
    # because the watcher's re-ring ladder owns loss detection from here.
    ring_rc=0
    fm_task_inbox_ring "$TARGET_BACKEND" "$T" "$INBOX_RECORD" "$EXPECTED_LABEL" || ring_rc=$?
    case "$ring_rc" in
      1) echo "fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at $INBOX_RECORD and the watcher will re-ring" >&2 ;;
      2) echo "fm-send: doorbell did not reach $T; the steer is durably recorded at $INBOX_RECORD and the watcher will re-ring" >&2 ;;
    esac
    exit 0
  fi
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The target backend's
  # verified submit retry still backs the settle up either way.
  case "$*" in
    /*) settle=1.2 ;;
    \$*)
      if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
      ;;
    *) settle=0.3 ;;
  esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Only exact empty confirms delivery; every other
  # verdict preserves the loud refusal boundary. Only LOCAL targets reach this
  # block: remote text rides the inbox leg above, and remote --key exits
  # earlier.
  send_rc=0
  if verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" "$retries" "$sleep_s" "$settle" "$EXPECTED_LABEL"); then
    :
  else
    send_rc=$?
  fi
  if [ "$send_rc" -ne 0 ]; then
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  case "$verdict" in
    empty)
      ;;
    send-failed)
      echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
    pending)
      # The text was typed into the live target and Enter was sent; only the
      # submit read-back stayed unconfirmed (e.g. a busy harness queues the
      # steer and keeps rendering it). That is not a proven failure, so never
      # re-type the message: verify the pane instead. Exit 3 is the documented
      # delivered-unconfirmed status.
      # dropping it would silently stop tracking a marked request that very
      # likely landed. It stays armed on its unconfirmed-delivery marker, so a
      # correlated report still resolves it and an unanswered one still
      # surfaces through the library's own reconciliation
      echo "fm-send: text delivered to $T but submission is unconfirmed (verdict=pending; tried $RESOLUTION_TRIED); do not retype or blindly resend - verify with fm-peek.sh, then re-send '--key Enter' only if the composer still holds the text" >&2
      exit 3
      ;;
    *)
      echo "error: text not submitted to $T (delivery unconfirmed; verdict=${verdict:-unknown}; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
  esac
  # Delivery confirmed. Mark the pending expectation delivered without resolving
  # it: only a correlated parent report acknowledges the request.
  # Delivery is fully confirmed: close each answered decision in this home's
  # ledger (answerer-closes; see the header contract).
  if [ -n "$RESOLVE_KEYS" ]; then
    fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
    fm_send_feed_resolved_holds "$RESOLVE_ANSWER_TEXT" || exit 1
  fi
  # Submit landed with exact empty. Confirmation only proves the text was
  # accepted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
