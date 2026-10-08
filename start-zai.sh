#!/usr/bin/env bash
# Single-shell execution: Android Emulator Runner invokes each script line separately.
set -euo pipefail

ADB_BIN="$(command -v adb)"
mkdir -p "$HOME/Android/Sdk/platform-tools"
if [[ "$ADB_BIN" != "$HOME/Android/Sdk/platform-tools/adb" ]]; then
  ln -sfn "$ADB_BIN" "$HOME/Android/Sdk/platform-tools/adb"
fi
adb devices
test "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1"

RESULT_DIR="$GITHUB_WORKSPACE/results"
mkdir -p "$RESULT_DIR"
export PYTHONPATH="$GITHUB_WORKSPACE/Open-AutoGLM:$GITHUB_WORKSPACE/android_world:$GITHUB_WORKSPACE:${PYTHONPATH:-}"
cd "$GITHUB_WORKSPACE/android_world"

python -u "$GITHUB_WORKSPACE/run_zai_autoglm.py" \
  --suite_family=android_world \
  --agent_name=zai_autoglm_phone \
  --tasks=SystemWifiTurnOn \
  --task_random_seed=101 \
  --perform_emulator_setup \
  --adb_path="$ADB_BIN" \
  --output_path="$RESULT_DIR" \
  2>&1 | tee "$RESULT_DIR/benchmark.log"

grep -q "Running task: SystemWifiTurnOn" "$RESULT_DIR/benchmark.log"
grep -Eq "Task (Successful|Failed)" "$RESULT_DIR/benchmark.log"
if grep -q "SKIPPING" "$RESULT_DIR/benchmark.log"; then
  echo "AndroidWorld skipped the task (see benchmark.log)"
  exit 1
fi
echo "ZAI AUTOGLM ANDROIDWORLD EVALUATION FINISHED"
