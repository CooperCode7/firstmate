#!/usr/bin/env bash
# fm-usage-report.sh - read-only token-usage and cost attribution over Claude Code transcripts.
#
# Answers "where did the tokens go" for a fleet without any telemetry pipeline:
# every Claude Code session already records per-request usage (uncached input,
# cache creation split by 5m/1h TTL, cache reads, output) plus model, effort,
# subagent flag and working directory into JSONL under its config dir's
# projects/. This reads those transcripts and attributes spend.
#
# Output contract: `--json` prints one object with schema `fm-usage-report.v1`.
# The default renders that same model as TOON at the output boundary; the two are
# parity representations. Read-only: it takes no session lock, drains no wakes,
# and writes nothing except under --sample-window.
#
# Usage:
#   fm-usage-report.sh [--dir <transcripts-dir>] [--since <YYYY-MM-DD>] [--json]
#   fm-usage-report.sh --sample-window [--min-interval <seconds>]
#   fm-usage-report.sh --help
#
#   --dir            transcripts root; default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects.
#                    Point it at a mounted volume to analyze another home's fleet. Repeatable:
#                    one subscription's usage window and credit spend span every fleet on it, so
#                    pass every home to get a correct credit figure rather than a per-home slice.
#   --primary-dir    a primary checkout path, repeatable; default this checkout's root.
#   --since          drop requests before this UTC date.
#   --json           print the internal JSON model verbatim instead of TOON.
#   --sample-window  append one timestamped quota-plus-tokens sample for session-window
#                    calibration, then exit. Self-rate-limited; see --min-interval.
#   --min-interval   seconds that must elapse between samples (default 300).
#
# Deduplication: a streamed response repeats the same usage object across chunks,
# so records are deduplicated on (sessionId, requestId) before summing. Skipping
# that inflates every total several-fold and is the single correctness trap here.
#
# Costs are list-price equivalents computed from token counts, not an invoice.
# They are the right basis for credit-billed usage, which bills at standard API rates.
#
# Role attribution is by working-directory shape, not by task id: a treehouse path is a
# crewmate, a no-mistakes path is a pipeline gate agent, a cwd equal to a declared primary
# checkout is a primary session, and anything else is an unclassified clone. Declare each
# primary with --primary-dir; without it only this checkout counts, so another home's
# transcripts (a container fleet read from the host) would otherwise misattribute. A fleet
# that predates the treehouse layout used plain sibling clones, which land in other-clone
# rather than being silently counted as primaries. Task-level attribution is not possible
# for runs whose worktrees were already torn down, and is not claimed.
#
# Credit-billed episodes are inferred: within plan usage the main conversation gets a
# one-hour prompt-cache TTL, and it drops to five minutes once usage spills onto
# credits. Five-minute main-conversation cache writes therefore mark credit-billed
# periods. The inference is void if a TTL is pinned by promptCacheTtl,
# CLAUDE_CODE_PROMPT_CACHE_TTL or FORCE_PROMPT_CACHING_5M, and it can only see periods
# in which a primary session was actively making requests, so the total is a lower bound.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() { sed -n '2,32{s/^# \{0,1\}//;s/^#$//;p;}' "$0"; }

DIRS=""
SINCE=""
PRIMARIES=""
AS_JSON=0
SAMPLE=0
MIN_INTERVAL=300
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) AS_JSON=1 ;;
    --sample-window) SAMPLE=1 ;;
    --dir)
      [ "$#" -ge 2 ] || { echo "error: --dir requires a value" >&2; exit 2; }
      [ -d "$2" ] || { echo "error: no transcripts directory at $2" >&2; exit 1; }
      DIRS="$DIRS$2"$'\n'
      shift ;;
    --primary-dir)
      [ "$#" -ge 2 ] || { echo "error: --primary-dir requires a value" >&2; exit 2; }
      PRIMARIES="$PRIMARIES$2"$'\n'
      shift ;;
    --since) [ "$#" -ge 2 ] || { echo "error: --since requires a value" >&2; exit 2; }; SINCE=$2; shift ;;
    --min-interval) [ "$#" -ge 2 ] || { echo "error: --min-interval requires a value" >&2; exit 2; }; MIN_INTERVAL=$2; shift ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required and was not found on PATH" >&2; exit 1; }
