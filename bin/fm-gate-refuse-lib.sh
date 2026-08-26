# The exit code every refusal uses, distinct enough to recognize in a caller or
# test as "the gate refusal fired" rather than an ordinary usage error.
FM_GATE_REFUSE_EXIT=3

# fm_is_gate_agent: return 0 without output when this process looks like a
# no-mistakes gate agent. An optional root anchors the git-common-dir check;
# callers that omit it retain the historical current-worktree behavior.
fm_is_gate_agent() {
  local anchor=${1:-.} common
  if [ "${FM_GATE_REFUSE_BYPASS:-}" = 1 ]; then
    return 1
  fi
  if [ "${NO_MISTAKES_GATE+x}" = x ]; then
    FM_GATE_REFUSE_REASON='env'
    return 0
  fi
  common=$(cd "$anchor" 2>/dev/null \
    && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo /nonexistent)" 2>/dev/null \
    && pwd -P || true)
  case "$common" in
    */.no-mistakes/repos/*.git)
      FM_GATE_REFUSE_REASON='path'
      FM_GATE_REFUSE_COMMON=$common
      return 0 ;;
  esac
  return 1
}

# fm_refuse_if_gate_agent: exit FM_GATE_REFUSE_EXIT with a clear stderr message if
# this process looks like a no-mistakes gate agent. Call before any fleet
# mutation. No-ops (returns 0) for a normal firstmate session, or when firstmate's
# own test harness sets FM_GATE_REFUSE_BYPASS=1 (see the header).
fm_refuse_if_gate_agent() {
  fm_is_gate_agent "${1:-.}" || return 0
  if [ "$FM_GATE_REFUSE_REASON" = env ]; then
    echo "error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)" >&2
  else
    echo "error: refusing fleet lifecycle from inside a no-mistakes gate worktree ($FM_GATE_REFUSE_COMMON)" >&2
  fi
  exit "$FM_GATE_REFUSE_EXIT"
}
