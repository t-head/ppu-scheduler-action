#!/usr/bin/env bash
set -euo pipefail

POLL_INTERVAL=30
JOB_NAME="${JOB_NAME:?}"
NAMESPACE="${INPUT_NAMESPACE:-default}"
NNODES="${INPUT_NNODES:-0}"
[ "$NNODES" -eq 0 ] && NNODES=1
START_TIME="${JOB_START_TIME:?}"
DEADLINE="${JOB_DEADLINE:?}"
TASK_FILE="/wl_nas/devops/ppu-dashboard/tasks/${JOB_NAME}.json"
POD_W0="${JOB_NAME}-worker-0"
FINAL_STATUS="failed"
LOG_PID=""
WAIT_PID=""
DRAIN_LOGS=false

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  else
    echo "[output] $1=$2"
  fi
}
set_output "job_status" "$FINAL_STATUS"

_on_exit() {
  local rc=$?
  trap - EXIT TERM INT
  if [ -n "$WAIT_PID" ]; then
    kill "$WAIT_PID" 2>/dev/null || true
    wait "$WAIT_PID" 2>/dev/null || true
  fi
  if [ -n "$LOG_PID" ]; then
    if [ "$DRAIN_LOGS" != true ]; then
      kill "$LOG_PID" 2>/dev/null || true
    fi
    wait "$LOG_PID" 2>/dev/null || true
  fi
  JOB_STATUS="$FINAL_STATUS" JOB_START_TIME="$START_TIME" \
    bash "$(dirname "${BASH_SOURCE[0]}")/report-job.sh" || true
  exit "$rc"
}
_on_signal() {
  echo "Workload monitoring cancelled"
  FINAL_STATUS="cancelled"
  DRAIN_LOGS=false
  set_output "job_status" "$FINAL_STATUS"
  exit 130
}
trap '_on_exit' EXIT
trap '_on_signal' TERM INT

echo "Streaming worker-0 logs; waiting for all ${NNODES} worker pods to finish"
(
  trap - EXIT
  _log_child=""
  trap 'kill "$_log_child" 2>/dev/null; wait "$_log_child" 2>/dev/null; exit 0' TERM INT
  while true; do
    _remaining=$(( DEADLINE - $(date +%s) ))
    [ "$_remaining" -le 0 ] && break
    timeout --signal=TERM --kill-after=5s "${_remaining}s" \
      kubectl logs "$POD_W0" -c worker -n "$NAMESPACE" -f --pod-running-timeout=5s 2>/dev/null &
    _log_child=$!
    wait "$_log_child" && break
    _phase=$(kubectl get pod "$POD_W0" -n "$NAMESPACE" --request-timeout=10s -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$_phase" in Succeeded|Failed) break ;; esac
    sleep 3 &
    _log_child=$!
    wait "$_log_child" || true
  done
) > >(sed -u 's/^/[worker-0] /') &
LOG_PID=$!

while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START_TIME ))
  if [ "$NOW" -ge "$DEADLINE" ]; then
    echo "::error::Job timed out after $(( DEADLINE - START_TIME ))s across scheduling and execution"
    FINAL_STATUS="timeout"
    exit 0
  fi

  POD_SNAPSHOT=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" -o json)
  SUCCEEDED=$(printf '%s' "$POD_SNAPSHOT" | jq '[.items[] | select(.status.phase == "Succeeded")] | length')
  FAILED=$(printf '%s' "$POD_SNAPSHOT" | jq '[.items[] | select(.status.phase == "Failed")] | length')
  RUNNING=$(printf '%s' "$POD_SNAPSHOT" | jq '[.items[] | select(.status.phase == "Running")] | length')
  STARTING=$(printf '%s' "$POD_SNAPSHOT" | jq '[.items[] | select(.status.phase == "Pending")] | length')

  if [ -f "$TASK_FILE" ] && { [ "$RUNNING" -gt 0 ] || [ "$SUCCEEDED" -gt 0 ]; }; then
    TASK_RECORDED_STATUS=$(jq -r '.status // empty' "$TASK_FILE")
    if [ "$TASK_RECORDED_STATUS" != "running" ]; then
      jq '.status = "running"' "$TASK_FILE" > "${TASK_FILE}.tmp" && mv "${TASK_FILE}.tmp" "$TASK_FILE"
    fi
  fi

  if [ "$SUCCEEDED" -eq "$NNODES" ] || [ "$FAILED" -gt 0 ]; then
    W0_PHASE=$(printf '%s' "$POD_SNAPSHOT" | jq -r --arg pod "$POD_W0" '.items[] | select(.metadata.name == $pod) | .status.phase')
    case "$W0_PHASE" in Succeeded|Failed) DRAIN_LOGS=true ;; esac
    if [ "$FAILED" -gt 0 ]; then
      echo "::error::Worker execution failed (failed=$FAILED)"
      exit 0
    fi
    FINAL_STATUS="succeeded"
    echo "All worker pods succeeded"
    exit 0
  fi

  echo "${ELAPSED}s elapsed - starting=$STARTING running=$RUNNING succeeded=$SUCCEEDED failed=$FAILED"
  if [ "$STARTING" -gt 0 ]; then
    printf '%s' "$POD_SNAPSHOT" | jq -r '
      .items[] | select(.status.phase == "Pending") |
      "  \(.metadata.name): \(.status.containerStatuses[0].state.waiting.reason // "starting") \(.status.containerStatuses[0].state.waiting.message // "")"'
  fi
  WAIT_SECONDS=$(( DEADLINE - $(date +%s) ))
  [ "$WAIT_SECONDS" -gt "$POLL_INTERVAL" ] && WAIT_SECONDS=$POLL_INTERVAL
  if [ "$WAIT_SECONDS" -gt 0 ]; then
    sleep "$WAIT_SECONDS" &
    WAIT_PID=$!
    wait "$WAIT_PID"
    WAIT_PID=""
  fi
done
