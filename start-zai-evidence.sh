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
    "prompt_variant":os.environ.get("PHONE_AGENT_PROMPT_VARIANT","baseline"),
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

# Validate prerequisite app installation before any paid inference.
if [[ "$TASK_NAME" == Markor* ]]; then
  adb shell pm path net.gsantner.markor | tee "$RESULT_DIR/markor-package.txt"
  grep -q '^package:' "$RESULT_DIR/markor-package.txt" || {
    echo "PREREQUISITE_FAILED: Markor is not installed"; exit 1;
  }
  python - <<'PY'
from phone_agent.config.apps import APP_PACKAGES
import zai_androidworld_agent
assert APP_PACKAGES.get("Markor") == "net.gsantner.markor"
print("MARKOR_LAUNCH_MAPPING_OK")
PY
fi

# The official AutoGLM Type tool uses the ADBKeyBoard IME and broadcasts.
# The AndroidWorld emulator does not include that third-party keyboard.
# Pin both its official release and SHA256 to make text entry reproducible.
if [[ "$TASK_NAME" == Markor* ]]; then
  APK="$RUNNER_TEMP/adbkeyboard-v2.4-dev.apk"
  curl --fail --location --silent --show-error --retry 3 \
    --output "$APK" \
    https://github.com/senzhk/ADBKeyBoard/releases/download/v2.4-dev/keyboardservice-debug.apk
  echo "e0d0cf276b710cb34c46121f58720f5285a83ed410b0d45f57a0677b67dc2852  $APK" | sha256sum --check
  adb install -r "$APK"
  adb shell ime enable com.android.adbkeyboard/.AdbIME
  adb shell ime set com.android.adbkeyboard/.AdbIME
  adb shell settings get secure default_input_method | tr -d '\r' | \
    grep -Fx 'com.android.adbkeyboard/.AdbIME'
  adb shell pm path com.android.adbkeyboard | grep -q '^package:'
  echo "ADB_KEYBOARD_INSTALLED_AND_SELECTED" | tee "$RESULT_DIR/keyboard_status.txt"
fi

STOPFILE="$RECORD_DIR/.stop"
RECORD_PID=""
record_loop() {
  local n=0 remote dst
  while [[ ! -e "$STOPFILE" ]]; do
    n=$((n + 1))
    remote="/sdcard/eval_$n.mp4"
    dst="$RECORD_DIR/segment_$(printf '%03d' "$n").mp4"
    adb shell screenrecord --size 480x800 --time-limit 150 --bit-rate 500000 "$remote" || true
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
if [[ "$valid" -lt 1 ]]; then
  echo "SCREEN_RECORDING_MISSING: generating a clearly labelled step-frame reconstruction"
  # This is NOT a full real-time recording. It is a reviewable video assembled
  # from the step screenshots that AndroidWorld actually captured.
  find "$RESULT_DIR/frames" -name '*.jpg' -print | sort > "$RESULT_DIR/frames/list.txt"
  if [[ -s "$RESULT_DIR/frames/list.txt" ]]; then
    ffmpeg -hide_banner -loglevel error -y -framerate 1 \
      -pattern_type glob -i "$RESULT_DIR/frames/*.jpg" \
      -vf "scale=480:800:force_original_aspect_ratio=decrease,pad=480:800:(ow-iw)/2:(oh-ih)/2" \
      -c:v libx264 -pix_fmt yuv420p "$RESULT_DIR/recordings/step_frame_reconstruction.mp4" || true
  fi
  echo "RECORDING_INCOMPLETE: native capture failed; reconstruction is not equivalent to a real-time screen recording" | tee "$RESULT_DIR/recording_status.txt"
else
  echo "Native Android MP4 recorded" > "$RESULT_DIR/recording_status.txt"
fi
echo "ANDROIDWORLD_ZAI_EVIDENCE_COMPLETE"
