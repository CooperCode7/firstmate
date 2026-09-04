#!/usr/bin/env bash
# tests/fm-clickup-notify.test.sh - unit tests for the sealed container's only
# captain-facing outbound channel (bin/fm-clickup-notify.sh). The forge call is
# stubbed, so nothing here reaches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-clickup-notify.sh"
TMP_ROOT=$(fm_test_tmproot fm-clickup-notify)
mkdir -p "$TMP_ROOT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required to build the comment payload)"; exit 0; }

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
# Records the request instead of sending it, so the payload and the
# authorization header can be asserted without a live ClickUp task.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
: > "${FM_TEST_CURL_ARGS:?}"
next_is_data=0
next_is_out=0
for arg in "$@"; do
  if [ "$next_is_data" = 1 ]; then
    printf '%s\n' "$arg" > "${FM_TEST_CURL_BODY:?}"
    next_is_data=0
  fi
  # Real curl always creates its -o target. This fake writes one only when a
  # response is declared, so the default case leaves the path absent and keeps
  # covering the response-less failure path.
  if [ "$next_is_out" = 1 ]; then
    if [ -n "${FM_TEST_CURL_RESPONSE:-}" ]; then
      printf '%s\n' "$FM_TEST_CURL_RESPONSE" > "$arg"
    fi
    printf '%s\n' "$arg" > "${FM_TEST_CURL_OUTPATH:?}"
    next_is_out=0
  fi
  [ "$arg" = "-d" ] && next_is_data=1
  [ "$arg" = "-o" ] && next_is_out=1
  printf '%s\n' "$arg" >> "$FM_TEST_CURL_ARGS"
done
printf '%s' "${FM_TEST_CURL_STATUS:-200}"
SH
chmod +x "$FAKEBIN/curl"

ARGS="$TMP_ROOT/curl.args"
BODY="$TMP_ROOT/curl.body"
OUTPATH="$TMP_ROOT/curl.outpath"
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"

run_notify() { # <extra env assignments...>: prints output, sets NOTIFY_RC
  local out rc=0
  out=$(env "$@" PATH="$FAKEBIN:$PATH" TMPDIR="$SCRATCH" \
    FM_TEST_CURL_ARGS="$ARGS" FM_TEST_CURL_BODY="$BODY" FM_TEST_CURL_OUTPATH="$OUTPATH" \
    "$NOTIFY" ${NOTIFY_ARGS[@]+"${NOTIFY_ARGS[@]}"} 2>&1) || rc=$?
  NOTIFY_OUT=$out
  NOTIFY_RC=$rc
}

# --- refusals before any request --------------------------------------------

NOTIFY_ARGS=()
run_notify CLICKUP_API_KEY=tok FM_CLICKUP_TASK=abc123
expect_code 2 "$NOTIFY_RC" "a missing message must be a usage error"
[ ! -e "$ARGS" ] || fail "a usage error must not reach the forge"
pass "fm-clickup-notify refuses an empty message before sending anything"

NOTIFY_ARGS=("something happened")
run_notify CLICKUP_API_KEY=tok
expect_code 2 "$NOTIFY_RC" "no task id anywhere must be a usage error"
pass "fm-clickup-notify refuses when no task id is given or configured"

NOTIFY_ARGS=("something happened")
run_notify FM_CLICKUP_TASK=abc123
expect_code 1 "$NOTIFY_RC" "a missing token must fail"
assert_contains "$NOTIFY_OUT" "CLICKUP_API_KEY" "the missing-token error must name what is absent"
[ ! -e "$ARGS" ] || fail "a missing token must not reach the forge"
pass "fm-clickup-notify reports a missing token instead of sending an unauthenticated request"

# --- the request it actually builds -----------------------------------------

NOTIFY_ARGS=("PR ready for review")
run_notify CLICKUP_API_KEY=secret-token FM_CLICKUP_TASK=abc123
expect_code 0 "$NOTIFY_RC" "a well-formed notification should succeed: $NOTIFY_OUT"
assert_grep 'https://api.clickup.com/api/v2/task/abc123/comment' "$ARGS" \
  "the comment must be posted to the configured task"
