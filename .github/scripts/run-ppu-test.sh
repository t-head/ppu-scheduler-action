#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
: "${INPUT_IMAGE:?}"
: "${INPUT_COMMAND:?}"

export INPUT_NNODES="${INPUT_NNODES:-0}"
export INPUT_NPROC_PER_NODE="${INPUT_NPROC_PER_NODE:-1}"
export INPUT_NAMESPACE="${INPUT_NAMESPACE:-ppu-sched}"
export INPUT_TIMEOUT_MINUTES="${INPUT_TIMEOUT_MINUTES:-10}"
export INPUT_HOST_VOLUMES="${INPUT_HOST_VOLUMES:-}"
export INPUT_EXTRA_ENV="${INPUT_EXTRA_ENV:-}"
export INPUT_MASTER_PORT="${INPUT_MASTER_PORT:-29500}"
export INPUT_CLEANUP_POLICY="always"
export INPUT_SOURCE_DIR="${INPUT_SOURCE_DIR:-/workspace/source}"
export INPUT_NODE_SELECTOR="${INPUT_NODE_SELECTOR:-}"
export INPUT_DMESG_POLICY="${INPUT_DMESG_POLICY:-always}"
export CONTAINER_OPTIONS="${CONTAINER_OPTIONS:-}"
export USER_ENV_JSON="{}"

JOB_NAME="$(bash "$GITHUB_WORKSPACE/scripts/job-name.sh")"
export JOB_NAME
SOURCE_STAGE_DIR="/wl_nas/devops/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}/${JOB_NAME}/source.tar.gz"
export SOURCE_STAGE_DIR
OUTPUT_FILE="$(mktemp)"
export GITHUB_OUTPUT="$OUTPUT_FILE"
LOCAL_TARBALL="$(mktemp /tmp/ppu-action-ci.XXXXXX.tar.gz)"

cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  local job_status
  job_status="$(grep '^job_status=' "$OUTPUT_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
  export INPUT_JOB_STATUS="${job_status:-failed}"
  bash "$GITHUB_WORKSPACE/scripts/cleanup.sh"
  if [ "$INPUT_DMESG_POLICY" != "never" ]; then
    bash "$GITHUB_WORKSPACE/scripts/print-dmesg.sh"
  fi
  rm -f "$LOCAL_TARBALL" "$OUTPUT_FILE"
  exit "$rc"
}
trap cleanup EXIT

if [ -x /opt/bin/kubectl ]; then
  export PATH="/opt/bin:$PATH"
fi
command -v kubectl >/dev/null

if [ -n "${ARTIFACT_PATHS:-}" ]; then
  while IFS= read -r artifact_path; do
    [ -z "$artifact_path" ] && continue
    if [[ "$artifact_path" != /* ]]; then
      artifact_path="$GITHUB_WORKSPACE/$artifact_path"
    fi
    test -e "$artifact_path"
    artifact_name="$(basename "$artifact_path")"
    if [ ! -e "$GITHUB_WORKSPACE/$artifact_name" ]; then
      cp -a "$artifact_path" "$GITHUB_WORKSPACE/$artifact_name"
    fi
  done <<< "$ARTIFACT_PATHS"
fi

mkdir -p "$(dirname "$SOURCE_STAGE_DIR")"
tar czf "$LOCAL_TARBALL" -C "$GITHUB_WORKSPACE" .
cp "$LOCAL_TARBALL" "$SOURCE_STAGE_DIR"

echo "Running PPU validation job: $JOB_NAME"
bash "$GITHUB_WORKSPACE/scripts/submit.sh"

JOB_STATUS="$(grep '^job_status=' "$OUTPUT_FILE" | tail -1 | cut -d= -f2-)"
if [ "$JOB_STATUS" != "succeeded" ]; then
  echo "PPU validation finished with status: ${JOB_STATUS:-unknown}"
  exit 1
fi
