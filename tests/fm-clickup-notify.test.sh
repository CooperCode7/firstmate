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
for arg in "$@"; do
  if [ "$next_is_data" = 1 ]; then
    printf '%s\n' "$arg" > "${FM_TEST_CURL_BODY:?}"
    next_is_data=0
  fi
  [ "$arg" = "-d" ] && next_is_data=1
  printf '%s\n' "$arg" >> "$FM_TEST_CURL_ARGS"
done
printf '%s' "${FM_TEST_CURL_STATUS:-200}"
SH
chmod +x "$FAKEBIN/curl"

ARGS="$TMP_ROOT/curl.args"
BODY="$TMP_ROOT/curl.body"

run_notify() { # <extra env assignments...>: prints output, sets NOTIFY_RC
  local out rc=0
  out=$(env "$@" PATH="$FAKEBIN:$PATH" \
    FM_TEST_CURL_ARGS="$ARGS" FM_TEST_CURL_BODY="$BODY" \
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

NOTIFY_ARGS=("boom")
run_notify CLICKUP_API_KEY=secret-token FM_CLICKUP_TASK=abc123 FM_TEST_CURL_STATUS=401
expect_code 1 "$NOTIFY_RC" "a non-2xx response must fail loudly"
assert_contains "$NOTIFY_OUT" "401" "the failure must name the status it got back"
case "$NOTIFY_OUT" in
  *secret-token*) fail "the API token leaked into the error output" ;;
esac
pass "fm-clickup-notify reports a rejected request without echoing the token"

echo "# fm-clickup-notify.test.sh: all assertions passed"
