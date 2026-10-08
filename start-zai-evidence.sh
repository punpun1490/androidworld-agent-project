#!/usr/bin/env bash
set -Eeuo pipefail
: "${GITHUB_WORKSPACE:?}"
: "${TASK_NAME:?}"
: "${SUITE_SEED:?}"
ADB_BIN="$(command -v adb)"
mkdir -p "$HOME/Android/Sdk/platform-tools"
if [[ "$ADB_BIN" != "$HOME/Android/Sdk/platform-tools/adb" ]]; then ln -sfn "$ADB_BIN" "$HOME/Android/Sdk/platform-tools/adb"; fi
adb devices
test "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1"
export PYTHONPATH="$GITHUB_WORKSPACE/Open-AutoGLM:$GITHUB_WORKSPACE/android_world:$GITHUB_WORKSPACE:${PYTHONPATH:-}"
RESULT_DIR="$GITHUB_WORKSPACE/results"
RECORD_DIR="$RESULT_DIR/recordings"
mkdir -p "$RECORD_DIR"

python - <<'PY'
import json, os, pathlib, subprocess
root=pathlib.Path(os.environ["GITHUB_WORKSPACE"])
def rev(path):
    return subprocess.check_output(["git","-C",str(root/path),"rev-parse","HEAD"],text=True).strip()
meta={
    "task":os.environ["TASK_NAME"],"suite_seed":int(os.environ["SUITE_SEED"]),
    "agent":"zai_autoglm_phone","model":os.environ["PHONE_AGENT_MODEL"],
    "temperature":0,"device_id":os.environ["PHONE_AGENT_DEVICE_ID"],
    "workflow_commit":os.environ.get("GITHUB_SHA"),
    "androidworld_commit":rev("android_world"),"autoglm_commit":rev("Open-AutoGLM"),
}
(root/"results"/"metadata.json").write_text(json.dumps(meta,indent=2)+"\n")
print("EXPERIMENT_METADATA:",json.dumps(meta))
PY

# Install applications BEFORE recording; then evaluate without --perform_emulator_setup.
cd "$GITHUB_WORKSPACE/android_world"
python -u - <<'PY' 2>&1 | tee "$RESULT_DIR/setup.log"
import os
from android_world.env import env_launcher
env = env_launcher.load_and_setup_env(
    console_port=5554, emulator_setup=True,
    adb_path=os.path.expanduser("~/Android/Sdk/platform-tools/adb"))
env.close()
print("ANDROIDWORLD_APP_SETUP_PASSED")
PY
grep -q ANDROIDWORLD_APP_SETUP_PASSED "$RESULT_DIR/setup.log"

STOPFILE="$RECORD_DIR/.stop"
RECORD_PID=""
record_loop() {
  local n=0 remote dst
  while [[ ! -e "$STOPFILE" ]]; do
    n=$((n + 1))
    remote="/sdcard/eval_$n.mp4"
    dst="$RECORD_DIR/segment_$(printf '%03d' "$n").mp4"
    adb shell screenrecord --time-limit 150 --bit-rate 900000 "$remote" || true
    adb pull "$remote" "$dst" >/dev/null 2>&1 || true
    adb shell rm -f "$remote" >/dev/null 2>&1 || true
  done
}
stop_recording() {
  [[ -n "$RECORD_PID" ]] || return 0
  touch "$STOPFILE"
  adb shell 'pidof screenrecord | xargs -r -n1 kill -2' >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do
    kill -0 "$RECORD_PID" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$RECORD_PID" 2>/dev/null; then kill "$RECORD_PID" 2>/dev/null || true; fi
  wait "$RECORD_PID" 2>/dev/null || true
  RECORD_PID=""
}
trap stop_recording EXIT
record_loop &
RECORD_PID=$!
sleep 3

set +e
timeout --signal=INT --kill-after=30s 900s \
  python -u "$GITHUB_WORKSPACE/run_zai_autoglm.py" \
    --suite_family=android_world \
    --agent_name=zai_autoglm_phone \
    --tasks="$TASK_NAME" \
    --n_task_combinations=1 \
    --task_random_seed="$SUITE_SEED" \
    --adb_path="$ADB_BIN" \
    --output_path="$RESULT_DIR" 2>&1 | tee "$RESULT_DIR/benchmark.log"
run_exit=${PIPESTATUS[0]}
set -e
stop_recording
trap - EXIT

valid=0
for f in "$RECORD_DIR"/*.mp4; do
  [[ -e "$f" ]] || continue
  if [[ -s "$f" ]] && ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 "$f" >/dev/null 2>&1; then
    echo "VALID_MP4 $f"
    valid=$((valid+1))
  else
    echo "INVALID_MP4 $f"
  fi
done
echo "VALID_VIDEO_SEGMENTS=$valid"
if [[ "$run_exit" -ne 0 ]]; then echo "BENCHMARK_PROCESS_FAILED exit=$run_exit"; exit "$run_exit"; fi
if grep -q 'SKIPPING' "$RESULT_DIR/benchmark.log"; then echo "TASK_SKIPPED"; exit 1; fi
grep -Eq 'Task (Successful|Failed)' "$RESULT_DIR/benchmark.log" || { echo "NO_VERIFIER_RESULT"; exit 1; }
python "$GITHUB_WORKSPACE/export_results.py" \
    --results "$RESULT_DIR" --agent zai_autoglm_phone \
    --model "$PHONE_AGENT_MODEL" --suite-seed "$SUITE_SEED" \
    --recording 'recordings/segment_*.mp4'
if [[ "$valid" -lt 1 ]]; then echo "SCREEN_RECORDING_MISSING"; exit 1; fi
echo "ANDROIDWORLD_ZAI_EVIDENCE_COMPLETE"
