#!/usr/bin/env bash
# Deterministic return-catch-up gate regression.
#
# Covers the second half of the 2026-07-14 incident: an away-mode blocked event
# survived in durable state, but the ordinary return request could proceed to
# Bearings before Firstmate owned remediation. The shared script now stops,
# drains, preserves evidence, and refuses ordinary work until every live open
# `blocked:` event is resolved or durably reclassified.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-return-tests)

install_runner() {  # <case-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp "$ROOT/bin/fm-afk-return.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
printf 'stop\n' >> "$FM_HOME/stop.log"
rm -f "$FM_HOME/state/.afk"
if [ -e "$FM_HOME/state/.fail-terminal-stop-once" ]; then
  rm -f "$FM_HOME/state/.fail-terminal-stop-once"
  exit 1
fi
rm -f "$FM_HOME/state/.afk-daemon-terminal"
SH
  cat > "$dir/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
file="$FM_HOME/state/.fake-drain"
if [ "${1:-}" = --ack-through ]; then
  [ "${3:-}" = --recovery-generation ] && [ "${4:-}" = fixture-generation ] || exit 2
  printf '%s\n' "$2" >> "$FM_HOME/state/.fake-drain-acks"
  : > "$file"
  exit 0
fi
if [ -s "$file" ]; then
  cat "$file"
  sequence=$(awk -F '\t' '$2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max + 0 }' "$file")
  printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation fixture-generation\n' "$sequence" >&2
fi
SH
  chmod +x "$dir/bin/"*.sh
}

run_return() {  # <case-dir> <mode>
  local dir=$1 mode=$2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-afk-return.sh" "$mode" 2>&1
}

ack_return() {  # <case-dir> <return-output>
  local dir=$1 output=$2 sequence generation
  sequence=$(printf '%s\n' "$output" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' | tail -1)
  generation=$(printf '%s\n' "$output" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "return output lacked a generation-bound post-handling acknowledgement: $output"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation"
}




test_captain_decision_does_not_masquerade_as_firstmate_blocker() {
  local dir out
  dir="$TMP_ROOT/captain-decision"
  install_runner "$dir"
  cat > "$dir/home/state/decision-task.meta" <<'EOF'
window=synthetic:fm-decision-task
backend=tmux
kind=ship
EOF
  printf 'needs-decision [key=api-shape]: captain must choose the synthetic API shape\n' > "$dir/home/state/decision-task.status"
  date +%s > "$dir/home/state/.afk"
  printf '1784074271\t1\tsignal\tdecision-task.status\tsignal: synthetic decision\n' > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "approval decision should not be treated as a firstmate blocker: $out"
  assert_contains "$out" 'catch-up wake:' "approval decision notification was not surfaced in catch-up"
  [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "approval decision incorrectly opened a firstmate blocker gate"
  pass "needs-decision remains reportable without masquerading as a firstmate-actionable blocker"
}

test_evidence_publication_failure_preserves_wake_for_redrain() {
  local dir out rc gate
  dir="$TMP_ROOT/evidence-publication-failure"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  printf '1784074271\t7\tsignal\trecovery-task.status\tsignal: recover after output failure\n' \
    > "$dir/home/state/.fake-drain"
  : > "$dir/read-only-output"

  set +e
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    "$dir/bin/fm-afk-return.sh" begin 3< "$dir/read-only-output" >&3 2> "$dir/failed.err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "evidence publication failure should retain catch-up (rc=$rc)"
  [ -s "$dir/home/state/.fake-drain" ] || fail "publication failure removed the unhandled durable wake"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "publication failure acknowledged the wake before delivery"
  [ -s "$gate" ] || fail "publication failure did not retain the catch-up gate"

  out=$(run_return "$dir" check) || fail "publication retry did not complete catch-up: $out"
  assert_contains "$out" 'catch-up wake: 1784074271' "publication retry did not re-drain the durable wake"
  assert_contains "$out" 'WAKE_ACK_REQUIRED: after handling completes' "publication retry did not return acknowledgement to the handling turn"
  [ -s "$dir/home/state/.fake-drain" ] || fail "successful evidence publication consumed the wake before handling"
  [ ! -e "$dir/home/state/.fake-drain-acks" ] || fail "successful evidence publication acknowledged the wake before handling"
  [ ! -e "$gate" ] || fail "successful publication retry left the catch-up gate pending"

  out=$(run_return "$dir" check) || fail "return did not recover after interruption before acknowledgement: $out"
  assert_contains "$out" 'catch-up wake: 1784074271' "interrupted handling did not re-drain the published wake"
  [ -s "$dir/home/state/.fake-drain" ] || fail "interrupted handling lost the published wake"
  ack_return "$dir" "$out" || fail "explicit acknowledgement after replay failed"
  [ ! -s "$dir/home/state/.fake-drain" ] || fail "explicit acknowledgement did not consume the replayed wake"
  [ "$(cat "$dir/home/state/.fake-drain-acks" 2>/dev/null || true)" = 7 ] \
    || fail "explicit acknowledgement after replay used the wrong wake sequence"
  pass "AFK return re-drains published wakes until handling acknowledges"
}

test_away_reentry_refuses_pending_return_gate() {
  local dir out rc
  dir="$TMP_ROOT/reentry"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  printf 'schema\tfm-afk-return.v1\nphase\tblocked\n' > "$dir/home/state/.afk-return-catchup"
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-afk-launch.sh" start-native 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "away re-entry succeeded while return catch-up was pending"
  assert_contains "$out" 'return catch-up is still pending' "away re-entry refusal did not explain the pending owner"
  [ ! -e "$dir/home/state/.afk" ] || fail "away re-entry wrote .afk despite the pending return gate"
  pass "away-mode re-entry fails closed while the prior return catch-up is pending"
}


test_captain_decision_does_not_masquerade_as_firstmate_blocker
test_evidence_publication_failure_preserves_wake_for_redrain
test_away_reentry_refuses_pending_return_gate
