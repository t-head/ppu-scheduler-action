#!/usr/bin/env bash
# =============================================================================
# submit-training-job.sh
#   统一 Volcano vcjob 提交逻辑：渲染 vcjob YAML → 幂等提交 → 轮询等待 →
#   收集日志 → 输出 GitHub Actions outputs。
#
#   所有 PPU 作业（单卡到多机多卡）一律以 batch.volcano.sh/v1alpha1 Job(vcjob)
#   运行，由无卡的 CPU 编排 runner 提交。参见 docs/DESIGN.md §7 / §8 / §11。
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 全局配置
# -----------------------------------------------------------------------------
POLL_INTERVAL=30                       # 轮询间隔（秒）
PENDING_WARN_THRESHOLD=300             # Pod Pending 超过该秒数后输出调度告警
LOG_DIR="/tmp/training-logs"           # 日志收集目录
MANIFEST_DIR="/tmp/training-manifests" # 渲染出的 vcjob YAML 目录

mkdir -p "$LOG_DIR" "$MANIFEST_DIR"

# -----------------------------------------------------------------------------
# 辅助函数
# -----------------------------------------------------------------------------
log_info()  { echo "::notice::$*"; }
log_warn()  { echo "::warning::$*"; }
log_error() { echo "::error::$*"; }

# 写入 GitHub Actions output（若在本地运行则仅打印，不报错）
set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  else
    echo "[output] $1=$2"
  fi
}

# 将任意字符串规整为合法的 DNS-1123 label 片段：
#   转小写 → 非 [a-z0-9-] 替换为 '-' → 去除首尾多余的 '-'
sanitize_name() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/^-*//; s/-*$//'
}

# -----------------------------------------------------------------------------
# 读取输入参数（全部来自环境变量，带默认值）
# -----------------------------------------------------------------------------
NNODES="${INPUT_NNODES:-1}"
NPROC="${INPUT_NPROC_PER_NODE:-1}"
COMMAND="${INPUT_COMMAND:-}"
IMAGE="${INPUT_IMAGE:-}"
NAMESPACE="${INPUT_NAMESPACE:-default}"
TIMEOUT_MINUTES="${INPUT_TIMEOUT_MINUTES:-60}"
PVC_NAME="${INPUT_PVC_NAME:-}"
PVC_MOUNT_PATH="${INPUT_PVC_MOUNT_PATH:-/mnt/pvc}"
EXTRA_ENV="${INPUT_EXTRA_ENV:-}"
MASTER_PORT="${INPUT_MASTER_PORT:-29500}"
QUEUE="${INPUT_QUEUE:-default}"
# CLEANUP_POLICY 在本脚本仅透传给 outputs / summary，实际清理由 cleanup.sh 执行
CLEANUP_POLICY="${INPUT_CLEANUP_POLICY:-on_success}"
# 节点定向选择器（逗号分隔 KEY=VAL，可为空；作为硬约束合并进 pod nodeSelector）
NODE_SELECTOR="${INPUT_NODE_SELECTOR:-}"

# 轮询超时（秒）：由分钟换算
TIMEOUT=$(( TIMEOUT_MINUTES * 60 ))

# -----------------------------------------------------------------------------
# 必填校验
# -----------------------------------------------------------------------------
if [ -z "$IMAGE" ]; then
  log_error "input 'image' 必填，但为空。"
  exit 1
fi
if [ -z "$COMMAND" ]; then
  log_error "input 'command' 必填，但为空。"
  exit 1
fi

# -----------------------------------------------------------------------------
# 生成幂等 Job 名：ppu-{owner}-{run_id}-{attempt}
#   截断到合法长度，并为 Volcano 生成的 pod 名 "{job}-worker-{idx}" 预留后缀空间
# -----------------------------------------------------------------------------
OWNER=$(sanitize_name "${GITHUB_REPOSITORY_OWNER:-unknown}" | cut -c1-20 | sed 's/-*$//')
RUN_ID="${GITHUB_RUN_ID:-0}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
JOB_NAME="ppu-${OWNER}-${RUN_ID}-${RUN_ATTEMPT}"
# 截断到 52 字符（63 - "-worker-N" 余量），并去除截断产生的尾部 '-'
JOB_NAME=$(echo "$JOB_NAME" | cut -c1-52 | sed 's/-*$//')

