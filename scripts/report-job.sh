#!/usr/bin/env bash
set -euo pipefail

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  else
    echo "[output] $1=$2"
  fi
}

JOB_NAME="${JOB_NAME:?}"
NAMESPACE="${INPUT_NAMESPACE:-default}"
NPROC="${INPUT_NPROC_PER_NODE:-1}"
START_TIME="${JOB_START_TIME:?}"
FINAL_STATUS="${JOB_STATUS:?}"
TASK_FILE="/wl_nas/devops/ppu-dashboard/tasks/${JOB_NAME}.json"
set_output "job_status" "$FINAL_STATUS"
METRICS_END_EPOCH=$(date +%s)
METRICS_END_TIME=$(date +%Y-%m-%dT%H:%M:%S%z)
DURATION=$(( METRICS_END_EPOCH - START_TIME ))
set_output "duration_seconds" "$DURATION"
POD_SNAPSHOT=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" -o json)

QUEUE_START_EPOCH=0
QUEUE_END_EPOCH=0
QUEUE_DURATION_SECONDS=0
UNSCHEDULED_PODS=0
LONG_QUEUE_PODS=0
POD_QUEUE=""
OCCUPIED_PPU_CARD_SECONDS=0
EXECUTION_PPU_CARD_SECONDS=0

while IFS='|' read -r _pod_name _created_at _scheduled_at _started_at _finished_at; do
  [ -z "$_pod_name" ] && continue

  _created_epoch=$(date -d "$_created_at" +%s 2>/dev/null || echo 0)
  if [ "$_created_epoch" -gt 0 ]; then
    if [ "$QUEUE_START_EPOCH" -eq 0 ] || [ "$_created_epoch" -lt "$QUEUE_START_EPOCH" ]; then
      QUEUE_START_EPOCH=$_created_epoch
    fi
    _pod_queue_end_epoch=$METRICS_END_EPOCH
    if [ -n "$_scheduled_at" ]; then
      _pod_queue_end_epoch=$(date -d "$_scheduled_at" +%s 2>/dev/null || echo "$METRICS_END_EPOCH")
    fi
    [ "$_pod_queue_end_epoch" -gt "$QUEUE_END_EPOCH" ] && QUEUE_END_EPOCH=$_pod_queue_end_epoch
    _pod_queue_seconds=$(( _pod_queue_end_epoch - _created_epoch ))
    [ "$_pod_queue_seconds" -lt 0 ] && _pod_queue_seconds=0
    _pod_scheduled=1
    [ -z "$_scheduled_at" ] && _pod_scheduled=0
    [ "$_pod_queue_seconds" -ge 300 ] && LONG_QUEUE_PODS=$(( LONG_QUEUE_PODS + 1 ))
    POD_QUEUE="${POD_QUEUE:+${POD_QUEUE},}${_pod_name#"${JOB_NAME}-"}:${_pod_queue_seconds}:${_pod_scheduled}"
  fi

  _resource_end_epoch=$METRICS_END_EPOCH
  if [ -n "$_finished_at" ]; then
    _resource_end_epoch=$(date -d "$_finished_at" +%s 2>/dev/null || echo "$METRICS_END_EPOCH")
  fi

  [ -z "$_scheduled_at" ] && UNSCHEDULED_PODS=$(( UNSCHEDULED_PODS + 1 ))

  if [ -n "$_scheduled_at" ]; then
    _scheduled_epoch=$(date -d "$_scheduled_at" +%s 2>/dev/null || echo 0)
    if [ "$_scheduled_epoch" -gt 0 ]; then
      _occupied_seconds=$(( _resource_end_epoch - _scheduled_epoch ))
      [ "$_occupied_seconds" -lt 0 ] && _occupied_seconds=0
      OCCUPIED_PPU_CARD_SECONDS=$(( OCCUPIED_PPU_CARD_SECONDS + _occupied_seconds * NPROC ))
    fi
  fi

  if [ -n "$_started_at" ]; then
    _started_epoch=$(date -d "$_started_at" +%s 2>/dev/null || echo 0)
    if [ "$_started_epoch" -gt 0 ]; then
      _execution_seconds=$(( _resource_end_epoch - _started_epoch ))
      [ "$_execution_seconds" -lt 0 ] && _execution_seconds=0
      EXECUTION_PPU_CARD_SECONDS=$(( EXECUTION_PPU_CARD_SECONDS + _execution_seconds * NPROC ))
    fi
  fi