case "$MIN_INTERVAL" in ''|*[!0-9]*) echo "error: --min-interval must be a whole number of seconds" >&2; exit 2 ;; esac
if [ -n "$SINCE" ]; then
  case "$SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) echo "error: --since must be YYYY-MM-DD" >&2; exit 2 ;;
  esac
fi

if [ "$SAMPLE" -eq 1 ]; then
  command -v quota-axi >/dev/null 2>&1 || { echo "error: --sample-window needs quota-axi on PATH" >&2; exit 1; }
  [ -d "$DATA" ] || { echo "error: no data directory at $DATA" >&2; exit 1; }
  OUT=$DATA/usage-window-samples.tsv
  NOW=$(date -u +%s)
  if [ -f "$OUT" ]; then
    LAST=$(awk -F'\t' 'END{print $1}' "$OUT" 2>/dev/null || echo 0)
    case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
    if [ "$((NOW - LAST))" -lt "$MIN_INTERVAL" ]; then
      echo "fm-usage-report: skipped, last sample was $((NOW - LAST))s ago (min ${MIN_INTERVAL}s)"
      exit 0
    fi
  fi
  QUOTA=$(quota-axi --json 2>/dev/null | jq -c '.' 2>/dev/null) || QUOTA=""
  [ -n "$QUOTA" ] || { echo "error: quota-axi produced no parseable output" >&2; exit 1; }
  SAMPLE_ARGS=""
  if [ -n "$DIRS" ]; then
    while IFS= read -r d; do [ -n "$d" ] && SAMPLE_ARGS="$SAMPLE_ARGS --dir $d"; done <<EOF
$DIRS
EOF
  fi
  # shellcheck disable=SC2086 # deliberate word splitting of the accumulated --dir list
  TOTALS=$("$0" $SAMPLE_ARGS --json \
    | jq -c '{requests, input_tok, cache_write_tok, cache_read_tok, output_tok}')
  printf '%s\t%s\t%s\t%s\n' "$NOW" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TOTALS" "$QUOTA" >> "$OUT"
  echo "fm-usage-report: appended sample to $OUT"
  exit 0
fi

if [ -z "$DIRS" ]; then
  DIRS=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects$'\n'
  [ -d "${DIRS%$'\n'}" ] || { echo "error: no transcripts directory at ${DIRS%$'\n'}" >&2; exit 1; }
fi
DIR_LIST=$(printf '%s' "$DIRS" | sed '/^$/d' | paste -sd, -)
[ -n "$PRIMARIES" ] || PRIMARIES="$FM_ROOT"$'\n'
PRIMARY_JSON=$(printf '%s' "$PRIMARIES" | sed '/^$/d' | jq -R . | jq -sc .)

TMP=$(mktemp "${TMPDIR:-/tmp}/fm-usage-report.XXXXXX") || { echo "error: could not create a temporary file" >&2; exit 1; }
trap 'rm -f "$TMP"' EXIT INT TERM