log_info "Job 名称:   $JOB_NAME"
log_info "命名空间:   $NAMESPACE"
log_info "队列:       $QUEUE"
log_info "规模:       ${NNODES} node(s) × ${NPROC} PPU/node"
log_info "超时:       ${TIMEOUT_MINUTES}min (${TIMEOUT}s)"

# -----------------------------------------------------------------------------
# Fail-fast：Volcano 未安装则直接退出，避免提交后死锁
# -----------------------------------------------------------------------------
if ! kubectl get crd jobs.batch.volcano.sh >/dev/null 2>&1; then
  log_error "未检测到 Volcano CRD (jobs.batch.volcano.sh)。无法提交 vcjob。"
  log_error "请先安装 Volcano: kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/master/installer/volcano-development.yaml"
  exit 1
fi

# -----------------------------------------------------------------------------
# 构建额外环境变量 YAML 片段（解析 INPUT_EXTRA_ENV，逗号分隔 KEY=VAL）
#   每行缩进 16 空格，与 containers[0].env 列表对齐
# -----------------------------------------------------------------------------
EXTRA_ENV_YAML=""
if [ -n "$EXTRA_ENV" ]; then
  IFS=',' read -ra _env_pairs <<< "$EXTRA_ENV"
  for _pair in "${_env_pairs[@]}"; do
    [ -z "$_pair" ] && continue
    _key="${_pair%%=*}"
    _val="${_pair#*=}"
    # 去除 key 首尾空白
    _key=$(echo "$_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$_key" ] && continue
    EXTRA_ENV_YAML+="                - name: ${_key}"$'\n'
    EXTRA_ENV_YAML+="                  value: \"${_val}\""$'\n'
  done
  # 去除末尾多余换行，避免注入后产生连续空行
  EXTRA_ENV_YAML="${EXTRA_ENV_YAML%$'\n'}"
fi

