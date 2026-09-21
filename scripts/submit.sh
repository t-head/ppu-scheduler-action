#!/usr/bin/env bash
set -euo pipefail

POLL_INTERVAL=30
PENDING_WARN_THRESHOLD=300
MANIFEST_DIR="/tmp/training-manifests"

mkdir -p "$MANIFEST_DIR"

log_info()  { echo "::notice::$*"; }
log_warn()  { echo "::warning::$*"; }
log_error() { echo "::error::$*"; }

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  else
    echo "[output] $1=$2"
  fi
}

sanitize_name() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/^-*//; s/-*$//'
}

# YAML 双引号字符串转义：将值中的特殊字符转义后可安全嵌入 value: "..." 中
yaml_escape_value() {
  local val="$1"
  val="${val//\\/\\\\}"       # \ → \\
  val="${val//\"/\\\"}"       # " → \\"
  val="${val//$'\n'/\\n}"     # 换行 → \n
  val="${val//$'\t'/\\t}"     # tab → \t
  printf '%s' "$val"
}

NNODES="${INPUT_NNODES:-0}"
NPROC="${INPUT_NPROC_PER_NODE:-1}"

# nnodes=0 表示单机模式：仅 1 pod，无 gang/service
SINGLE_MODE=false
if [ "$NNODES" -eq 0 ]; then
  SINGLE_MODE=true
  NNODES=1
fi
COMMAND="${INPUT_COMMAND:-}"
IMAGE="${INPUT_IMAGE:-}"
NAMESPACE="${INPUT_NAMESPACE:-default}"
TIMEOUT_MINUTES="${INPUT_TIMEOUT_MINUTES:-60}"
HOST_VOLUMES="${INPUT_HOST_VOLUMES:-}"
EXTRA_ENV="${INPUT_EXTRA_ENV:-}"
MASTER_PORT="${INPUT_MASTER_PORT:-29500}"
CLEANUP_POLICY="${INPUT_CLEANUP_POLICY:-always}"
NODE_SELECTOR="${INPUT_NODE_SELECTOR:-}"
SOURCE_STAGE_DIR="${SOURCE_STAGE_DIR:-}"
SOURCE_MOUNT_PATH="${INPUT_SOURCE_DIR:-/workspace/source}"
CONTAINER_OPTIONS="${CONTAINER_OPTIONS:-}"

# 默认 NAS 挂载定义（pod spec 与 host_volumes 去重共用同一份定义）
# 每项格式: "volumeName|containerMountPath|hostPath"
DEFAULT_NAS_VOLUMES=(
  "nas-aisw|/nas_aisw|/nas_aisw"
  "wl-nas|/mnt/wl_nas|/wl_nas"
)

TIMEOUT=$(( TIMEOUT_MINUTES * 60 ))

if [ -z "$IMAGE" ]; then
  log_error "input 'image' 必填，但为空。"
  exit 1
fi
if [ -z "$COMMAND" ]; then
  log_error "input 'command' 必填，但为空。"
  exit 1
fi

OWNER=$(sanitize_name "${GITHUB_REPOSITORY_OWNER:-unknown}" | cut -c1-20 | sed 's/-*$//')
RUN_ID="${GITHUB_RUN_ID:-0}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
# 优先使用用户传入的 job_suffix（解决 matrix 场景 github.job 相同导致命名冲突）
if [ -n "${INPUT_JOB_SUFFIX:-}" ]; then
  JOB_SUFFIX=$(sanitize_name "$INPUT_JOB_SUFFIX" | cut -c1-20 | sed 's/-*$//')
else
  JOB_SUFFIX=$(sanitize_name "${GITHUB_JOB_NAME:-job}" | cut -c1-20 | sed 's/-*$//')
fi
JOB_NAME="ppu-${OWNER}-${RUN_ID}-${RUN_ATTEMPT}-${JOB_SUFFIX}"
JOB_NAME=$(echo "$JOB_NAME" | cut -c1-63 | sed 's/-*$//')
set_output "job_name" "$JOB_NAME"

