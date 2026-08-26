#!/usr/bin/env bash
# Tests for fm-tool-update-check.sh, the watched tooling update report.
#
# The case that matters most is PATH skew: a tool that has already installed its
# newer copy, while PATH still resolves an older one. On 2026-08-20 that exact
# shape broke this fleet. Herdr self-installed 0.8.2 into ~/.local/bin, a version
# manager kept its own 0.8.0 earlier on PATH inside a directory named "latest",
# and every Herdr command then failed on a protocol mismatch. A check that only
# asks "is a newer version published" reports everything up to date and misses
# it, so test_path_skew_is_reported_from_every_copy reproduces the incident and
# asserts the report names the older copy PATH resolves AND the newer copy that
# is already installed. A single `command -v` lookup cannot know the second
# version, so that assertion fails against any build without real per-copy
# probing.
#
# The fixtures use a synthetic command name and their own temporary PATH
# directories, so no case ever probes, launches, or otherwise touches a tool
# actually installed on this host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-tool-update-check.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-tool-update-check)

# Exported here, at the top level, because git_fixture runs inside a command
# substitution and an export from that subshell never reaches the cases, which
# make fixture commits of their own. A host with no git identity configured
# would otherwise fail those commits and leave the fixture in a shape the case
# did not ask for.
fm_git_identity fmtest fmtest@example.invalid

# The incident's tool, under a name that cannot exist on this host.
TOOL=herdr-fixture

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# make_copy <dir> <command> <version-output>: an executable copy that answers
# --version with the given text and nothing else.
make_copy() {
  local dir=$1 command_name=$2 text=$3
  mkdir -p "$dir"
  cat > "$dir/$command_name" <<SH
#!/usr/bin/env bash
printf '%s\n' '$text'
SH
  chmod 0755 "$dir/$command_name"
}


# make_counting_copy <dir> <command> <version-output> <log>: the same copy, which
# also appends one line to <log> every time it runs, so a case can assert how
# many times the check actually probed it.
make_counting_copy() {
  local dir=$1 command_name=$2 text=$3 log=$4
  mkdir -p "$dir"
  cat > "$dir/$command_name" <<SH
#!/usr/bin/env bash
printf 'probed\n' >> '$log'
printf '%s\n' '$text'
SH
  chmod 0755 "$dir/$command_name"
}

write_config() {
  local home=$1
  shift
  printf '%s\n' "$*" > "$home/config/watched-tools.json"
}

# The fixture directories first, then the ambient PATH, which the check needs
# because it shells out to ordinary tools such as jq, git, date, grep, stat, and
# timeout. What keeps a tool installed on this host out of a fixture is the
# synthetic command name, not this PATH, so every case watches a command name
# that cannot exist here.
fixture_path() {
  printf '%s:%s\n' "$1" "$PATH"
}

