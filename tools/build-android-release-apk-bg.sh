#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CROMITE_ROOT="$(cd -- "${CROMITE_ROOT:-$SELF_DIR/..}" && pwd -P)"
WORKSPACE="${WORKSPACE:-/root/working_dir}"
SRC_DIR="${SRC_DIR:-$WORKSPACE/chromium/src}"
OUT_DIR="${OUT_DIR:-$SRC_DIR/out/arm64}"

LOG_DIR="${LOG_DIR:-$WORKSPACE/build_logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/cromite_android_arm64_$(date +%Y%m%d_%H%M%S).log}"

export GIT_CACHE_PATH="${GIT_CACHE_PATH:-$WORKSPACE/.git_cache}"
export CIPD_CACHE_DIR="${CIPD_CACHE_DIR:-$WORKSPACE/.cipd_cache}"
export VPYTHON_VIRTUALENV_ROOT="${VPYTHON_VIRTUALENV_ROOT:-$WORKSPACE/.vpython_root}"
export SISO_CACHE_DIR="${SISO_CACHE_DIR:-$WORKSPACE/.siso_cache}"
SISO_LOCAL_JOBS="${SISO_LOCAL_JOBS:-4}"
SISO_REMOTE_JOBS="${SISO_REMOTE_JOBS:-0}"

export PATH="$WORKSPACE/depot_tools:$PATH"
if [[ -d "$SRC_DIR/third_party/llvm-build/Release+Asserts/bin" ]]; then
  export PATH="$SRC_DIR/third_party/llvm-build/Release+Asserts/bin:$PATH"
fi

if [[ -z "${USE_KEYSTORE:-}" ]]; then
  if [[ -n "${KEYSTORE_PASSWORD:-}" || -n "${KEYSTORE_PASSWORD_FILE:-}" ]]; then
    export USE_KEYSTORE=1
  fi
fi

if [[ -n "${USE_KEYSTORE:-}" ]]; then
  export KEYSTORE_PATH="${KEYSTORE_PATH:-$CROMITE_ROOT/1214514.jks}"
  export KEYSTORE_NAME="${KEYSTORE_NAME:-1214514}"

  if [[ -z "${KEYSTORE_PASSWORD:-}" && -n "${KEYSTORE_PASSWORD_FILE:-}" ]]; then
    KEYSTORE_PASSWORD="$(<"$KEYSTORE_PASSWORD_FILE")"
    export KEYSTORE_PASSWORD
  fi

  if [[ -z "${KEYSTORE_PASSWORD:-}" ]]; then
    echo "ERROR: Signing enabled but KEYSTORE_PASSWORD is not set." >&2
    echo "Set KEYSTORE_PASSWORD or KEYSTORE_PASSWORD_FILE (preferred)." >&2
    exit 2
  fi

  if [[ ! -f "$KEYSTORE_PATH" ]]; then
    echo "ERROR: KEYSTORE_PATH does not exist: $KEYSTORE_PATH" >&2
    exit 2
  fi
fi

run_build() {
  mkdir -p "$OUT_DIR" "$LOG_DIR" "$SISO_CACHE_DIR"

  {
    echo "target_os = \"android\""
    echo "target_cpu = \"arm64\""
    cat "$CROMITE_ROOT/build/cromite.gn_args"
  } >"$OUT_DIR/args.gn"

  cd "$SRC_DIR"

  GN_BIN="$SRC_DIR/buildtools/linux64/gn"
  if [[ -x "$GN_BIN" ]]; then
    "$GN_BIN" gen "$OUT_DIR"
  else
    gn gen "$OUT_DIR"
  fi

  vpython3 "$WORKSPACE/depot_tools/siso.py" ninja -C "$OUT_DIR" \
    -cache_dir "$SISO_CACHE_DIR" \
    -local_jobs "$SISO_LOCAL_JOBS" \
    -remote_jobs "$SISO_REMOTE_JOBS" \
    --offline \
    chrome_public_apk

  echo
  echo "Build done."
  echo "APK: $OUT_DIR/apks/ChromePublic.apk"
}

if [[ "${1:-}" != "--run" ]]; then
  mkdir -p "$LOG_DIR"
  setsid "$0" --run >"$LOG_FILE" 2>&1 < /dev/null &
  echo "Build started in background."
  echo "PID: $!"
  echo "Log: $LOG_FILE"
  exit 0
fi

run_build