log_info "Job 名称:   $JOB_NAME"
log_info "命名空间:   $NAMESPACE"
if [ "$SINGLE_MODE" = true ]; then
  if [ "$NPROC" -gt 1 ]; then
    log_info "模式:       多卡 (${NPROC} PPU)"
  else
    log_info "模式:       单卡 (${NPROC} PPU)"
  fi
else
  log_info "规模:       ${NNODES} node(s) × ${NPROC} PPU/node"
fi
log_info "超时:       ${TIMEOUT_MINUTES}min (${TIMEOUT}s)"

if [ "$SINGLE_MODE" = false ]; then
  if ! kubectl get crd podgroups.scheduling.x-k8s.io >/dev/null 2>&1; then
    log_error "未检测到 PodGroup CRD (podgroups.scheduling.x-k8s.io)。无法进行 gang 调度。"
    exit 1
  fi
fi

EXTRA_ENV_YAML=""
if [ -n "$EXTRA_ENV" ]; then
  IFS=',' read -ra _env_pairs <<< "$EXTRA_ENV"
  for _pair in "${_env_pairs[@]}"; do
    [ -z "$_pair" ] && continue
    _key="${_pair%%=*}"
    _val="${_pair#*=}"
    _key=$(echo "$_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$_key" ] && continue
    _val=$(yaml_escape_value "$_val")
    EXTRA_ENV_YAML+="        - name: ${_key}"$'\n'
    EXTRA_ENV_YAML+="          value: \"${_val}\""$'\n'
  done
  EXTRA_ENV_YAML="${EXTRA_ENV_YAML%$'\n'}"
fi

# --- 从当前环境继承代理变量，注入 worker pod ---
# ARC Runner 通过 hook-extension-cpu ConfigMap 注入了代理变量，
# 这里将非空的代理变量透传给 worker pod，避免直连外网被 WAF 403。
# 放在 EXTRA_ENV_YAML 之前，用户可通过 extra_env 覆盖代理设置。
PROXY_ENV_YAML=""
for _proxy_var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
  _proxy_val="${!_proxy_var:-}"
  if [ -n "$_proxy_val" ]; then
    _proxy_val=$(yaml_escape_value "$_proxy_val")
    PROXY_ENV_YAML+="        - name: ${_proxy_var}"$'\n'
    PROXY_ENV_YAML+="          value: \"${_proxy_val}\""$'\n'
  fi
done
PROXY_ENV_YAML="${PROXY_ENV_YAML%$'\n'}"
if [ -n "$PROXY_ENV_YAML" ]; then
  log_info "代理环境变量将注入 worker pod"
fi

# === 用户 workflow/job env 自动转发 ===
USER_ENV_YAML=""
if [[ -n "${USER_ENV_JSON:-}" && "${USER_ENV_JSON}" != "{}" && "${USER_ENV_JSON}" != "null" ]]; then
  while IFS= read -r line; do
    _key="${line%%=*}"
    _b64val="${line#*=}"
    [[ -z "${_key}" ]] && continue
    # 跳过 action 内部变量，避免二次注入
    case "$_key" in
      INPUT_*|CONTAINER_OPTIONS|SOURCE_STAGE_DIR|USER_ENV_JSON|GITHUB_*) continue ;;
    esac
    _val=$(echo "${_b64val}" | base64 -d)
    _val=$(yaml_escape_value "$_val")
    USER_ENV_YAML+="        - name: \"${_key}\""$'\n'
    USER_ENV_YAML+="          value: \"${_val}\""$'\n'
  done < <(echo "${USER_ENV_JSON}" | jq -r 'to_entries[] | "\(.key)=\(.value | @base64)"')
  USER_ENV_YAML="${USER_ENV_YAML%$'\n'}"
  if [[ -n "${USER_ENV_YAML}" ]]; then
    log_info "用户 env 变量将注入 worker pod: $(echo "${USER_ENV_JSON}" | jq -r 'keys | join(", ")')"
  fi
fi