# -----------------------------------------------------------------------------
# 构建用户节点定向 YAML 片段（解析 INPUT_NODE_SELECTOR，逗号分隔 KEY=VAL）
#   - 仅当用户传入 node_selector 时才渲染 nodeSelector: 段
#   - PPU pod 落到 PPU 节点已由 alibabacloud.com/ppu 资源请求天然保证
#   - 每行缩进 12 空格，与 spec 层级对齐
# -----------------------------------------------------------------------------
NODE_SELECTOR_YAML=""
if [ -n "$NODE_SELECTOR" ]; then
  _ns_items=""
  IFS=',' read -ra _ns_pairs <<< "$NODE_SELECTOR"
  for _pair in "${_ns_pairs[@]}"; do
    [ -z "$_pair" ] && continue
    _key="${_pair%%=*}"
    _val="${_pair#*=}"
    # 去除 key 首尾空白
    _key=$(echo "$_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$_key" ] && continue

    # --- 校验 key ---
    _key_name="$_key"
    if [[ "$_key" == */* ]]; then
      _key_prefix="${_key%/*}"
      _key_name="${_key##*/}"
      # DNS 前缀：≤253 字符，仅 [a-zA-Z0-9.-]，以字母数字开头结尾
      if [ ${#_key_prefix} -gt 253 ] || [ -z "$_key_prefix" ] \
         || ! [[ "$_key_prefix" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?$ ]]; then
        log_error "node_selector: key 前缀不合法: '${_key_prefix}' (需为合法 DNS 子域，≤253 字符)"
        exit 1
      fi
    fi
    # name 部分：≤63 字符，以字母数字开头结尾，中间允许 [-_.]
    if [ -z "$_key_name" ] || [ ${#_key_name} -gt 63 ] \
       || ! [[ "$_key_name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,61}[a-zA-Z0-9])?$ ]]; then
      log_error "node_selector: key 名称不合法: '${_key_name}' (需为字母数字及 -_. ，≤63 字符，以字母数字开头结尾)"
      exit 1
    fi

    # --- 校验 value：可为空；非空时 ≤63，以字母数字开头结尾，中间允许 [-_.] ---
    if [ -n "$_val" ]; then
      if [ ${#_val} -gt 63 ] \
         || ! [[ "$_val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,61}[a-zA-Z0-9])?$ ]]; then
        log_error "node_selector: value 不合法: '${_val}' (需为字母数字及 -_. ，≤63 字符，以字母数字开头结尾)"
        exit 1
      fi
    fi

    _ns_items+="            ${_key}: \"${_val}\""$'\n'
  done
  # 去除末尾多余换行
  _ns_items="${_ns_items%$'\n'}"
  # 仅当至少存在一个合法标签时才渲染 nodeSelector 段
  if [ -n "$_ns_items" ]; then
    NODE_SELECTOR_YAML="          nodeSelector:"$'\n'"${_ns_items}"
  fi
fi

# -----------------------------------------------------------------------------
# 构建可选 PVC 挂载 / 卷 YAML 片段
#   volumeMounts 列表项缩进 16 空格；volumes 列表项缩进 12 空格
# -----------------------------------------------------------------------------
PVC_MOUNT_YAML=""
PVC_VOLUME_YAML=""
if [ -n "$PVC_NAME" ]; then
  PVC_MOUNT_YAML="                - name: user-pvc
                  mountPath: ${PVC_MOUNT_PATH}"
  PVC_VOLUME_YAML="            - name: user-pvc
              persistentVolumeClaim:
                claimName: ${PVC_NAME}"
fi

# -----------------------------------------------------------------------------
# 构建容器启动脚本（args）
#   - 前置 prologue：从 Volcano 注入的 VK_TASK_INDEX / VC_TASK_INDEX 派生
#     RANK / NODE_RANK（单 task 多 replica 模式下即为 pod 的副本序号）。
#   - 之后拼接用户 command。
#   使用单引号 heredoc 保证 prologue 中的 $ 不被编排脚本展开，
#   保持为容器运行时的真实变量。
# -----------------------------------------------------------------------------
read -r -d '' _PROLOGUE <<'PROLOGUE_EOF' || true
# --- ppu-distributed-action 注入的分布式契约（运行时求值）---
# RANK / NODE_RANK 派生自 Volcano env plugin 注入的 VK_TASK_INDEX
export NODE_RANK="${VK_TASK_INDEX:-${VC_TASK_INDEX:-0}}"
export RANK="${NODE_RANK}"
# ------------------------------------------------------------
PROLOGUE_EOF

# 拼接 prologue + 用户命令，并整体缩进 18 空格（对齐 args 的 '|' 块标量）
FULL_SCRIPT="${_PROLOGUE}"$'\n'"${COMMAND}"
SCRIPT_INDENTED=$(printf '%s\n' "$FULL_SCRIPT" | sed 's/^/                  /')

# -----------------------------------------------------------------------------
# 渲染 vcjob YAML
#   注意：本 heredoc 未加引号，会展开 ${...} 变量；用户命令与 prologue 已预先
#   构建成 ${SCRIPT_INDENTED}，注入时仅做一次变量替换，不会再次展开其中的 $。
# -----------------------------------------------------------------------------
MANIFEST="$MANIFEST_DIR/vcjob.yaml"
cat > "$MANIFEST" <<YAML_EOF
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: ppu-distributed-action
    github.com/run-id: "${RUN_ID}"
    github.com/run-attempt: "${RUN_ATTEMPT}"
spec:
  # gang scheduling：全部 task 同时获得资源或全部不调度
  minAvailable: ${NNODES}
  schedulerName: volcano
  queue: ${QUEUE}
  maxRetry: 0
  # 完成 24h 后自动 GC，作为清理兜底
  ttlSecondsAfterFinished: 86400
  plugins:
    # env 插件：为每个 task pod 注入 VK_TASK_INDEX / VC_TASK_INDEX（用于派生 RANK）
    env: []
    # svc 插件：自动创建 headless service，赋予每个 pod 稳定 DNS，用于 rendezvous
    svc: []
  tasks:
    # 单一 task "worker"：所有节点使用同一模板，replicas = nnodes
    - name: worker
      replicas: ${NNODES}
      template:
        spec:
          schedulerName: volcano
          restartPolicy: Never
${NODE_SELECTOR_YAML}
          containers:
            - name: worker
              image: ${IMAGE}
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "-c"]
              args:
                - |
${SCRIPT_INDENTED}
              env:
                - name: NNODES
                  value: "${NNODES}"
                - name: NPROC_PER_NODE
                  value: "${NPROC}"
                # WORLD_SIZE = 全局总节点数（= task pod 总数），非进程总数
                - name: WORLD_SIZE
                  value: "${NNODES}"
                - name: MASTER_PORT
                  value: "${MASTER_PORT}"
                # 单进程模式固定 0；pod 内多进程由用户 launcher 自行管理 local rank
                - name: LOCAL_RANK
                  value: "0"
                # MASTER_ADDR 指向 Volcano svc plugin 创建的 headless service 中
                # rank-0 pod 的稳定 DNS：{jobname}-worker-0.{jobname}
                - name: MASTER_ADDR
                  value: "${JOB_NAME}-worker-0.${JOB_NAME}"
                # 说明：RANK / NODE_RANK 由 Volcano env plugin 注入的 VK_TASK_INDEX
                #       派生，在上方 args 启动脚本中 export，此处不做静态赋值。
${EXTRA_ENV_YAML}
              resources:
                requests:
                  alibabacloud.com/ppu: "${NPROC}"
                limits:
                  alibabacloud.com/ppu: "${NPROC}"
              volumeMounts:
                - name: dshm
                  mountPath: /dev/shm
${PVC_MOUNT_YAML}
          volumes:
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 64Gi
${PVC_VOLUME_YAML}
YAML_EOF

# -----------------------------------------------------------------------------
# 幂等提交：先删除同名旧 vcjob（忽略 not found），再 apply
# -----------------------------------------------------------------------------
log_info "清理同名旧资源（若存在）: $JOB_NAME"
kubectl delete vcjob "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
# 等待旧资源与其 pod 完成回收
sleep 3

log_info "提交 vcjob: $JOB_NAME"
echo "::group::Rendered vcjob manifest"
cat "$MANIFEST"
echo "::endgroup::"

kubectl apply -f "$MANIFEST"
log_info "vcjob 提交成功"

set_output "job_name" "$JOB_NAME"
set_output "log_artifact_name" "training-logs-${JOB_NAME}"

# -----------------------------------------------------------------------------
# 轮询等待完成
#   状态来源：vcjob .status.state.phase
#   终态：Completed（成功）/ Failed / Terminated / Aborted（失败）
# -----------------------------------------------------------------------------
START_TIME=$(date +%s)
FINAL_STATUS="timeout"
PENDING_WARNED=false

log_info "等待 vcjob 完成 (超时: ${TIMEOUT}s, 轮询: ${POLL_INTERVAL}s)..."

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))

  # 超时处理
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    log_error "vcjob 在 ${TIMEOUT}s 后超时"
    FINAL_STATUS="timeout"
    break
  fi

  # 读取 vcjob phase
  PHASE=$(kubectl get vcjob "$JOB_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.state.phase}' 2>/dev/null || echo "")

  case "$PHASE" in
    Completed)
      log_info "vcjob 执行成功 (phase=Completed)"
      FINAL_STATUS="succeeded"
      break
      ;;
    Failed|Terminated|Aborted)
      log_error "vcjob 执行失败 (phase=${PHASE})"
      FINAL_STATUS="failed"
      break
      ;;
  esac

  # 调度告警：Pod Pending 超过阈值时输出 FailedScheduling 事件（仅告警一次）
  if [ "$ELAPSED" -gt "$PENDING_WARN_THRESHOLD" ] && [ "$PENDING_WARNED" = false ]; then
    PENDING_PODS=$(kubectl get pods -n "$NAMESPACE" \
                     -l "volcano.sh/job-name=$JOB_NAME" \
                     --field-selector=status.phase=Pending \
                     -o name 2>/dev/null | wc -l | tr -d ' ')
    if [ "${PENDING_PODS:-0}" -gt 0 ]; then
      log_warn "仍有 ${PENDING_PODS} 个 pod 处于 Pending 超过 5 分钟，可能资源不足或调度受阻。"
      echo "::group::FailedScheduling events"
      kubectl get events -n "$NAMESPACE" \
        --field-selector "reason=FailedScheduling" \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
      echo "::endgroup::"
      PENDING_WARNED=true
    fi
  fi

  echo "  ⏳ 已用时: ${ELAPSED}s / ${TIMEOUT}s - phase=${PHASE:-<none>}"
  sleep "$POLL_INTERVAL"
done

DURATION=$(( $(date +%s) - START_TIME ))
set_output "job_status" "$FINAL_STATUS"
set_output "duration_seconds" "$DURATION"

# -----------------------------------------------------------------------------
# 收集所有 task pod 的日志 + describe，写入文件供后续 artifact 上传
# -----------------------------------------------------------------------------
log_info "从所有 task pod 收集日志..."
echo "::group::Collecting task pod logs"

PODS=$(kubectl get pods -n "$NAMESPACE" \
         -l "volcano.sh/job-name=$JOB_NAME" \
         -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

TASK_PODS=""
for pod in $PODS; do
  log_info "收集日志: $pod"
  kubectl logs "$pod" -n "$NAMESPACE" --all-containers=true \
    > "$LOG_DIR/${pod}.log" 2>&1 || true
  kubectl describe pod "$pod" -n "$NAMESPACE" \
    > "$LOG_DIR/${pod}-describe.txt" 2>&1 || true

  if [ -n "$TASK_PODS" ]; then
    TASK_PODS="${TASK_PODS},${pod}"
  else
    TASK_PODS="$pod"
  fi
done

set_output "task_pods" "$TASK_PODS"
echo "::endgroup::"

# -----------------------------------------------------------------------------
# 汇总
# -----------------------------------------------------------------------------
log_info "=== vcjob 执行汇总 ==="
log_info "Job:      $JOB_NAME"
log_info "Status:   $FINAL_STATUS"
log_info "Duration: ${DURATION}s"
log_info "Pods:     $TASK_PODS"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  STATUS_ICON="❌ ${FINAL_STATUS}"
  [ "$FINAL_STATUS" = "succeeded" ] && STATUS_ICON="✅ succeeded"
  cat >> "$GITHUB_STEP_SUMMARY" <<SUMMARY_EOF
## 🚀 PPU 分布式训练结果

| 字段 | 值 |
|------|-----|
| **Job Name** | \`${JOB_NAME}\` |
| **Status** | ${STATUS_ICON} |
| **Duration** | ${DURATION}s |
| **Queue** | ${QUEUE} |
| **Nodes** | ${NNODES} |
| **PPU/Node** | ${NPROC} |
| **Total PPU** | $(( NNODES * NPROC )) |
| **Image** | \`${IMAGE}\` |
| **Cleanup Policy** | ${CLEANUP_POLICY} |
SUMMARY_EOF
fi

# 失败/超时时以非零码退出，让 workflow step 标红
if [ "$FINAL_STATUS" != "succeeded" ]; then
  exit 1
fi