# shellcheck disable=SC2016 # jq program: $-vars are jq's, not the shell's
EXTRACT='
select(.type=="assistant" and .message.usage != null)
| (.cwd // "") as $c
| {sid: .sessionId,
   role: (if ($c|test("/\\.treehouse/")) then "crewmate"
          elif ($c|test("/\\.no-mistakes/")) then "pipeline-gate"
          elif (($primaries | index($c)) != null) then "primary"
          else "other-clone" end),
   project: ($c | split("/") | last),
   req: (.requestId // .message.id // ""),
   model: (.message.model // "unknown"),
   effort: (.effort // "default"),
   side: (.isSidechain // false),
   i: (.message.usage.input_tokens // 0),
   cw: (.message.usage.cache_creation_input_tokens // 0),
   cr: (.message.usage.cache_read_input_tokens // 0),
   o:  (.message.usage.output_tokens // 0),
   cw1h: (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0),
   cw5m: (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0),
   ts: (.timestamp // "")}
| select(.req != "" and .ts != "")'

# find -exec ... + rather than a pipe into xargs: with no matching file GNU xargs
# still runs the command once, which would leave jq reading this loop's stdin and
# writing junk that defeats the no-records refusal below. -exec + never runs on
# zero matches, and keeps stdin free either way.
while IFS= read -r d; do
  [ -n "$d" ] || continue
  find "$d" -name '*.jsonl' -type f \
    -exec jq -c --argjson primaries "$PRIMARY_JSON" "$EXTRACT" {} + >> "$TMP" 2>/dev/null || true
done <<EOF
$DIRS
EOF

[ -s "$TMP" ] || { echo "error: no usage records found under $DIR_LIST" >&2; exit 1; }

MODEL=$(jq -n --arg dir "$DIR_LIST" --arg since "$SINCE" --argjson primaries "$PRIMARY_JSON" '
def pct(p): if length == 0 then 0 else (sort | .[((length - 1) * p) | floor]) end;
def r2: . * 100 | round / 100;
def ep: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def price:
  if (.model|test("fable-5-1")) then {i:10, w5:12.5, w1:20, r:0.25, o:50}
  elif (.model|test("fable")) then {i:10, w5:12.5, w1:20, r:1, o:50}
  elif (.model|test("opus")) then {i:5, w5:6.25, w1:10, r:0.5, o:25}
  elif (.model|test("sonnet")) then {i:2, w5:2.5, w1:4, r:0.2, o:10}
  elif (.model|test("haiku")) then {i:1, w5:1.25, w1:2, r:0.1, o:5}
  else {i:0, w5:0, w1:0, r:0, o:0} end;
def parts: price as $p
  | {input: (.i * $p.i),
     cache_write: (.cw5m * $p.w5 + .cw1h * $p.w1 + (([.cw - .cw5m - .cw1h, 0] | max) * $p.w5)),
     cache_read: (.cr * $p.r),
     output: (.o * $p.o)}
  | map_values(. / 1000000);
def usd: parts | add;
def sum(f): map(f) | add // 0;
def ctx: .i + .cw + .cr;

[inputs]
| unique_by(.sid, .req)
| (if $since == "" then . else map(select(.ts >= $since)) end)
| . as $all
| if ($all | length) == 0 then {error: "no records after --since filter"} else
  ($all | sum(usd)) as $U
  | (($U | if . == 0 then 1 else . end)) as $Unz
  | ($all | map(.ts) | (max | ep) - (min | ep)) as $span
  | (($span / 86400) | if . < 1 then 1 else . end) as $days
  | ($all | map(select(.role == "primary" and .side == false and .cw5m > 0)) | sort_by(.ts) | map(.ts | ep)) as $marks
  | ($marks | reduce .[] as $t ([];
      if (length == 0) or ($t - (.[-1][-1])) > 3600 then . + [[$t]] else (.[0:-1] + [.[-1] + [$t]]) end)) as $eps
  | ($eps | map({s: .[0], e: .[-1]})) as $wins
  | {
    schema: "fm-usage-report.v1",
    generated: (now | todate),
    transcripts_dirs: $dir,
    since: (if $since == "" then "all" else $since end),
    primary_dirs: ($primaries | join(",")),
    sessions: ($all | map(.sid) | unique | length),
    requests: ($all | length),
    span_start: ($all | map(.ts) | min),
    span_end: ($all | map(.ts) | max),
    days: ($days | round),
    input_tok: ($all | sum(.i)),
    cache_write_tok: ($all | sum(.cw)),
    cache_read_tok: ($all | sum(.cr)),
    output_tok: ($all | sum(.o)),
    cache_write_1h_tok: ($all | sum(.cw1h)),
    cache_write_5m_tok: ($all | sum(.cw5m)),
    usd_total: ($U | r2),
    usd_per_day: (($U / $days) | r2),
    share_input_pct: ($all | sum(parts.input) / $Unz * 100 | round),
    share_cache_write_pct: ($all | sum(parts.cache_write) / $Unz * 100 | round),
    share_cache_read_pct: ($all | sum(parts.cache_read) / $Unz * 100 | round),
    share_output_pct: ($all | sum(parts.output) / $Unz * 100 | round),
    subagent_share_pct: ($all | (map(select(.side)) | sum(usd)) / $Unz * 100 | round),
    cold_start_p50_tok: ($all | group_by(.sid) | map(sort_by(.ts) | .[0] | .cw) | pct(0.5)),
    cold_start_share_pct: ($all | group_by(.sid) | map(sort_by(.ts) | .[0] | parts.cache_write) | (add // 0) / $Unz * 100 | r2),
    credit_usd_total: ($wins | map(. as $w | $all | map(select((.ts|ep) >= $w.s and (.ts|ep) <= $w.e)) | sum(usd)) | (add // 0) | r2),
    credit_share_pct: (($wins | map(. as $w | $all | map(select((.ts|ep) >= $w.s and (.ts|ep) <= $w.e)) | sum(usd)) | (add // 0)) / $Unz * 100 | r2),
    by_role: ($all | group_by(.role) | map({
        role: .[0].role,
        sessions: (map(.sid) | unique | length),
        requests: length,
        usd: (sum(usd) | r2),
        share_pct: (sum(usd) / $Unz * 100 | round),
        ctx_p50: (map(ctx) | pct(0.5)),
        ctx_p90: (map(ctx) | pct(0.9)),
        over_200k_pct: ((map(select(ctx > 200000)) | length) / length * 100 | round),
        read_to_write: ((sum(.cr) / ([sum(.cw), 1] | max)) | round)
      }) | sort_by(-.usd)),
    by_model: ($all | group_by(.model) | map({
        model: .[0].model,
        requests: length,
        usd: (sum(usd) | r2),
        share_pct: (sum(usd) / $Unz * 100 | round)
      }) | sort_by(-.usd)),
    credit_episodes: ($wins | to_entries | map(.value as $w | {
        episode: (.key + 1),
        start: ($w.s | todate),
        end: ($w.e | todate),
        minutes: ((($w.e - $w.s) / 60) | round),
        requests: ($all | map(select((.ts|ep) >= $w.s and (.ts|ep) <= $w.e)) | length),
        usd: ($all | map(select((.ts|ep) >= $w.s and (.ts|ep) <= $w.e)) | sum(usd) | r2)
      }))
  } end' "$TMP") || { echo "error: usage model could not be computed from $DIR_LIST" >&2; exit 1; }

if printf '%s' "$MODEL" | jq -e 'has("error")' >/dev/null 2>&1; then
  printf '%s' "$MODEL" | jq -r '"error: " + .error' >&2
  exit 1
fi

if [ "$AS_JSON" -eq 1 ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# TOON renderer (output boundary; parity with the JSON model). Encoder shape and
# quoting follow bin/fm-bearings-snapshot.sh, the repo's TOON owner.
printf '%s\n' "$MODEL" | jq -r '
  def q:
    tostring
    | if (. == "")
        or test("^\\s|\\s$")
        or (. == "true" or . == "false" or . == "null")
        or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
        or test("[:\"\\\\\\[\\]{},]")
        or test("[[:cntrl:]]")
        or test("^-")
      then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
      else . end;
  def scal:
    if . == null then "null"
    elif type == "boolean" then (if . then "true" else "false" end)
    elif type == "number" then tostring
    else q end;
  def emit($k; $v):
    if ($v | type) == "array" then
      if ($v | length) == 0 then "\($k): []"
      else
        ($v[0] | keys_unsorted) as $ks
        | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
            ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
      end
    else "\($k): " + ($v | scal)
    end;
  [ to_entries[] | emit(.key; .value) ] | join("\n")
' || { echo "error: TOON rendering failed" >&2; exit 1; }
