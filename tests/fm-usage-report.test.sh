#!/usr/bin/env bash
# tests/fm-usage-report.test.sh - behavior tests for bin/fm-usage-report.sh.
#
# The report is a read-only projection over Claude Code transcripts, so every
# case drives the executable against synthetic transcript fixtures and asserts
# on its output contract, never on its source.
#
# The load-bearing case is deduplication: a streamed response repeats the same
# usage object across chunks, so a report that sums raw records overstates every
# total several-fold. Pricing, role attribution, the credit-episode inference,
# TOON/JSON parity, refusals, and the sampler's rate limit are pinned alongside it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-usage-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-report-tests)

# mk_record <sid> <req> <ts> <cwd> <model> <out_tok> <cw1h> <cw5m> <sidechain>
# Emits one assistant transcript line. Cache creation totals mirror the TTL split
# so a fixture cannot claim a write that belongs to neither bucket.
mk_record() {
  printf '{"type":"assistant","sessionId":"%s","requestId":"%s","timestamp":"%s","cwd":"%s","isSidechain":%s,' \
    "$1" "$2" "$3" "$4" "$9"
  printf '"message":{"model":"%s","usage":{"input_tokens":0,"cache_creation_input_tokens":%s,' \
    "$5" "$(( $7 + $8 ))"
  printf '"cache_read_input_tokens":0,"output_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s,"ephemeral_5m_input_tokens":%s}}}}\n' \
    "$6" "$7" "$8"
}

# fixture_dir <name>: a fresh transcripts root registered under the temp root.
fixture_dir() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/session"
  printf '%s' "$d"
}

run_json() { "$REPORT" "$@" --json 2>/dev/null; }

# --- refusals ---------------------------------------------------------------

OUT=$("$REPORT" --help 2>&1); CODE=$?
expect_code 0 "$CODE" "--help must succeed"
assert_contains "$OUT" "fm-usage-report.v1" "--help must state the output schema"
pass "--help succeeds and names the output schema"

"$REPORT" --dir "$TMP_ROOT/does-not-exist" >/dev/null 2>&1
expect_code 1 "$?" "a missing transcripts directory must refuse"

EMPTY=$(fixture_dir empty)
OUT=$("$REPORT" --dir "$EMPTY" 2>&1); CODE=$?
expect_code 1 "$CODE" "a directory with no usage records must refuse"
assert_contains "$OUT" "no usage records" "the empty-directory refusal must say why"
pass "an absent or record-free transcripts directory refuses instead of reporting zeros"

"$REPORT" --since 08-2026 >/dev/null 2>&1
expect_code 2 "$?" "a malformed --since must be a usage error"
"$REPORT" --min-interval abc --sample-window >/dev/null 2>&1
expect_code 2 "$?" "a non-numeric --min-interval must be a usage error"
"$REPORT" --not-a-flag >/dev/null 2>&1
expect_code 2 "$?" "an unknown argument must be a usage error"
pass "malformed arguments exit 2 and are distinguished from runtime refusals"

# --- deduplication ----------------------------------------------------------

DEDUP=$(fixture_dir dedup)
{
  mk_record s1 r1 2026-08-26T10:00:00.000Z /primary claude-sonnet-5 1000000 0 0 false
  mk_record s1 r1 2026-08-26T10:00:01.000Z /primary claude-sonnet-5 1000000 0 0 false
  mk_record s1 r1 2026-08-26T10:00:02.000Z /primary claude-sonnet-5 1000000 0 0 false
} > "$DEDUP/session/a.jsonl"

MODEL=$(run_json --dir "$DEDUP" --primary-dir /primary)
REQS=$(printf '%s' "$MODEL" | jq -r '.requests')
USD=$(printf '%s' "$MODEL" | jq -r '.usd_total')
[ "$REQS" = "1" ] || fail "three chunks of one request must count once, got $REQS"
[ "$USD" = "10" ] || fail "1M Sonnet output tokens must price at \$10, got $USD"
pass "repeated stream chunks of one request are counted once, and pricing follows the model"

# --- role attribution -------------------------------------------------------

ROLES=$(fixture_dir roles)
{
  mk_record p1 rp 2026-08-26T10:00:00.000Z /primary claude-sonnet-5 100 0 0 false
  mk_record c1 rc 2026-08-26T10:00:00.000Z /home/fm/.treehouse/proj-1/proj claude-sonnet-5 100 0 0 false
  mk_record g1 rg 2026-08-26T10:00:00.000Z /home/fm/.no-mistakes/worktrees/abc claude-sonnet-5 100 0 0 false
  mk_record o1 ro 2026-08-26T10:00:00.000Z /Users/someone/sibling-clone claude-sonnet-5 100 0 0 false
} > "$ROLES/session/a.jsonl"

ROLE_LIST=$(run_json --dir "$ROLES" --primary-dir /primary | jq -r '[.by_role[].role] | sort | join(",")')
[ "$ROLE_LIST" = "crewmate,other-clone,pipeline-gate,primary" ] \
  || fail "expected the four role buckets, got '$ROLE_LIST'"
pass "a treehouse, pipeline, declared-primary and unrecognized path each land in their own role"

# An undeclared checkout must NOT be promoted to primary, which would silently
# inflate the primary's share for any fleet that predates the treehouse layout.
UNDECLARED=$(run_json --dir "$ROLES" --primary-dir /somewhere-else | jq -r '[.by_role[] | select(.role=="primary")] | length')
[ "$UNDECLARED" = "0" ] || fail "an undeclared checkout must not be classified primary"
pass "only a declared --primary-dir counts as a primary session"

# --- credit-episode inference ----------------------------------------------