NODE_SELECTOR_YAML=""
if [ -n "$NODE_SELECTOR" ]; then
  _ns_items=""
  IFS=',' read -ra _ns_pairs <<< "$NODE_SELECTOR"
  for _pair in "${_ns_pairs[@]}"; do
    [ -z "$_pair" ] && continue
    _key="${_pair%%=*}"
    _val="${_pair#*=}"
    _key=$(echo "$_key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$_key" ] && continue

    _key_name="$_key"
    if [[ "$_key" == */* ]]; then
      _key_prefix="${_key%/*}"
      _key_name="${_key##*/}"
      if [ ${#_key_prefix} -gt 253 ] || [ -z "$_key_prefix" ] \
         || ! [[ "$_key_prefix" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?$ ]]; then
        log_error "node_selector: key 前缀不合法: '${_key_prefix}'"
        exit 1
      fi
    fi
    if [ -z "$_key_name" ] || [ ${#_key_name} -gt 63 ] \
       || ! [[ "$_key_name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,61}[a-zA-Z0-9])?$ ]]; then
      log_error "node_selector: key 名称不合法: '${_key_name}'"
      exit 1
    fi

    if [ -n "$_val" ]; then
      if [ ${#_val} -gt 63 ] \
         || ! [[ "$_val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,61}[a-zA-Z0-9])?$ ]]; then
        log_error "node_selector: value 不合法: '${_val}'"
        exit 1
      fi
    fi

    _ns_items+="    ${_key}: \"${_val}\""$'\n'
  done
  _ns_items="${_ns_items%$'\n'}"
  if [ -n "$_ns_items" ]; then
    NODE_SELECTOR_YAML="  nodeSelector:"$'\n'"${_ns_items}"
  fi
fi

# --- Container runtime options 解析 ---
# CONTAINER_OPTIONS 为用户传入的 YAML 片段（可多行），支持的键：
#   privileged:   true/false             → 容器 securityContext.privileged
#   host_ipc:     true/false             → pod spec.hostIPC
#   host_network: true/false             → pod spec.hostNetwork
#   dns_policy:   "ClusterFirstWithHostNet" → pod spec.dnsPolicy
#   shm_size:     "8Gi"                  → /dev/shm emptyDir sizeLimit（默认 64Gi）
#   cap_add:      "SYS_PTRACE,IPC_LOCK"  → securityContext.capabilities.add（逗号分隔）
# 留空时全部保持默认，行为与未引入本选项前完全一致。
PRIVILEGED="false"
HOST_IPC="false"
HOST_NETWORK="false"
DNS_POLICY=""
SHM_SIZE=""
CAP_ADD=""

# 提取指定键的取值：键名大小写不敏感；值去引号与空白。
# 注：pipefail 下 grep 无匹配会使管道非零，尾部 || true 兜底，空值由调用方回退默认。
_co_opt_value() {
  printf '%s\n' "$CONTAINER_OPTIONS" | grep -i "^[[:space:]]*${1}:" | head -1 | awk '{print $2}' | tr -d "\"' " || true
}

if [ -n "$CONTAINER_OPTIONS" ]; then
  PRIVILEGED=$(_co_opt_value 'privileged'); PRIVILEGED="${PRIVILEGED:-false}"
  HOST_IPC=$(_co_opt_value 'host_ipc');     HOST_IPC="${HOST_IPC:-false}"
  HOST_NETWORK=$(_co_opt_value 'host_network'); HOST_NETWORK="${HOST_NETWORK:-false}"
  DNS_POLICY=$(_co_opt_value 'dns_policy')
  SHM_SIZE=$(_co_opt_value 'shm_size')
  CAP_ADD=$(_co_opt_value 'cap_add')

  # 布尔值规范化（True/TRUE → true）并校验
  PRIVILEGED=$(printf '%s' "$PRIVILEGED" | tr '[:upper:]' '[:lower:]')
  HOST_IPC=$(printf '%s' "$HOST_IPC" | tr '[:upper:]' '[:lower:]')
  HOST_NETWORK=$(printf '%s' "$HOST_NETWORK" | tr '[:upper:]' '[:lower:]')
  if [ "$PRIVILEGED" != "true" ] && [ "$PRIVILEGED" != "false" ]; then
    log_error "container_options: privileged 取值必须为 true/false，实际为 '${PRIVILEGED}'"
    exit 1
  fi
  if [ "$HOST_IPC" != "true" ] && [ "$HOST_IPC" != "false" ]; then
    log_error "container_options: host_ipc 取值必须为 true/false，实际为 '${HOST_IPC}'"
    exit 1
  fi
  if [ "$HOST_NETWORK" != "true" ] && [ "$HOST_NETWORK" != "false" ]; then
    log_error "container_options: host_network 取值必须为 true/false，实际为 '${HOST_NETWORK}'"
    exit 1
  fi

  # dns_policy 校验并规范化为 K8s 的驼峰取值。None 需同时提供 dnsConfig，
  # 本 action 不生成 dnsConfig，故明确拒绝，而不是产出一份会被 apiserver 打回的 pod spec。
  if [ -n "$DNS_POLICY" ]; then
    case "$(printf '%s' "$DNS_POLICY" | tr '[:upper:]' '[:lower:]')" in
      clusterfirst)            DNS_POLICY="ClusterFirst" ;;
      clusterfirstwithhostnet) DNS_POLICY="ClusterFirstWithHostNet" ;;
      default)                 DNS_POLICY="Default" ;;
      *)
        log_error "container_options: dns_policy 取值必须为 ClusterFirst/ClusterFirstWithHostNet/Default，实际为 '${DNS_POLICY}'"
        exit 1
        ;;
    esac
  fi

  # shm_size 校验（K8s quantity，如 8Gi / 512Mi / 1024），同时防非法字符注入 YAML
  if [ -n "$SHM_SIZE" ]; then
    if ! [[ "$SHM_SIZE" =~ ^[0-9]+(\.[0-9]+)?([kMGTPE]i?)?$ ]]; then
      log_error "container_options: shm_size 不是合法的 K8s size（示例: 8Gi、512Mi），实际为 '${SHM_SIZE}'"
      exit 1
    fi
  fi

  log_info "container_options: privileged=${PRIVILEGED} host_ipc=${HOST_IPC} host_network=${HOST_NETWORK} dns_policy=${DNS_POLICY:-<集群默认>} shm_size=${SHM_SIZE:-64Gi(默认)} cap_add=${CAP_ADD:-<none>}"
fi

# hostNetwork 与默认的 ClusterFirst 组合，会让 pod 拿到宿主 resolver，于是本 action
# 自己注入的 MASTER_ADDR（headless Service 的 *.svc.cluster.local）无法解析，
# 多机 rendezvous 必然失败。K8s 对这一组合的官方解法就是
# ClusterFirstWithHostNet：集群内名字走 CoreDNS，其余仍由 CoreDNS 按上游转发。
# 未显式指定 dns_policy 时按此补齐；显式指定则一律尊重用户取值。
if [ "$HOST_NETWORK" = "true" ] && [ -z "$DNS_POLICY" ]; then
  DNS_POLICY="ClusterFirstWithHostNet"
  log_info "host_network=true，dnsPolicy 自动置为 ClusterFirstWithHostNet（可用 container_options.dns_policy 覆盖）"
fi

# /dev/shm 大小（默认 64Gi，与历史行为一致）
SHM_SIZE_LIMIT="${SHM_SIZE:-64Gi}"

# cap_add → securityContext.capabilities.add 列表项（12 空格缩进，对齐 add: 下的列表）
CAP_ADD_ITEMS=""
if [ -n "$CAP_ADD" ]; then
  IFS=',' read -ra _caps <<< "$CAP_ADD"
  for _cap in "${_caps[@]}"; do
    _cap=$(printf '%s' "$_cap" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')
    [ -z "$_cap" ] && continue
    # K8s capability 名称：大写字母开头，仅大写字母/数字/下划线
    if ! [[ "$_cap" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      log_error "container_options: cap_add 含不合法的 capability 名称 '${_cap}'（示例: SYS_PTRACE,IPC_LOCK）"
      exit 1
    fi
    CAP_ADD_ITEMS+="            - ${_cap}"$'\n'
  done
  CAP_ADD_ITEMS="${CAP_ADD_ITEMS%$'\n'}"
fi

# 容器级 securityContext 片段（6 空格缩进，与 image/env/resources 同级）
SECURITY_CONTEXT_YAML=""
if [ "$PRIVILEGED" = "true" ] || [ -n "$CAP_ADD_ITEMS" ]; then
  _sc="      securityContext:"
  if [ "$PRIVILEGED" = "true" ]; then
    _sc+=$'\n'"        privileged: true"
  fi
  if [ -n "$CAP_ADD_ITEMS" ]; then
    _sc+=$'\n'"        capabilities:"
    _sc+=$'\n'"          add:"
    _sc+=$'\n'"$CAP_ADD_ITEMS"
  fi
  SECURITY_CONTEXT_YAML="$_sc"
fi

# pod 级选项片段（2 空格缩进，与 nodeSelector/containers 同级）
POD_LEVEL_OPTIONS_YAML=""
_append_pod_option() {
  if [ -n "$POD_LEVEL_OPTIONS_YAML" ]; then
    POD_LEVEL_OPTIONS_YAML+=$'\n'"  ${1}"
  else
    POD_LEVEL_OPTIONS_YAML="  ${1}"
  fi
}
if [ "$HOST_IPC" = "true" ]; then
  _append_pod_option "hostIPC: true"
fi
if [ "$HOST_NETWORK" = "true" ]; then
  _append_pod_option "hostNetwork: true"
fi
if [ -n "$DNS_POLICY" ]; then
  _append_pod_option "dnsPolicy: ${DNS_POLICY}"
fi

HOST_VOLUME_MOUNTS=""
HOST_VOLUME_DEFS=""
if [ -n "$HOST_VOLUMES" ]; then
  _vol_idx=0
  IFS=',' read -ra _vol_pairs <<< "$HOST_VOLUMES"
  for _pair in "${_vol_pairs[@]}"; do
    [ -z "$_pair" ] && continue
    _host_path="${_pair%%:*}"
    _container_path="${_pair#*:}"
    if [ -z "$_host_path" ] || [ -z "$_container_path" ]; then
      log_error "host_volumes 格式错误: '${_pair}'，应为 /host/path:/container/path"
      exit 1
    fi
    # 过滤与默认 NAS 挂载重复的路径
    _is_default=false
    for _def_entry in "${DEFAULT_NAS_VOLUMES[@]}"; do
      _def_path="${_def_entry#*|}"; _def_path="${_def_path%%|*}"
      if [ "$_container_path" = "$_def_path" ]; then
        _is_default=true
        break
      fi
    done
    if [ "$_is_default" = true ]; then
      log_warn "host_volumes 条目 '${_pair}' 的挂载路径 ${_container_path} 已是默认挂载，已跳过以避免重复。"
      continue
    fi
    _vol_name="host-vol-${_vol_idx}"
    HOST_VOLUME_MOUNTS+="        - name: ${_vol_name}"$'\n'
    HOST_VOLUME_MOUNTS+="          mountPath: ${_container_path}"$'\n'
    HOST_VOLUME_DEFS+="    - name: ${_vol_name}"$'\n'
    HOST_VOLUME_DEFS+="      hostPath:"$'\n'
    HOST_VOLUME_DEFS+="        path: ${_host_path}"$'\n'
    HOST_VOLUME_DEFS+="        type: DirectoryOrCreate"$'\n'
    _vol_idx=$(( _vol_idx + 1 ))
  done
  HOST_VOLUME_MOUNTS="${HOST_VOLUME_MOUNTS%$'\n'}"
  HOST_VOLUME_DEFS="${HOST_VOLUME_DEFS%$'\n'}"
  log_info "host_volumes 解析结果:"
  echo "${HOST_VOLUME_MOUNTS}" >&2
  echo "${HOST_VOLUME_DEFS}" >&2
fi

# --- NAS 源码 tarball 解压注入 ---
# SOURCE_STAGE_DIR 为 CPU runner 视角的 tarball 路径（/wl_nas/devops/xxx/source.tar.gz），
# PPU pod 通过默认 NAS 挂载（/mnt/wl_nas）访问同一份文件，路径前缀需做映射。
if [ -n "$SOURCE_STAGE_DIR" ]; then
  # CPU runner 容器内 NAS 路径 /wl_nas → PPU pod 容器内 NAS 路径 /mnt/wl_nas
  # 注：不用 patsub（${var/\/wl_nas\//...}）——bash 的替换串中 \/ 会字面保留反斜杠
  if [[ "$SOURCE_STAGE_DIR" == /wl_nas/* ]]; then
    TARBALL_PATH_IN_POD="/mnt/wl_nas/${SOURCE_STAGE_DIR#/wl_nas/}"
  else
    TARBALL_PATH_IN_POD="$SOURCE_STAGE_DIR"
  fi
  EXTRACT_CMD="mkdir -p ${SOURCE_MOUNT_PATH} && tar xzf ${TARBALL_PATH_IN_POD} -C ${SOURCE_MOUNT_PATH} && echo '✓ 源码已解压到 ${SOURCE_MOUNT_PATH}'"
  COMMAND="${EXTRACT_CMD} && ${COMMAND}"
  log_info "源码 tarball 解压注入: ${TARBALL_PATH_IN_POD} → ${SOURCE_MOUNT_PATH}"
fi

SCRIPT_INDENTED=$(printf '%s\n' "$COMMAND" | sed 's/^/          /')

# --- 清理同名旧资源 ---
log_info "清理同名旧资源（若存在）: $JOB_NAME"
kubectl delete pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" --ignore-not-found=true 2>/dev/null || true
kubectl delete svc "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
kubectl delete podgroups.scheduling.x-k8s.io "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
sleep 3

# --- 创建 Headless Service ---
if [ "$SINGLE_MODE" = false ]; then
  SVC_MANIFEST="$MANIFEST_DIR/service.yaml"
  cat > "$SVC_MANIFEST" <<SVC_EOF
apiVersion: v1
kind: Service
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  clusterIP: None
  selector:
    ppu-job: ${JOB_NAME}
  ports:
    - name: master
      port: ${MASTER_PORT}
      targetPort: ${MASTER_PORT}
SVC_EOF

  log_info "创建 Headless Service: $JOB_NAME"
  kubectl apply -f "$SVC_MANIFEST"

  # --- 创建 PodGroup ---
  PG_MANIFEST="$MANIFEST_DIR/podgroup.yaml"
  cat > "$PG_MANIFEST" <<PG_EOF
apiVersion: scheduling.x-k8s.io/v1alpha1
kind: PodGroup
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  minMember: ${NNODES}
PG_EOF

  log_info "创建 PodGroup: $JOB_NAME (minMember=$NNODES)"
  kubectl apply -f "$PG_MANIFEST"
else
  log_info "单卡/多卡模式：跳过 Service/PodGroup 创建"
fi

# --- 构建 Pod labels（gang 模式才包含 pod-group label）---
POD_LABELS="    ppu-job: ${JOB_NAME}"
if [ "$SINGLE_MODE" = false ]; then
  POD_LABELS="${POD_LABELS}"$'\n'"    scheduling.x-k8s.io/pod-group: ${JOB_NAME}"
fi
POD_LABELS="${POD_LABELS}"$'\n'"    app.kubernetes.io/managed-by: ppu-distributed-action"

# 从 DEFAULT_NAS_VOLUMES 动态生成 pod spec 中的 NAS volumeMounts 和 volumes
DEFAULT_NAS_VOLUME_MOUNTS=""
DEFAULT_NAS_VOLUME_DEFS=""
for _def_entry in "${DEFAULT_NAS_VOLUMES[@]}"; do
  IFS='|' read -r _vname _mpath _hpath <<< "$_def_entry"
  DEFAULT_NAS_VOLUME_MOUNTS+="        - name: ${_vname}"$'\n'
  DEFAULT_NAS_VOLUME_MOUNTS+="          mountPath: ${_mpath}"$'\n'
  DEFAULT_NAS_VOLUME_DEFS+="    - name: ${_vname}"$'\n'
  DEFAULT_NAS_VOLUME_DEFS+="      hostPath:"$'\n'
  DEFAULT_NAS_VOLUME_DEFS+="        path: ${_hpath}"$'\n'
  DEFAULT_NAS_VOLUME_DEFS+="        type: DirectoryOrCreate"$'\n'
done
DEFAULT_NAS_VOLUME_MOUNTS="${DEFAULT_NAS_VOLUME_MOUNTS%$'\n'}"
DEFAULT_NAS_VOLUME_DEFS="${DEFAULT_NAS_VOLUME_DEFS%$'\n'}"

# --- 循环创建 N 个 Pod ---
for i in $(seq 0 $(( NNODES - 1 ))); do
  POD_MANIFEST="$MANIFEST_DIR/pod-worker-${i}.yaml"
  cat > "$POD_MANIFEST" <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${JOB_NAME}-worker-${i}
  namespace: ${NAMESPACE}
  labels:
${POD_LABELS}
    worker-index: "${i}"
spec:
  schedulerName: default-scheduler
  hostname: ${JOB_NAME}-worker-${i}
  subdomain: ${JOB_NAME}
  restartPolicy: Never
${NODE_SELECTOR_YAML}
${POD_LEVEL_OPTIONS_YAML}
  dnsConfig:
    options:
    - name: ndots
      value: "2"
    - name: single-request-reopen
    - name: attempts
      value: "3"
    - name: timeout
      value: "2"
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
        - name: WORLD_SIZE
          value: "${NNODES}"
        - name: MASTER_PORT
          value: "${MASTER_PORT}"
        - name: LOCAL_RANK
          value: "0"
        - name: NODE_RANK
          value: "${i}"
        - name: RANK
          value: "${i}"
        - name: MASTER_ADDR
          value: "${JOB_NAME}-worker-0.${JOB_NAME}.${NAMESPACE}.svc.cluster.local"
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
${PROXY_ENV_YAML}
${USER_ENV_YAML}
${EXTRA_ENV_YAML}
      resources:
        requests:
          alibabacloud.com/ppu: "${NPROC}"
        limits:
          alibabacloud.com/ppu: "${NPROC}"
${SECURITY_CONTEXT_YAML}
      volumeMounts:
        - name: dshm
          mountPath: /dev/shm
${DEFAULT_NAS_VOLUME_MOUNTS}
${HOST_VOLUME_MOUNTS}
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: ${SHM_SIZE_LIMIT}
${DEFAULT_NAS_VOLUME_DEFS}
${HOST_VOLUME_DEFS}
POD_EOF

  log_info "创建 Pod: ${JOB_NAME}-worker-${i}"
  kubectl apply -f "$POD_MANIFEST"
done

log_info "所有 ${NNODES} 个 worker Pod 已提交"

# --- 写入任务记录到 NAS ---
{
  TASK_DIR="/wl_nas/devops/ppu-dashboard/tasks"
  mkdir -p "$TASK_DIR" 2>/dev/null || true
  TASK_FILE="${TASK_DIR}/${JOB_NAME}.json"
  cat > "$TASK_FILE" <<TASK_EOF
{
  "run_id": "${RUN_ID}",
  "run_attempt": "${RUN_ATTEMPT}",
  "repo": "${GITHUB_REPOSITORY}",
  "job_name": "${JOB_NAME}",
  "github_job": "${GITHUB_JOB_NAME}",
  "pod_name": "${JOB_NAME}-worker-0",
  "namespace": "${NAMESPACE}",
  "ppu_per_node": ${NPROC},
  "nnodes": ${NNODES},
  "ppu_total": $(( NNODES * NPROC )),
  "start_time": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "status": "running"
}
TASK_EOF
  log_info "任务记录已写入: ${TASK_FILE}"
} 2>/dev/null || true

# --- 打印各 Pod 调度节点 ---
sleep 5
for i in $(seq 0 $(( NNODES - 1 ))); do
  _pod="${JOB_NAME}-worker-${i}"
  _node=$(kubectl get pod "$_pod" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "pending")
  log_info "Pod ${_pod} → Node: ${_node}"
done

# --- 实时流式日志（仅 worker-0）---
POD_W0="${JOB_NAME}-worker-0"
(
  while ! kubectl logs "$POD_W0" -n "$NAMESPACE" -f 2>/dev/null; do
    sleep 3
  done
) | sed -u "s/^/[worker-0] /" &
LOG_PID=$!
START_TIME=$(date +%s)
FINAL_STATUS="timeout"
PENDING_WARNED=false

log_info "等待所有 Pod 完成 (超时: ${TIMEOUT}s, 轮询: ${POLL_INTERVAL}s)..."

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))

  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    log_error "作业在 ${TIMEOUT}s 后超时"
    FINAL_STATUS="timeout"
    break
  fi

  TOTAL_PODS=$NNODES
  SUCCEEDED=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" \
    --field-selector=status.phase=Succeeded -o name 2>/dev/null | wc -l | tr -d ' ')
  FAILED=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" \
    --field-selector=status.phase=Failed -o name 2>/dev/null | wc -l | tr -d ' ')
  RUNNING=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')

  if [ "$SUCCEEDED" -eq "$TOTAL_PODS" ]; then
    log_info "所有 Pod 执行成功 (succeeded=$SUCCEEDED)"
    FINAL_STATUS="succeeded"
    break
  fi
  if [ "$FAILED" -gt 0 ]; then
    log_error "有 Pod 执行失败 (failed=$FAILED)"
    FINAL_STATUS="failed"
    break
  fi

  if [ "$ELAPSED" -gt "$PENDING_WARN_THRESHOLD" ] && [ "$PENDING_WARNED" = false ]; then
    PENDING_PODS=$(kubectl get pods -n "$NAMESPACE" \
                     -l "ppu-job=$JOB_NAME" \
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

  echo "  ⏳ ${ELAPSED}s/${TIMEOUT}s - running=$RUNNING succeeded=$SUCCEEDED failed=$FAILED"
  sleep "$POLL_INTERVAL"
done

# 停止日志流
kill $LOG_PID 2>/dev/null || true
wait 2>/dev/null || true

DURATION=$(( $(date +%s) - START_TIME ))
set_output "job_status" "$FINAL_STATUS"
set_output "duration_seconds" "$DURATION"

# --- 收集 pod 名称 ---
PODS=$(kubectl get pods -n "$NAMESPACE" \
         -l "ppu-job=$JOB_NAME" \
         -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

TASK_PODS=""
for pod in $PODS; do
  if [ -n "$TASK_PODS" ]; then
    TASK_PODS="${TASK_PODS},${pod}"
  else
    TASK_PODS="$pod"
  fi
done

set_output "task_pods" "$TASK_PODS"

log_info "=== 作业执行汇总 ==="
log_info "Job:      $JOB_NAME"
log_info "Status:   $FINAL_STATUS"
log_info "Duration: ${DURATION}s"
log_info "Pods:     $TASK_PODS"

# 直接更新任务记录终态（不依赖 cleanup.sh 的 output 传递）
if [ -f "${TASK_FILE:-}" ] && command -v jq >/dev/null 2>&1; then
  jq --arg end_time "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg status "$FINAL_STATUS" \
    '.end_time = $end_time | .status = $status' "$TASK_FILE" > "${TASK_FILE}.tmp" && mv "${TASK_FILE}.tmp" "$TASK_FILE"
  log_info "任务记录已更新终态: ${TASK_FILE}"
fi

if [ "$FINAL_STATUS" != "succeeded" ]; then
  exit 1
fi
