#!/usr/bin/env bash
# Behavior test for fm-spawn.sh's droid launch adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-droid)

make_fakebin() {
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
    literal=
    prev=
    for a in "$@"; do
      if [ "$prev" = "-l" ]; then
        literal=$a
        break
      fi
      prev=$a
    done
    if [ -n "$literal" ]; then
      printf '%s\n' "$literal" > "$FM_FAKE_PENDING_LINE_FILE"
      printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
      exit 0
    fi
    for a in "$@"; do
      if [ "$a" = Enter ] && [ -s "$FM_FAKE_PENDING_LINE_FILE" ]; then
        line=$(cat "$FM_FAKE_PENDING_LINE_FILE")
        : > "$FM_FAKE_PENDING_LINE_FILE"
        (cd "${FM_FAKE_EXEC_CWD:-$PWD}" && sh -c "$line")
        exit 0
      fi
    done
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/droid" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'argc=%s\n' "$#"
  i=0
  for a in "$@"; do
    i=$((i + 1))
    printf 'argv%s=%s\n' "$i" "$a"
  done
} >> "$FM_FAKE_DROID_ARGV_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/droid"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_spawn_droid_writes_settings_and_launches_with_settings_file() {
  local case_dir home proj wt fakebin launchlog argvlog pending id out status launch settings_path
  id=spawn-droid-z1
  case_dir="$TMP_ROOT/case"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  argvlog="$case_dir/droid.argv"
  pending="$case_dir/pending-line"
  fakebin=$(make_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for droid\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-droid"
  touch "$home/state/.last-watcher-beat"
  : > "$pending"
  : > "$launchlog"
  : > "$argvlog"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_PENDING_LINE_FILE="$pending" FM_FAKE_LAUNCH_LOG="$launchlog" \
    FM_FAKE_DROID_ARGV_LOG="$argvlog" FM_FAKE_EXEC_CWD="$wt" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" --harness droid --model glm-5.2 --effort high 2>&1)
  status=$?
  expect_code 0 "$status" "droid spawn should succeed"
  assert_contains "$out" "spawned $id harness=droid" "spawn did not report droid harness"

  assert_grep "harness=droid" "$home/state/$id.meta" "meta missing harness=droid"
  assert_grep "model=glm-5.2" "$home/state/$id.meta" "meta missing model=glm-5.2"
  assert_grep "effort=high" "$home/state/$id.meta" "meta missing effort=high"

  launch=$(cat "$launchlog")
  assert_contains "$launch" "droid --settings" "droid launch did not use --settings"
  assert_not_contains "$launch" "droid -m" "droid launch must not use ignored -m"
  assert_not_contains "$launch" "--model" "droid launch must not use ignored --model"
  assert_not_contains "$launch" "--reasoning-effort" "droid launch must not use interactive reasoning flag"
  assert_not_contains "$launch" "--auto" "droid launch must not rely on ignored interactive --auto"
  assert_not_contains "$launch" "--skip-permissions-unsafe" "droid launch must not use ignored skip-permissions flag"

  assert_grep "argv1=--settings" "$argvlog" "fake droid did not receive --settings"
  settings_path=$(sed -n 's/^argv2=//p' "$argvlog")
  [ -n "$settings_path" ] || fail "fake droid did not receive settings path"
  [ -f "$settings_path" ] || fail "droid settings file was not written: $settings_path"
  assert_grep '"model": "glm-5.2"' "$settings_path" "settings file did not pin glm-5.2"
  assert_grep '"reasoningEffort": "high"' "$settings_path" "settings file did not pin high reasoning"
  assert_grep '"sessionDefaultSettings": {' "$settings_path" "settings file missing session defaults"
  assert_grep '"interactionMode": "auto"' "$settings_path" "settings file did not start in auto mode"
  assert_grep '"autonomyLevel": "high"' "$settings_path" "settings file did not pin high autonomy"
  assert_grep "argv3=brief for droid" "$argvlog" "fake droid did not receive brief as one prompt argument"
  pass "fm-spawn droid records profile metadata and launches with verified --settings pin"
}

# Busy-signature regression: the shared default busy regex must cover droid's
# live-verified spinner hints (droid 0.170.0) and not its idle footer.
test_busy_regex_covers_droid_footers() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  printf '%s' ' ⡄ Executing...  (Press ESC to stop)' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "busy regex must match droid Executing footer"
  printf '%s' ' ⣄ Streaming...  (Press ESC to stop)' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "busy regex must match droid Streaming footer"
  if printf '%s' ' Auto (High) · allow all commands' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT"; then
    fail "busy regex must not match droid idle footer"
  fi
  pass "default busy regex covers droid busy footers and not its idle footer"
}

test_spawn_droid_writes_settings_and_launches_with_settings_file
test_busy_regex_covers_droid_footers

echo "# all fm-spawn-droid tests passed"