CREDIT=$(fixture_dir credit)
{
  mk_record p1 r1 2026-08-26T10:00:00.000Z /primary claude-sonnet-5 100 5000 0 false
  mk_record p1 r2 2026-08-26T11:00:00.000Z /primary claude-sonnet-5 100 0 5000 false
} > "$CREDIT/session/a.jsonl"

CREDIT_MODEL=$(run_json --dir "$CREDIT" --primary-dir /primary)
EPISODES=$(printf '%s' "$CREDIT_MODEL" | jq -r '.credit_episodes | length')
[ "$EPISODES" = "1" ] || fail "a five-minute main-conversation write must open one credit episode, got $EPISODES"
printf '%s' "$CREDIT_MODEL" | jq -e '.credit_usd_total > 0' >/dev/null \
  || fail "a detected credit episode must carry a non-zero total"
pass "a five-minute main-conversation cache write marks a credit-billed episode"

ONEHOUR=$(fixture_dir onehour)
mk_record p1 r1 2026-08-26T10:00:00.000Z /primary claude-sonnet-5 100 5000 0 false > "$ONEHOUR/session/a.jsonl"
EPISODES=$(run_json --dir "$ONEHOUR" --primary-dir /primary | jq -r '.credit_episodes | length')
[ "$EPISODES" = "0" ] || fail "one-hour writes alone must open no credit episode, got $EPISODES"
pass "usage entirely within the plan's one-hour cache TTL reports no credit episode"

# A subagent always gets the five-minute TTL regardless of billing, so it must
# never be read as evidence of credit spend.
SIDE=$(fixture_dir sidechain)
mk_record p1 r1 2026-08-26T10:00:00.000Z /primary claude-sonnet-5 100 0 5000 true > "$SIDE/session/a.jsonl"
EPISODES=$(run_json --dir "$SIDE" --primary-dir /primary | jq -r '.credit_episodes | length')
[ "$EPISODES" = "0" ] || fail "a subagent's five-minute write must not open a credit episode, got $EPISODES"
pass "a subagent's five-minute cache write is not treated as credit-billing evidence"

# --- --since, repeatable --dir, and output parity ---------------------------

SINCE_REQS=$(run_json --dir "$CREDIT" --primary-dir /primary --since 2026-08-26 | jq -r '.requests')
[ "$SINCE_REQS" = "2" ] || fail "--since on the same day must keep both records, got $SINCE_REQS"
OUT=$("$REPORT" --dir "$CREDIT" --primary-dir /primary --since 2026-08-27 2>&1); CODE=$?
expect_code 1 "$CODE" "--since past every record must refuse"
assert_contains "$OUT" "no records after" "the --since refusal must say why"
pass "--since filters by UTC date and refuses when it excludes every record"

MERGED=$(run_json --dir "$DEDUP" --dir "$ROLES" --primary-dir /primary | jq -r '.requests')
[ "$MERGED" = "5" ] || fail "repeatable --dir must merge every root (expected 5), got $MERGED"
pass "--dir is repeatable so one subscription's fleets are reported together"

JSON_USD=$(run_json --dir "$ROLES" --primary-dir /primary | jq -r '.usd_total')
TOON_USD=$("$REPORT" --dir "$ROLES" --primary-dir /primary 2>/dev/null | sed -n 's/^usd_total: //p')
[ -n "$TOON_USD" ] || fail "the TOON rendering must emit usd_total"
[ "$JSON_USD" = "$TOON_USD" ] || fail "TOON and JSON must agree: json=$JSON_USD toon=$TOON_USD"
pass "the default TOON rendering is in parity with the JSON model"

# --- sampler ----------------------------------------------------------------

FAKEBIN=$TMP_ROOT/fakebin
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nprintf %%s "{\\"quota\\":[]}"\n' > "$FAKEBIN/quota-axi"
chmod +x "$FAKEBIN/quota-axi"

SAMPLE_DATA=$TMP_ROOT/sampledata
mkdir -p "$SAMPLE_DATA"
OUT=$(PATH="$FAKEBIN:$PATH" FM_DATA_OVERRIDE="$SAMPLE_DATA" \
  "$REPORT" --sample-window --dir "$DEDUP" --primary-dir /primary 2>&1); CODE=$?
expect_code 0 "$CODE" "the first sample must succeed"
assert_contains "$OUT" "appended sample" "the first sample must report that it appended"
assert_present "$SAMPLE_DATA/usage-window-samples.tsv" "the sampler must create its durable record"
LINES=$(wc -l < "$SAMPLE_DATA/usage-window-samples.tsv" | tr -d '[:space:]')
[ "$LINES" = "1" ] || fail "the first sample must append exactly one line, got $LINES"

OUT=$(PATH="$FAKEBIN:$PATH" FM_DATA_OVERRIDE="$SAMPLE_DATA" \
  "$REPORT" --sample-window --dir "$DEDUP" --primary-dir /primary 2>&1); CODE=$?
expect_code 0 "$CODE" "a rate-limited sample must still succeed"
assert_contains "$OUT" "skipped" "an immediate second sample must report being skipped"
LINES=$(wc -l < "$SAMPLE_DATA/usage-window-samples.tsv" | tr -d '[:space:]')
[ "$LINES" = "1" ] || fail "the rate limit must not append a second line, got $LINES"
pass "the window sampler appends one durable record and rate-limits an immediate repeat"

OUT=$(PATH="$FAKEBIN:$PATH" FM_DATA_OVERRIDE="$TMP_ROOT/absent-data" \
  "$REPORT" --sample-window --dir "$DEDUP" 2>&1); CODE=$?
expect_code 1 "$CODE" "the sampler must refuse when its data directory is absent"
assert_contains "$OUT" "no data directory" "the sampler's refusal must name the missing directory"
pass "the sampler refuses a missing data directory instead of creating one"

echo "# fm-usage-report.test.sh: all assertions passed"
