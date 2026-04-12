#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CROMITE_ROOT="$(cd -- "${CROMITE_ROOT:-$SELF_DIR/..}" && pwd -P)"
WORKSPACE="${WORKSPACE:-/root/working_dir}"
SRC_DIR="${SRC_DIR:-$WORKSPACE/chromium/src}"
OUT_DIR="${OUT_DIR:-$SRC_DIR/out/arm64}"

LOG_DIR="${LOG_DIR:-$WORKSPACE/build_logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/cromite_android_arm64_$(date +%Y%m%d_%H%M%S).log}"
STATUS_FILE="${STATUS_FILE:-$LOG_FILE.status}"
CHILD_PID_FILE="${CHILD_PID_FILE:-$LOG_FILE.child.pid}"

export GIT_CACHE_PATH="${GIT_CACHE_PATH:-$WORKSPACE/.git_cache}"
export CIPD_CACHE_DIR="${CIPD_CACHE_DIR:-$WORKSPACE/.cipd_cache}"
export VPYTHON_VIRTUALENV_ROOT="${VPYTHON_VIRTUALENV_ROOT:-$WORKSPACE/.vpython_root}"
export SISO_CACHE_DIR="${SISO_CACHE_DIR:-$WORKSPACE/.siso_cache}"
SISO_LOCAL_JOBS="${SISO_LOCAL_JOBS:-2}"
SISO_REMOTE_JOBS="${SISO_REMOTE_JOBS:-0}"
NINJA_JOBS="${NINJA_JOBS:-2}"
BUILD_TARGET="${BUILD_TARGET:-chrome_public_apk}"
BUILD_MAX_RETRIES="${BUILD_MAX_RETRIES:-0}"
BUILD_STALL_TIMEOUT_SECS="${BUILD_STALL_TIMEOUT_SECS:-1800}"
BUILD_POLL_INTERVAL_SECS="${BUILD_POLL_INTERVAL_SECS:-15}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-15}"
FUTURE_MTIME_GRACE_SECS="${FUTURE_MTIME_GRACE_SECS:-8}"
BUILD_TOOL="${BUILD_TOOL:-siso}"
BUILD_FALLBACK_TOOL="${BUILD_FALLBACK_TOOL:-ninja}"
SISO_FAILURES_BEFORE_FALLBACK="${SISO_FAILURES_BEFORE_FALLBACK:-3}"

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

timestamp() {
  date '+%F %T%z'
}

log() {
  local ts message
  ts="$(timestamp)"
  message="$*"
  printf '[%s] %s\n' "$ts" "$message"
  printf '[%s] %s\n' "$ts" "$message" >>"$STATUS_FILE"
}

write_args_file() {
  mkdir -p "$OUT_DIR"

  {
    echo "target_os = \"android\""
    echo "target_cpu = \"arm64\""
    cat "$CROMITE_ROOT/build/cromite.gn_args"
  } >"$OUT_DIR/args.gn"
}

generate_build_files() {
  cd "$SRC_DIR"

  GN_BIN="$SRC_DIR/buildtools/linux64/gn"
  if [[ -x "$GN_BIN" ]]; then
    "$GN_BIN" gen "$OUT_DIR"
  else
    gn gen "$OUT_DIR"
  fi
}

resolve_ninja_bin() {
  local candidate

  for candidate in \
    "$SRC_DIR/third_party/ninja/ninja" \
    "$WORKSPACE/chromium/src/third_party/ninja/ninja"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "$WORKSPACE/depot_tools/ninja"
}

latest_build_activity_epoch() {
  local newest="$1"
  local tool="$2"
  local file mtime

  if [[ -e "$LOG_FILE" ]]; then
    mtime="$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)"
    if (( mtime > newest )); then
      newest="$mtime"
    fi
  fi

  if [[ "$tool" != "siso" ]]; then
    printf '%s\n' "$newest"
    return 0
  fi

  for file in \
    "$OUT_DIR/siso_localexec" \
    "$OUT_DIR/siso_metrics.json" \
    "$OUT_DIR/siso_explain" \
    "$OUT_DIR/siso_trace.json.tmp"; do
    if [[ -e "$file" ]]; then
      mtime="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
      if (( mtime > newest )); then
        newest="$mtime"
      fi
    fi
  done

  printf '%s\n' "$newest"
}