done < <(
  printf '%s' "$POD_SNAPSHOT" | jq -r --arg prefix "${JOB_NAME}-worker-" '
    .items | sort_by((.metadata.name | ltrimstr($prefix) | tonumber?) // 0) | .[] |
    [
      .metadata.name,
      (.metadata.creationTimestamp // ""),
      ([.status.conditions[]? | select(.type == "PodScheduled" and .status == "True") | .lastTransitionTime] | first // ""),
      (.status.containerStatuses[0].state.running.startedAt // .status.containerStatuses[0].state.terminated.startedAt // ""),
      (.status.containerStatuses[0].state.terminated.finishedAt // "")
    ] | join("|")
  '
)

if [ "$QUEUE_START_EPOCH" -gt 0 ] && [ "$QUEUE_END_EPOCH" -ge "$QUEUE_START_EPOCH" ]; then
  QUEUE_DURATION_SECONDS=$(( QUEUE_END_EPOCH - QUEUE_START_EPOCH ))
fi

QUEUE_REASON=""
if [ "$LONG_QUEUE_PODS" -gt 0 ] || [ "$UNSCHEDULED_PODS" -gt 0 ]; then
  QUEUE_REASON=$(kubectl get events -n "$NAMESPACE" --field-selector "reason=FailedScheduling" -o json 2>/dev/null \
    | jq -r --arg job "$JOB_NAME" '
        [.items[] | select(.involvedObject.name | startswith($job))]
        | sort_by(.lastTimestamp // .eventTime // "") | last | .message // empty' 2>/dev/null \
    | tr '\r\n' '  ' | sed 's/ *$//' | cut -c1-300 || true)
fi

OCCUPIED_PPU_CARD_HOURS=$(awk -v seconds="$OCCUPIED_PPU_CARD_SECONDS" 'BEGIN { printf "%.4f", seconds / 3600 }')
EXECUTION_PPU_CARD_HOURS=$(awk -v seconds="$EXECUTION_PPU_CARD_SECONDS" 'BEGIN { printf "%.4f", seconds / 3600 }')
TASK_PODS=$(printf '%s' "$POD_SNAPSHOT" | jq -r '[.items[].metadata.name] | join(",")')

set_output "queue_duration_seconds" "$QUEUE_DURATION_SECONDS"
set_output "unscheduled_pods" "$UNSCHEDULED_PODS"
set_output "pod_queue" "$POD_QUEUE"
set_output "queue_reason" "$QUEUE_REASON"
set_output "occupied_ppu_card_hours" "$OCCUPIED_PPU_CARD_HOURS"
set_output "execution_ppu_card_hours" "$EXECUTION_PPU_CARD_HOURS"
set_output "task_pods" "$TASK_PODS"

echo "Job: $JOB_NAME | Status: $FINAL_STATUS | Duration: ${DURATION}s | Pods: $TASK_PODS"

if [ -f "$TASK_FILE" ]; then
  jq \
    --arg end_time "$METRICS_END_TIME" \
    --arg status "$FINAL_STATUS" \
    --argjson queue_duration_seconds "$QUEUE_DURATION_SECONDS" \
    --argjson occupied_ppu_card_seconds "$OCCUPIED_PPU_CARD_SECONDS" \
    --argjson execution_ppu_card_seconds "$EXECUTION_PPU_CARD_SECONDS" \
    --argjson occupied_ppu_card_hours "$OCCUPIED_PPU_CARD_HOURS" \
    --argjson execution_ppu_card_hours "$EXECUTION_PPU_CARD_HOURS" \
    --argjson unscheduled_pods "$UNSCHEDULED_PODS" \
    --arg pod_queue "$POD_QUEUE" \
    --arg queue_reason "$QUEUE_REASON" \
    '.end_time = $end_time
     | .status = $status
     | .queue_duration_seconds = $queue_duration_seconds
     | .unscheduled_pods = $unscheduled_pods
     | .pod_queue = ($pod_queue | if . == "" then [] else split(",") | map(split(":") | {pod: .[0], queue_seconds: (.[1] | tonumber), scheduled: (.[2] == "1")}) end)
     | .queue_reason = $queue_reason
     | .occupied_ppu_card_seconds = $occupied_ppu_card_seconds
     | .execution_ppu_card_seconds = $execution_ppu_card_seconds
     | .occupied_ppu_card_hours = $occupied_ppu_card_hours
     | .execution_ppu_card_hours = $execution_ppu_card_hours' \
    "$TASK_FILE" > "${TASK_FILE}.tmp" && mv "${TASK_FILE}.tmp" "$TASK_FILE"
  echo "Task record finalized: $TASK_FILE"
fi
