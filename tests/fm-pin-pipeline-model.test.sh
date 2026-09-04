#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/bin/fm-pin-pipeline-model.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

shipped_config() {
  cat <<'YAML'
agent: auto
log_level: info

# agent_config:
#   claude:
#     model: sonnet
#     effort: high
YAML
}

test_commented_default_still_gets_pinned() {
  local dir config
  dir=$(mktemp -d)
  config="$dir/config.yaml"
  shipped_config > "$config"

  "$PIN" "$config" >/dev/null || fail "pin failed on shipped config"

  grep -qE '^agent_config:' "$config" || fail "no uncommented agent_config written"
  grep -qF '    model: "opus[1m]"' "$config" || fail "model not pinned to opus[1m]"
  grep -qE '^    effort: xhigh$' "$config" || fail "effort not pinned to xhigh"
  grep -qE '^agent: auto$' "$config" || fail "existing keys lost"
  rm -rf "$dir"
  pass "a commented agent_config block does not count as already pinned"
}

test_existing_choice_is_never_overwritten() {
  local dir config before after
  dir=$(mktemp -d)
  config="$dir/config.yaml"
  printf 'agent_config:\n  claude:\n    model: sonnet\n    effort: low\n' > "$config"
  before=$(cat "$config")

  "$PIN" "$config" >/dev/null || fail "pin failed on already-pinned config"

  after=$(cat "$config")
  [ "$before" = "$after" ] || fail "deliberate agent_config was rewritten"
  rm -rf "$dir"
  pass "an existing agent_config is left exactly as found"
}

test_pin_is_idempotent() {
  local dir config once twice
  dir=$(mktemp -d)
  config="$dir/config.yaml"
  shipped_config > "$config"

  "$PIN" "$config" >/dev/null || fail "first pin failed"
  once=$(cat "$config")
  "$PIN" "$config" >/dev/null || fail "second pin failed"
  twice=$(cat "$config")

  [ "$once" = "$twice" ] || fail "second run changed the file"
  [ "$(grep -cE '^agent_config:' "$config")" = 1 ] || fail "agent_config duplicated"
  rm -rf "$dir"
  pass "running twice writes the block once"
}

test_absent_config_is_a_clean_noop() {
  local dir config
  dir=$(mktemp -d)
  config="$dir/config.yaml"

  "$PIN" "$config" >/dev/null || fail "pin failed when config is absent"

  [ ! -e "$config" ] || fail "pin created a config that no-mistakes never wrote"
  rm -rf "$dir"
  pass "an absent config is left absent"
}

test_commented_default_still_gets_pinned
test_existing_choice_is_never_overwritten
test_pin_is_idempotent
test_absent_config_is_a_clean_noop