# The watcher check timeout is pinned to its documented default here, because the
# sweep budget is cut to fit it and an operator's ambient value would otherwise
# add a report line to cases that mean to be silent. The one case that exercises
# the cut sets its own value.
run_check() {
  local home=$1 path=$2 out=$3
  shift 3
  local status=0
  env FM_CHECK_TIMEOUT=30 "$@" FM_HOME="$home" PATH="$path" FM_TOOL_UPDATE_INTERVAL=0 "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

# --- the regression this script exists for ----------------------------------







# --- published updates ------------------------------------------------------

make_slow_copy() {
  local dir=$1 command_name=$2 seconds=$3
  mkdir -p "$dir"
  cat > "$dir/$command_name" <<SH
#!/usr/bin/env bash
sleep $seconds
printf 'herdr 0.8.2\n'
SH
  chmod 0755 "$dir/$command_name"
}

test_announced_update_is_reported_from_the_tool_itself() {
  local home dir out report
  # no-mistakes already announces its own update on stderr; read that rather
  # than reimplementing its version lookup.
  home=$(make_home announce)
  dir="$TMP_ROOT/announce/bin"
  mkdir -p "$dir"
  cat > "$dir/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
printf '1.46.0\n'
printf 'A new version of no-mistakes is available: v1.46.0 -> v1.47.0\n' >&2
SH
  chmod 0755 "$dir/no-mistakes-fixture"
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out"
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes update available: A new version of no-mistakes is available: v1.46.0 -> v1.47.0" "the tool's own update announcement was not reported"
  assert_not_contains "$report" "not in effect" "a published update must not be reported as PATH skew"
  pass "a tool's own update announcement is read from its output"
}

test_announcement_is_read_from_a_second_command() {
  local home dir out report quiet_home
  # The real no-mistakes prints its version for --version but announces a new
  # release only on its other commands, so the announcement has to be asked of a
  # command of its own while the version probe keeps reporting the version.
  home=$(make_home announce-args)
  dir="$TMP_ROOT/announce-args/bin"
  mkdir -p "$dir"
  cat > "$dir/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'no-mistakes version v1.46.0\n'
  exit 0
fi
printf 'A new version of no-mistakes is available: v1.46.0 -> v1.53.0\n' >&2
printf 'Usage: no-mistakes <command>\n'
SH
  chmod 0755 "$dir/no-mistakes-fixture"
  out="$home/out.txt"

  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","version_args":["--version"],"announce_args":["--help"],"announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  run_check "$home" "$(fixture_path "$dir")" "$out"
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes update available: A new version of no-mistakes is available: v1.46.0 -> v1.53.0" "the announcement was not read from the command that carries it"
  assert_not_contains "$report" "check failed" "the version probe stopped reporting this copy's version"

  # Control: the same tool watched without announce_args sees only the version
  # probe, which never carries the announcement, so the update is missed.
  quiet_home=$(make_home announce-args-control)
  write_config "$quiet_home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","version_args":["--version"],"announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  run_check "$quiet_home" "$(fixture_path "$dir")" "$quiet_home/out.txt"
  [ ! -s "$quiet_home/out.txt" ] || fail "the control home reported without a second command, so this test proves nothing: $(cat "$quiet_home/out.txt")"
  pass "an announcement carried by another command is read from that command"
}

test_unusable_announce_pattern_is_reported_not_read_as_silence() {
  local home dir out status
  # A pattern the search cannot use answers exactly like a tool with nothing to
  # announce, which is the silently dead update source this check exists to
  # prevent. It is reported as that tool's own check failure.
  home=$(make_home bad-pattern)
  dir="$TMP_ROOT/bad-pattern/bin"
  make_copy "$dir" no-mistakes-fixture 'no-mistakes version v1.46.0'
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","announce_pattern":"A new version of no-mistakes is available: ([^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out"
  assert_contains "$(cat "$out")" "no-mistakes check failed: announce_pattern is not a usable extended regular expression" "a pattern that cannot be used was read as nothing to announce"

  # Arming is a deliberate operator action, so the same registry refuses it
  # rather than arming a check with a source that can never fire.
  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm with an unusable announce_pattern exit"
  assert_absent "$home/state/tool-updates.check.sh" "arm registered a check whose announcement source cannot fire"
  pass "an announce_pattern that cannot be used is reported instead of read as silence"
}


test_an_unchecked_announcement_source_is_not_read_as_current() {
  local home dir out report
  # When the budget is gone the separate announcement command cannot run, and the
  # version probe's output never carries the announcement. Searching that output
  # anyway would present a source that was never asked as a clean result, which is
  # the same silently dead source announce_args was added to close.
  home=$(make_home announce-budget)
  dir="$TMP_ROOT/announce-budget/bin"
  mkdir -p "$dir"
  cat > "$dir/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'no-mistakes version v1.46.0\n'
  sleep 30
  exit 0
fi
printf 'A new version of no-mistakes is available: v1.46.0 -> v1.53.0\n' >&2
SH
  chmod 0755 "$dir/no-mistakes-fixture"
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","version_args":["--version"],"announce_args":["--help"],"announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out" FM_TOOL_UPDATE_BUDGET_SECS=1
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes check failed: the time budget ran out before the update announcement was checked" "an announcement source that was never asked was not reported"
  pass "an announcement source the budget could not reach is reported, not read as current"
}

test_an_announcement_probe_that_does_not_answer_is_reported() {
  local home dir out report
  # no-mistakes learns about a new release from the network, so the command that
  # carries the announcement is exactly the one that stalls on a flaky link. A
  # source that was asked and never answered must not read as a clean sweep.
  home=$(make_home announce-mute)
  dir="$TMP_ROOT/announce-mute/bin"
  mkdir -p "$dir"
  cat > "$dir/no-mistakes-fixture" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'no-mistakes version v1.46.0\n'
  exit 0
fi
sleep 30
SH
  chmod 0755 "$dir/no-mistakes-fixture"
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","version_args":["--version"],"announce_args":["--help"],"announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  report=$(cat "$out")
  assert_contains "$report" "no-mistakes check failed: $dir/no-mistakes-fixture did not answer when asked for its update announcement" "an announcement probe that never answered was read as a clean sweep"
  pass "an announcement probe that does not answer is reported, not read as current"
}

test_quiet_tool_with_announce_pattern_is_silent() {
  local home dir out
  home=$(make_home announce-quiet)
  dir="$TMP_ROOT/announce-quiet/bin"
  make_copy "$dir" no-mistakes-fixture '1.46.0'
  write_config "$home" '{"tools":[{"name":"no-mistakes","command":"no-mistakes-fixture","announce_pattern":"A new version of no-mistakes is available: [^ ]+ -> [^ ]+"}]}'
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out"
  [ ! -s "$out" ] || fail "a tool announcing nothing produced a report: $(cat "$out")"
  pass "a tool that announces nothing stays silent"
}

# --- git sources ------------------------------------------------------------

# git_fixture <name>: a work repo whose origin branch is two commits ahead,
# with those commits already present locally so the count is exact.
git_fixture() {
  local name=$1 bare work
  bare="$TMP_ROOT/$name.git"
  work="$TMP_ROOT/$name"
  git init -q --bare --initial-branch=main "$bare"
  git clone -q "$bare" "$work" 2>/dev/null
  printf 'one\n' > "$work/f1"
  git -C "$work" add f1
  git -C "$work" commit -qm one
  printf 'two\n' > "$work/f2"
  git -C "$work" add f2
  git -C "$work" commit -qm two
  printf 'three\n' > "$work/f3"
  git -C "$work" add f3
  git -C "$work" commit -qm three
  git -C "$work" push -q origin main
  git -C "$work" remote set-head origin main >/dev/null 2>&1
  printf '%s\n' "$work"
}

test_commits_behind_origin_are_reported() {
  local home work out head_before
  home=$(make_home git-behind)
  work=$(git_fixture git-behind-repo)
  git -C "$work" reset -q --hard HEAD~2
  head_before=$(git -C "$work" rev-parse HEAD)
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate update available: local main is 2 commits behind origin/main" "commits behind the origin branch were not reported"
  # The probe is read-only: the watched repository must be untouched.
  [ "$(git -C "$work" rev-parse HEAD)" = "$head_before" ] || fail "the check moved the watched repository's HEAD"
  git -C "$work" diff --quiet || fail "the check left changes in the watched repository"
  pass "commits behind the origin branch are reported without touching the repository"
}

test_default_branch_is_detected_when_branch_is_omitted() {
  local home work out
  home=$(make_home git-default)
  work=$(git_fixture git-default-repo)
  git -C "$work" reset -q --hard HEAD~1
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate update available: local main is 1 commit behind origin/main" "the default branch was not detected from the remote"
  pass "an omitted branch is detected from the remote's default branch"
}

test_default_branch_is_asked_of_the_remote_when_the_clone_has_no_record() {
  local home work out
  # A --single-branch clone, or one that never ran remote set-head, has no local
  # refs/remotes/origin/HEAD. The remote still knows its default branch, so this
  # must report the update rather than an unactionable check failure.
  home=$(make_home git-symref)
  work=$(git_fixture git-symref-repo)
  git -C "$work" remote set-head origin --delete >/dev/null 2>&1
  git -C "$work" reset -q --hard HEAD~2
  # Ask git what it knows rather than looking for a loose ref file, which never
  # exists under a non-loose ref backend and would make this vacuous there.
  ! git -C "$work" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 \
    || fail "the fixture still records the remote's default branch locally"
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate update available: local main is 2 commits behind origin/main" "the default branch was not asked of the remote"
  pass "the default branch is asked of the remote when the clone has no local record"
}

test_current_and_ahead_repositories_are_silent() {
  local home work out
  home=$(make_home git-current)
  work=$(git_fixture git-current-repo)
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  [ ! -s "$out" ] || fail "an up to date repository produced a report: $(cat "$out")"

  printf 'local only\n' > "$work/f4"
  git -C "$work" add f4
  git -C "$work" commit -qm four
  rm -f "$home/state/.tool-updates"
  run_check "$home" "$PATH" "$out"
  [ ! -s "$out" ] || fail "a repository ahead of its origin branch produced a report: $(cat "$out")"
  pass "a repository that is current or ahead of its origin branch is silent"
}

test_unusable_git_source_is_reported() {
  local home out
  home=$(make_home git-broken)
  mkdir -p "$TMP_ROOT/git-broken/not-a-repo"
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$TMP_ROOT/git-broken/not-a-repo\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate check failed" "an unusable git source was not reported"
  pass "an unusable git source is reported as a check failure"
}

test_unreadable_remote_is_not_reported_as_a_missing_branch() {
  local home work out report
  # A remote that cannot be reached at all and a branch that was deleted are
  # different problems with different repairs. Reporting the first as the second
  # wakes firstmate with a diagnosis that is simply wrong, so the report must
  # name only what the probe established.
  home=$(make_home git-unreadable)
  work=$(git_fixture git-unreadable-repo)
  rm -rf "$TMP_ROOT/git-unreadable-repo.git"
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  report=$(cat "$out")
  assert_contains "$report" "firstmate check failed" "a remote that could not be read was not reported"
  assert_contains "$report" "origin could not be reached or read" "the report does not name the condition the probe actually found"
  assert_not_contains "$report" "has no branch" "a remote that could not be read was reported as a deleted branch"
  pass "a remote that cannot be read is reported as unreadable, not as a missing branch"
}

test_missing_branch_on_a_readable_remote_is_still_reported() {
  local home work out
  # The other side of the case above: the remote answers, and it really does not
  # have the watched branch, so that must still be reported as a missing branch.
  home=$(make_home git-no-branch)
  work=$(git_fixture git-no-branch-repo)
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"release\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  assert_contains "$(cat "$out")" "firstmate check failed: origin has no branch release" "a branch the remote does not have was not reported as missing"
  pass "a branch a readable remote does not have is still reported as missing"
}

test_git_probes_stop_when_the_sweep_budget_is_gone() {
  local home work slow out report
  # The git probes are the several-in-a-row case, two of them over the network,
  # so they are the ones that can push a sweep past the watcher's own timeout and
  # leave it killed with nothing printed at all. Here the tool's command probe
  # spends the whole budget, so its git probes must not start: the sweep says
  # which tool it did not finish instead of quietly running on.
  home=$(make_home git-budget)
  work=$(git_fixture git-budget-repo)
  git -C "$work" reset -q --hard HEAD~2
  slow="$TMP_ROOT/git-budget/bin"
  make_slow_copy "$slow" "$TOOL" 30
  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"command\":\"$TOOL\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$slow")" "$out" FM_TOOL_UPDATE_BUDGET_SECS=1
  report=$(cat "$out")
  assert_contains "$report" "check incomplete: the time budget ran out before firstmate" "a sweep with no budget left did not say which tool it did not finish"
  assert_not_contains "$report" "commits behind" "the git probes ran after the sweep budget was already gone"
  pass "git probes stop and name their tool once the sweep budget is gone"
}

test_a_git_probe_that_does_not_answer_is_not_an_update() {
  local home work dir out report head_before
  # The local git probes are bounded too, so a bound that is hit must not be read
  # as the answer "this clone does not have that commit". This clone is ahead of
  # its remote branch, which is silent when the probes answer, so any claim of an
  # available update here was never established.
  home=$(make_home git-mute)
  work=$(git_fixture git-mute-repo)
  printf 'local only\n' > "$work/f4"
  git -C "$work" add f4
  git -C "$work" commit -qm four
  head_before=$(git -C "$work" rev-parse HEAD)

  # A git that answers everything except the object query, which never answers.
  dir="$TMP_ROOT/git-mute/bin"
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = cat-file ]; then
    sleep 30
    exit 0
  fi
done
exec $(command -v git) "\$@"
SH
  chmod 0755 "$dir/git"

  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  # The bound is wide enough that the earlier probes answer comfortably, so the
  # only probe that can hit it is the object query the fixture stalls. Asserting
  # that specific report keeps an unrelated timeout from passing this case for the
  # wrong reason.
  run_check "$home" "$(fixture_path "$dir")" "$out" FM_TOOL_UPDATE_PROBE_SECS=3
  report=$(cat "$out")
  assert_not_contains "$report" "update available" "a probe that never answered was reported as an available update"
  assert_contains "$report" "firstmate check failed: $work did not answer whether it already has" "the stalled object query was not the reported failure"
  [ "$(git -C "$work" rev-parse HEAD)" = "$head_before" ] || fail "the check moved the watched repository's HEAD"
  pass "a git probe that does not answer is reported as a failure, never as an update"
}

test_a_stalled_repository_probe_is_not_reported_as_not_a_repository() {
  local home work dir out report
  # The very first git probe is bounded too. A clone on a stalled mount that
  # never answers must be reported as not answering, not as not being a git
  # repository, which is a diagnosis the probe never established.
  home=$(make_home git-stall)
  work=$(git_fixture git-stall-repo)
  git -C "$work" reset -q --hard HEAD~2

  dir="$TMP_ROOT/git-stall/bin"
  mkdir -p "$dir"
  cat > "$dir/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = rev-parse ]; then
    sleep 30
    exit 0
  fi
done
exec $(command -v git) "\$@"
SH
  chmod 0755 "$dir/git"

  write_config "$home" "{\"tools\":[{\"name\":\"firstmate\",\"git\":{\"repo\":\"$work\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$dir")" "$out" FM_TOOL_UPDATE_PROBE_SECS=1
  report=$(cat "$out")
  assert_contains "$report" "firstmate check failed: $work did not answer whether it is a git repository" "a repository probe that never answered was not reported as such"
  assert_not_contains "$report" "is not a git repository" "a repository probe that never answered was reported as not a repository"
  pass "a stalled repository probe is reported as no answer, not as not a repository"
}

