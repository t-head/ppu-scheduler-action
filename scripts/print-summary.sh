#!/usr/bin/env bash
set -uo pipefail

[ -n "${JOB_STATUS:-}" ] || { echo "PPU job was not submitted, skipping usage summary"; exit 0; }

PENDING_WARN_THRESHOLD=300

format_duration() {
  local total_seconds="${1:-0}"
  [[ "$total_seconds" =~ ^[0-9]+$ ]] || total_seconds=0
  printf '%dh %dm %ds' \
    "$(( total_seconds / 3600 ))" \
    "$(( total_seconds % 3600 / 60 ))" \
    "$(( total_seconds % 60 ))"
}

pods="${NNODES:-0}"
[[ "$pods" =~ ^[0-9]+$ ]] || pods=0
[ "$pods" -eq 0 ] && pods=1
cards="${NPROC_PER_NODE:-1}"
[[ "$cards" =~ ^[0-9]+$ ]] || cards=1

queue="$(format_duration "${QUEUE_DURATION_SECONDS:-0}")"
unscheduled="${UNSCHEDULED_PODS:-0}"
[[ "$unscheduled" =~ ^[0-9]+$ ]] || unscheduled=0
[ "$unscheduled" -gt 0 ] && queue="${queue} (${unscheduled}/${pods} pod(s) never scheduled)"

queue_level="notice"
pod_queue_list=""
while IFS=':' read -r pod_name pod_seconds pod_scheduled; do
  [ -z "$pod_name" ] && continue
  [[ "$pod_seconds" =~ ^[0-9]+$ ]] || pod_seconds=0
  item="${pod_name} $(format_duration "$pod_seconds")"
  [ "$pod_scheduled" = "0" ] && item="${item} (not scheduled)"
  if [ "$pod_seconds" -ge "$PENDING_WARN_THRESHOLD" ] || [ "$pod_scheduled" = "0" ]; then
    queue_level="warning"
  fi
  pod_queue_list="${pod_queue_list:+${pod_queue_list}, }${item}"
done < <(printf '%s\n' "${POD_QUEUE:-}" | tr ',' '\n')
queue_reason="${QUEUE_REASON:-}"
[ "$queue_level" = "warning" ] && [ -z "$queue_reason" ] && queue_reason="no FailedScheduling event found"

echo "::group::PPU usage summary"
printf '%-28s %s\n' \
  "Job name:" "${JOB_NAME:-}" \
  "Status:" "$JOB_STATUS" \
  "PPU topology:" "${pods} pod(s) x ${cards} PPU = $(( pods * cards )) PPU" \
  "Queue duration:" "$queue" \
  "Pod queue time:" "${pod_queue_list:-no pod data}" \
  "Job duration:" "$(format_duration "${DURATION_SECONDS:-0}")" \
  "PPU card-hours (occupied):" "${OCCUPIED_PPU_CARD_HOURS:-0.0000}" \
  "PPU card-hours (execution):" "${EXECUTION_PPU_CARD_HOURS:-0.0000}" \
  "Pods:" "${TASK_PODS:-}"
[ -n "$queue_reason" ] && printf '%-28s %s\n' "Scheduling reason:" "$queue_reason"
echo
echo "Metric definitions:"
echo "  Queue duration: time from the first pod creation until all PPU pods are scheduled; a pod that is never scheduled is measured until the job ends."
echo "  Pod queue time: time from each pod's creation until it is scheduled to a PPU node, or until the job ends if it is never scheduled."
echo "  PPU card-hours (occupied): sum of each pod's PPU count multiplied by the time from scheduling to completion, including image pulling and container startup."
echo "  PPU card-hours (execution): sum of each pod's PPU count multiplied by the worker container running time."
echo "::endgroup::"

queue_message="PPU queue: total ${queue} | ${pod_queue_list:-no pod data}"
[ -n "$queue_reason" ] && queue_message="${queue_message} | Reason: ${queue_reason}"
echo "::${queue_level}::${queue_message//\%/%25}"
echo "::notice::PPU usage: ${JOB_STATUS} | ${pods} pod(s) x ${cards} PPU | occupied ${OCCUPIED_PPU_CARD_HOURS:-0.0000} card-hours | execution ${EXECUTION_PPU_CARD_HOURS:-0.0000} card-hours"