[ "$(jq -r '.comment_text' "$BODY")" = "PR ready for review" ] \
  || fail "the comment text was not carried through: $(cat "$BODY")"
[ "$(jq -r '.notify_all' "$BODY")" = true ] || fail "the comment must notify watchers"
[ "$(jq -r 'has("assignee")' "$BODY")" = false ] \
  || fail "no mention should be attached when no user id is configured"
pass "fm-clickup-notify posts the message to the configured task"

NOTIFY_ARGS=("input needed")
run_notify CLICKUP_API_KEY=secret-token FM_CLICKUP_TASK=abc123 FM_CLICKUP_MENTION_USER_ID=81598920
expect_code 0 "$NOTIFY_RC" "a mention notification should succeed: $NOTIFY_OUT"
[ "$(jq -r '.assignee' "$BODY")" = "81598920" ] \
  || fail "the mention must be a number, so ClickUp sends its alert mail: $(cat "$BODY")"
pass "fm-clickup-notify mentions the captain when a user id is configured"

# An explicit task id overrides the configured default.
NOTIFY_ARGS=("done" other456)
run_notify CLICKUP_API_KEY=secret-token FM_CLICKUP_TASK=abc123
expect_code 0 "$NOTIFY_RC" "an explicit task id should succeed: $NOTIFY_OUT"
assert_grep 'https://api.clickup.com/api/v2/task/other456/comment' "$ARGS" \
  "an explicit task id must win over the configured one"
pass "fm-clickup-notify prefers an explicit task id over the configured default"

# --- the token never becomes output -----------------------------------------

# A rejected request must report the status and exit 1. The response body is
# absent here, as it is whenever the transport writes nothing, and that absence
# must not decide the exit status: reading a missing file under `set -e` exits 2
# on GNU sed and 1 on BSD sed, so a platform-dependent code would reach the
# away-mode alarm instead of the failure this promises.
NOTIFY_ARGS=("boom")
run_notify CLICKUP_API_KEY=secret-token FM_CLICKUP_TASK=abc123 FM_TEST_CURL_STATUS=401
expect_code 1 "$NOTIFY_RC" "a non-2xx response must fail loudly"
assert_contains "$NOTIFY_OUT" "401" "the failure must name the status it got back"
case "$NOTIFY_OUT" in
  *secret-token*) fail "the API token leaked into the error output" ;;
esac
pass "a rejected request exits 1 and names the status even with no response body"

# With a body, the credential-shaped strings in it are redacted rather than
# echoed, and the exit status is still the failure.
NOTIFY_ARGS=("boom")
run_notify CLICKUP_API_KEY=secret-token FM_CLICKUP_TASK=abc123 FM_TEST_CURL_STATUS=401 \
  FM_TEST_CURL_RESPONSE='{"err":"Team not authorized","token":"pk_81598920_ABCDEFGHIJKLMNOPQRSTUVWX"}'
expect_code 1 "$NOTIFY_RC" "a non-2xx response with a body must still exit 1"
assert_contains "$NOTIFY_OUT" "401" "the failure must name the status it got back"
assert_contains "$NOTIFY_OUT" "Team not authorized" "the body must be surfaced so the cause is visible"
assert_contains "$NOTIFY_OUT" "<redacted>" "a credential-shaped string must be redacted"
case "$NOTIFY_OUT" in
  *pk_81598920_ABCDEFGHIJKLMNOPQRSTUVWX*) fail "a credential-shaped string in the body reached the output" ;;
esac
pass "a response body is surfaced with credential-shaped strings redacted"

# The response never lands on a fixed shared path, which would collide between
# concurrent runs, and nothing is left behind afterwards.
OUT_USED=$(cat "$OUTPATH")
case "$OUT_USED" in
  "$SCRATCH"/*) : ;;
  *) fail "the response must be written under the process's own TMPDIR, got '$OUT_USED'" ;;
esac
LEFTOVER=$(find "$SCRATCH" -type f | wc -l | tr -d '[:space:]')
[ "$LEFTOVER" = "0" ] || fail "the response file must be cleaned up, $LEFTOVER left in $SCRATCH"
pass "the response goes to a private temporary file that is cleaned up"

echo "# fm-clickup-notify.test.sh: all assertions passed"