# --- registry and reporting contract ----------------------------------------

test_absent_registry_is_silent() {
  local home out
  home=$(make_home no-config)
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  [ ! -s "$out" ] || fail "check spoke without a watched tool registry: $(cat "$out")"
  assert_absent "$home/state/.tool-updates" "check wrote a record without a registry"
  pass "no watched tool registry means no output at all"
}



test_an_overlong_report_says_it_was_cut() {
  local home out report i tools=
  # Many watched tools can outgrow one line. The report must say it was cut
  # rather than end mid-finding as if that were everything found.
  home=$(make_home long)
  for i in $(seq 1 30); do
    [ -z "$tools" ] || tools="$tools,"
    tools="$tools{\"name\":\"absent-tool-$i\",\"command\":\"fm-absent-fixture-$i\"}"
  done
  write_config "$home" "{\"tools\":[$tools]}"
  out="$home/out.txt"
  run_check "$home" "$PATH" "$out"
  report=$(cat "$out")
  assert_contains "$report" "[truncated]" "an over-long report was cut without saying so"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the cut report must still be exactly one line"
  pass "an over-long report is cut with the shared truncation marker"
}




test_invalid_environment_and_action_refuse() {
  local home status
  home=$(make_home refuse)
  status=0
  FM_HOME="$home" FM_TOOL_UPDATE_INTERVAL=5 "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "too-small interval exit"
  status=0
  FM_HOME="$home" FM_TOOL_UPDATE_PROBE_SECS=0 "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "zero probe bound exit"
  status=0
  FM_HOME="$home" FM_TOOL_UPDATE_BUDGET_SECS=999 "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "oversized budget exit"
  status=0
  FM_HOME="$home" "$CHECK" sweep >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown action exit"
  status=0
  FM_HOME="$home" "$CHECK" --help >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "help exit"
  pass "an out of range bound or unknown action refuses instead of guessing"
}

# --- arming through the existing watcher contract ----------------------------







test_announced_update_is_reported_from_the_tool_itself
test_announcement_is_read_from_a_second_command
test_unusable_announce_pattern_is_reported_not_read_as_silence
test_an_unchecked_announcement_source_is_not_read_as_current
test_an_announcement_probe_that_does_not_answer_is_reported
test_quiet_tool_with_announce_pattern_is_silent
test_commits_behind_origin_are_reported
test_default_branch_is_detected_when_branch_is_omitted
test_default_branch_is_asked_of_the_remote_when_the_clone_has_no_record
test_current_and_ahead_repositories_are_silent
test_unusable_git_source_is_reported
test_unreadable_remote_is_not_reported_as_a_missing_branch
test_missing_branch_on_a_readable_remote_is_still_reported
test_git_probes_stop_when_the_sweep_budget_is_gone
test_a_git_probe_that_does_not_answer_is_not_an_update
test_a_stalled_repository_probe_is_not_reported_as_not_a_repository
test_absent_registry_is_silent
test_an_overlong_report_says_it_was_cut
test_invalid_environment_and_action_refuse
