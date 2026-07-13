#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's cursor harness adapter.
#
# The spawn path is hermetic: fake tmux captures the literal launch command and a
# stub cursor-agent records argv when the captured command is executed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-cursor)

make_cursor_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'argc=%s\n' "$#"
  for arg in "$@"; do
    printf '<%s>\n' "$arg"
  done
} >> "${FM_CURSOR_ARGV_LOG:?}"
SH
  chmod +x "$fakebin/tmux" "$fakebin/cursor-agent"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog argvlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  argvlog="$case_dir/cursor-argv.log"
  fakebin=$(make_cursor_fakebin "$case_dir/fake")
  id="cursor-$name-z1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$argvlog|$id"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG ARGV_LOG ID <<EOF
$1
EOF
}

test_cursor_defaults_to_composer_pin_and_omits_effort_flag() {
  local rec out status launch argv meta
  rec=$(make_spawn_case default-pin)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$ID" "$PROJ_DIR" --harness cursor --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $ID harness=cursor" "spawn did not report cursor"

  meta="$HOME_DIR/state/$ID.meta"
  assert_grep "harness=cursor" "$meta" "meta missing harness=cursor"
  assert_grep "model=composer-2.5" "$meta" "cursor meta must record the Composer pin"
  assert_grep "effort=high" "$meta" "cursor meta must record the requested effort"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "cursor-agent --model 'composer-2.5' --force" \
    "cursor launch did not include the Composer model flag and --force"
  assert_not_contains "$launch" "--effort" "cursor launch must not pass an unverified --effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor launch must not pass a reasoning-effort flag"
  assert_not_contains "$launch" "--thinking" "cursor launch must not pass another harness's effort flag"

  : > "$ARGV_LOG"
  PATH="$FAKEBIN_DIR:$PATH" FM_CURSOR_ARGV_LOG="$ARGV_LOG" bash -c "$launch"
  argv=$(cat "$ARGV_LOG")
  assert_contains "$argv" "<--model>" "cursor argv missing --model"
  assert_contains "$argv" "<composer-2.5>" "cursor argv missing composer-2.5"
  assert_contains "$argv" "<--force>" "cursor argv missing --force"
  assert_contains "$argv" "<brief for $ID>" "cursor argv missing the brief as one prompt argument"
  assert_not_contains "$argv" "<--effort>" "cursor argv must not include --effort"
  assert_not_contains "$argv" "<--reasoning-effort>" "cursor argv must not include --reasoning-effort"
  pass "cursor spawn pins composer-2.5, uses --force, and records effort without passing an effort flag"
}

test_cursor_refuses_non_composer_model() {
  local rec out status
  rec=$(make_spawn_case refuse-noncomposer)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$ID" "$PROJ_DIR" --harness cursor --model gpt-5 2>&1)
  status=$?
  expect_code 1 "$status" "cursor spawn should refuse a non-Composer model"
  assert_contains "$out" "cursor harness is pinned to Composer models only" \
    "cursor refusal did not explain the Composer-only policy"
  assert_absent "$HOME_DIR/state/$ID.meta" "cursor refusal should happen before meta is written"
  pass "cursor refuses non-Composer model names"
}

# Busy-signature regression: the shared default busy regex must cover cursor's
# live-verified follow-up-bar hint (Cursor Agent 2026.07.09) and not its idle bar.
test_busy_regex_covers_cursor_footer() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  printf '%s' '  → Add a follow-up      ctrl+c to stop' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "busy regex must match cursor running follow-up bar"
  if printf '%s' '  → Add a follow-up' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT"; then
    fail "busy regex must not match cursor idle follow-up bar"
  fi
  pass "default busy regex covers cursor busy hint and not its idle bar"
}

test_cursor_defaults_to_composer_pin_and_omits_effort_flag
test_cursor_refuses_non_composer_model
test_busy_regex_covers_cursor_footer
