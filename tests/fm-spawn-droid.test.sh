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

test_spawn_droid_threads_model_effort_and_autonomy() {
  local case_dir home proj wt fakebin launchlog argvlog pending id out status launch
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
  assert_contains "$launch" "droid -m 'glm-5.2' --reasoning-effort 'high' --auto high" \
    "droid launch did not contain verified model, effort, and autonomy flags"
  assert_not_contains "$launch" "--skip-permissions-unsafe" "droid launch should use --auto high"

  assert_grep "argv1=-m" "$argvlog" "fake droid did not receive -m flag"
  assert_grep "argv2=glm-5.2" "$argvlog" "fake droid did not receive glm-5.2 model"
  assert_grep "argv3=--reasoning-effort" "$argvlog" "fake droid did not receive reasoning flag"
  assert_grep "argv4=high" "$argvlog" "fake droid did not receive high effort"
  assert_grep "argv5=--auto" "$argvlog" "fake droid did not receive autonomy flag"
  assert_grep "argv6=high" "$argvlog" "fake droid did not receive high autonomy"
  assert_grep "argv7=brief for droid" "$argvlog" "fake droid did not receive brief as one prompt argument"
  pass "fm-spawn droid records profile metadata and launches with model, effort, and autonomy flags"
}

test_spawn_droid_threads_model_effort_and_autonomy

echo "# all fm-spawn-droid tests passed"