sanitize_future_mtime_outputs() {
  local siso_output path candidate
  local touched=0

  siso_output="$OUT_DIR/siso_output"
  [[ -s "$siso_output" ]] || return 1

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    touched=1
    for candidate in "$path" "$path.d"; do
      if [[ -e "$candidate" ]]; then
        touch -c "$candidate" || true
      fi
    done
    log "normalized future-mtime output: $path"
  done < <(sed -n 's/.*future mtime on \([^:]*\):.*/\1/p' "$siso_output" | sort -u)

  if (( touched == 0 )); then
    return 1
  fi

  log "waiting ${FUTURE_MTIME_GRACE_SECS}s for filesystem timestamps to settle"
  sleep "$FUTURE_MTIME_GRACE_SECS"
  return 0
}

run_build() {
  mkdir -p "$OUT_DIR" "$LOG_DIR" "$SISO_CACHE_DIR"
  : >"$STATUS_FILE"

  local attempt=1
  local start_epoch newest idle child status
  local current_tool="$BUILD_TOOL"
  local consecutive_siso_failures=0
  local future_mtime_fixed=0
  local ninja_bin

  ninja_bin="$(resolve_ninja_bin)"

  while true; do
    if (( BUILD_MAX_RETRIES > 0 && attempt > BUILD_MAX_RETRIES )); then
      log "reached BUILD_MAX_RETRIES=$BUILD_MAX_RETRIES without a successful build"
      return 1
    fi

    write_args_file
    generate_build_files

    if [[ "$current_tool" == "ninja" ]]; then
      log "attempt $attempt: start $BUILD_TARGET with ninja (jobs=$NINJA_JOBS)"
    else
      log "attempt $attempt: start $BUILD_TARGET with siso (local_jobs=$SISO_LOCAL_JOBS remote_jobs=$SISO_REMOTE_JOBS)"
    fi
    start_epoch="$(date +%s)"

    set +e
    if [[ "$current_tool" == "ninja" ]]; then
      "$ninja_bin" -C "$OUT_DIR" -j "$NINJA_JOBS" "$BUILD_TARGET" &
    else
      vpython3 "$WORKSPACE/depot_tools/siso.py" ninja -C "$OUT_DIR" \
        -cache_dir "$SISO_CACHE_DIR" \
        -local_jobs "$SISO_LOCAL_JOBS" \
        -remote_jobs "$SISO_REMOTE_JOBS" \
        --offline \
        "$BUILD_TARGET" &
    fi
    child=$!
    set -e

    printf '%s\n' "$child" >"$CHILD_PID_FILE"

    while kill -0 "$child" 2>/dev/null; do
      newest="$(latest_build_activity_epoch "$start_epoch" "$current_tool")"
      idle="$(( $(date +%s) - newest ))"

      if (( idle >= BUILD_STALL_TIMEOUT_SECS )); then
        log "attempt $attempt: child $child stalled for ${idle}s; terminating before retry"
        kill "$child" 2>/dev/null || true
        sleep 2
        kill -9 "$child" 2>/dev/null || true
        break
      fi

      sleep "$BUILD_POLL_INTERVAL_SECS"
    done

    set +e
    wait "$child"
    status=$?
    set -e
    rm -f "$CHILD_PID_FILE"

    if (( status == 0 )); then
      log "build finished successfully: $OUT_DIR/apks/ChromePublic.apk"
      echo
      echo "Build done."
      echo "APK: $OUT_DIR/apks/ChromePublic.apk"
      return 0
    fi

    log "attempt $attempt exit status=$status"
    future_mtime_fixed=0
    if [[ "$current_tool" == "siso" ]] && sanitize_future_mtime_outputs; then
      future_mtime_fixed=1
      consecutive_siso_failures=0
    elif [[ "$current_tool" == "siso" ]]; then
      consecutive_siso_failures="$((consecutive_siso_failures + 1))"
    fi

    if [[ "$current_tool" == "siso" ]] && \
       [[ "$BUILD_FALLBACK_TOOL" == "ninja" ]] && \
       (( future_mtime_fixed == 0 )) && \
       (( consecutive_siso_failures >= SISO_FAILURES_BEFORE_FALLBACK )); then
      current_tool="ninja"
      log "switching to ninja fallback after $consecutive_siso_failures consecutive siso failures"
    fi

    if (( future_mtime_fixed == 0 )); then
      log "retrying in ${RETRY_DELAY_SECS}s"
      sleep "$RETRY_DELAY_SECS"
    fi

    attempt="$((attempt + 1))"
  done
}

if [[ "${1:-}" != "--run" ]]; then
  mkdir -p "$LOG_DIR"
  export LOG_FILE STATUS_FILE CHILD_PID_FILE
  setsid "$0" --run >"$LOG_FILE" 2>&1 < /dev/null &
  echo "Build started in background."
  echo "PID: $!"
  echo "Log: $LOG_FILE"
  echo "Status: $STATUS_FILE"
  echo "Child PID file: $CHILD_PID_FILE"
  exit 0
fi

run_build
