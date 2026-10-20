#!/usr/bin/env bash
set -euo pipefail

POLL_INTERVAL=30
PENDING_WARN_THRESHOLD=300
MANIFEST_DIR="/tmp/training-manifests"

mkdir -p "$MANIFEST_DIR"

log_info()  { echo "$*"; }
log_warn()  { echo "[warn] $*"; }
log_error() { echo "::error::$*"; }

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  else
    echo "[output] $1=$2"
  fi
}

# --- 预设默认输出（防止脚本异常退出时 cleanup 拿不到 job_status）---
set_output "job_status" "unknown"
set_output "duration_seconds" "0"
set_output "queue_duration_seconds" "0"
set_output "unscheduled_pods" "0"
set_output "pod_queue" ""
set_output "queue_reason" ""
set_output "occupied_ppu_card_hours" "0.0000"
set_output "execution_ppu_card_hours" "0.0000"

# --- SIGTERM/SIGINT trap（解决外部取消导致 unknown 状态）---
_on_signal() {
  log_warn "收到终止信号，标记任务为 cancelled"
  set_output "job_status" "cancelled"
  exit 130
}
trap '_on_signal' TERM INT

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
DMESG_POLICY="${INPUT_DMESG_POLICY:-never}"

case "$DMESG_POLICY" in
  never|on_failure|always) ;;
  *)
    log_error "dmesg_policy 取值必须为 never/on_failure/always，实际为 '${DMESG_POLICY}'"
    exit 1
    ;;
esac

# 默认 NAS 挂载定义（pod spec 与 host_volumes 去重共用同一份定义）
# 每项格式: "volumeName|containerMountPath|hostPath"
DEFAULT_NAS_VOLUMES=(
  "nas-aisw|/nas_aisw|/nas_aisw"
  "wl-nas|/mnt/wl_nas|/wl_nas"
  "wl-nas-direct|/wl_nas|/wl_nas"
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

RUN_ID="${GITHUB_RUN_ID:-0}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
JOB_NAME="${JOB_NAME:-}"
if [ -z "$JOB_NAME" ]; then
  log_error "JOB_NAME 为空（应由 Resolve job name 步骤计算）"
  exit 1
fi
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
BOARD_TYPE=""
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

    [ "$_key" = "board-type" ] && BOARD_TYPE="$_val"
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
#   cpus:         "8" / "1.5" / "500m"   → resources.limits.cpu（别名 cpu）
#   memory:       "64Gi" / "64g"         → resources.limits.memory（docker 小写单位按 1024 进制转换）
# cpus/memory 留空时按卡型和 NPROC 自动计算，其他选项保持各自默认值。
PRIVILEGED="false"
HOST_IPC="false"
HOST_NETWORK="false"
DNS_POLICY=""
SHM_SIZE=""
CAP_ADD=""
CPUS=""
MEMORY=""

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
  CPUS=$(_co_opt_value 'cpus'); [ -z "$CPUS" ] && CPUS=$(_co_opt_value 'cpu')
  MEMORY=$(_co_opt_value 'memory')

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

  if [ -n "$CPUS" ]; then
    if ! [[ "$CPUS" =~ ^([0-9]+(\.[0-9]+)?|[0-9]+m)$ ]]; then
      log_error "container_options: cpus 不是合法的 CPU 数量（示例: 8、1.5、500m），实际为 '${CPUS}'"
      exit 1
    fi
  fi

  # docker 的 b/k/m/g/t 为 1024 进制，而 K8s 中小写 m 表示 milli，须转换为 Ki/Mi/Gi/Ti
  if [ -n "$MEMORY" ]; then
    if [[ "$MEMORY" =~ ^([0-9]+)([bkmgt])$ ]]; then
      case "${BASH_REMATCH[2]}" in
        b) MEMORY="${BASH_REMATCH[1]}" ;;
        k) MEMORY="${BASH_REMATCH[1]}Ki" ;;
        m) MEMORY="${BASH_REMATCH[1]}Mi" ;;
        g) MEMORY="${BASH_REMATCH[1]}Gi" ;;
        t) MEMORY="${BASH_REMATCH[1]}Ti" ;;
      esac
    elif ! [[ "$MEMORY" =~ ^[0-9]+(\.[0-9]+)?([KMGTPE]i?|k)?$ ]]; then
      log_error "container_options: memory 不是合法的内存大小（示例: 64Gi、512Mi、64g），实际为 '${MEMORY}'"
      exit 1
    fi
  fi
fi

if [ -z "$CPUS" ]; then
  case "$BOARD_TYPE" in
    ZW-M890P)
      CPU_PER_PPU=31
      CPU_MAX=248
      ;;
    OAM-810E|"")
      CPU_PER_PPU=11
      CPU_MAX=176
      ;;
    *)
      log_error "node_selector: 未知 board-type '${BOARD_TYPE}'，无法确定默认 CPU；请显式设置 container_options.cpus"
      exit 1
      ;;
  esac
  CPUS=$((NPROC * CPU_PER_PPU))
  [ "$CPUS" -gt "$CPU_MAX" ] && CPUS="$CPU_MAX"
  log_info "container_options.cpus 未设置，按 board-type=${BOARD_TYPE:-<未指定，按OAM-810E>}、${NPROC} PPU 自动设置为 ${CPUS}"
fi

if [ -z "$MEMORY" ]; then
  case "$BOARD_TYPE" in
    ZW-M890P)
      MEMORY_PER_PPU_GI=256
      MEMORY_MAX_GI=2048
      ;;
    OAM-810E|"")
      MEMORY_PER_PPU_GI=112
      MEMORY_MAX_GI=1792
      ;;
    *)
      log_error "node_selector: 未知 board-type '${BOARD_TYPE}'，无法确定默认内存；请显式设置 container_options.memory"
      exit 1
      ;;
  esac
  MEMORY_GI=$((NPROC * MEMORY_PER_PPU_GI))
  [ "$MEMORY_GI" -gt "$MEMORY_MAX_GI" ] && MEMORY_GI="$MEMORY_MAX_GI"
  MEMORY="${MEMORY_GI}Gi"
  log_info "container_options.memory 未设置，按 board-type=${BOARD_TYPE:-<未指定，按OAM-810E>}、${NPROC} PPU 自动设置为 ${MEMORY}"
fi

log_info "container_options: privileged=${PRIVILEGED} host_ipc=${HOST_IPC} host_network=${HOST_NETWORK} dns_policy=${DNS_POLICY:-<集群默认>} shm_size=${SHM_SIZE:-64Gi(默认)} cap_add=${CAP_ADD:-<none>} cpus=${CPUS:-<不限>} memory=${MEMORY}"

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

# 仅设 limits：K8s 会把未声明的 requests 默认为同值，与 docker --cpus/--memory 的硬上限语义一致
RESOURCE_LIMITS_YAML=""
[ -n "$CPUS" ] && RESOURCE_LIMITS_YAML+="          cpu: \"${CPUS}\""$'\n'
[ -n "$MEMORY" ] && RESOURCE_LIMITS_YAML+="          memory: \"${MEMORY}\""$'\n'
RESOURCE_LIMITS_YAML="${RESOURCE_LIMITS_YAML%$'\n'}"

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
  EXTRACT_CMD="mkdir -p ${SOURCE_MOUNT_PATH} && tar xzf ${TARBALL_PATH_IN_POD} -C ${SOURCE_MOUNT_PATH} && cd ${SOURCE_MOUNT_PATH} && echo '✓ 源码已解压到 ${SOURCE_MOUNT_PATH}'"
  COMMAND="${EXTRACT_CMD} && ${COMMAND}"
  log_info "源码 tarball 解压注入: ${TARBALL_PATH_IN_POD} → ${SOURCE_MOUNT_PATH}"
fi

if [ "$DMESG_POLICY" != "never" ]; then
  DMESG_DIR_IN_POD="/mnt/wl_nas/devops/dmesg/${RUN_ID}-${RUN_ATTEMPT}/${JOB_NAME}"
  DMESG_COLLECTOR=$(<"$(dirname "${BASH_SOURCE[0]}")/dmesg-collector.sh")
  COMMAND="${DMESG_COLLECTOR}
PPU_DMESG_DIR='${DMESG_DIR_IN_POD}'
export PPU_DMESG_DIR
_ppu_dmesg_begin
_ppu_worker_pid=''
_ppu_worker_signal() {
  trap - TERM INT
  [ -n \"\${_ppu_worker_pid:-}\" ] && kill -TERM \"\$_ppu_worker_pid\" 2>/dev/null
  wait \"\$_ppu_worker_pid\" 2>/dev/null
  _ppu_dmesg_end \"\$1\"
  exit \"\$1\"
}
trap '_ppu_worker_signal 143' TERM
trap '_ppu_worker_signal 130' INT
(
${COMMAND}
) &
_ppu_worker_pid=\$!
wait \"\$_ppu_worker_pid\"
_ppu_command_rc=\$?
trap - TERM INT
_ppu_dmesg_end \"\$_ppu_command_rc\"
exit \"\$_ppu_command_rc\""
  log_info "dmesg 采集策略: ${DMESG_POLICY}，NAS 路径: /wl_nas/devops/dmesg/${RUN_ID}-${RUN_ATTEMPT}/${JOB_NAME}"
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
  kubectl create -f "$SVC_MANIFEST"

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
  kubectl create -f "$PG_MANIFEST"
else
  log_info "单卡/多卡模式：跳过 Service/PodGroup 创建"
fi

# --- 构建 Pod labels（gang 模式才包含 pod-group label）---
POD_LABELS="    ppu-job: ${JOB_NAME}"
if [ "$SINGLE_MODE" = false ]; then
  POD_LABELS="${POD_LABELS}"$'\n'"    scheduling.x-k8s.io/pod-group: ${JOB_NAME}"
fi
POD_LABELS="${POD_LABELS}"$'\n'"    app.kubernetes.io/managed-by: ppu-distributed-action"

POD_AFFINITY_YAML=""
if [ "$NNODES" -gt 1 ]; then
  POD_AFFINITY_YAML=$(cat <<AFFINITY_EOF
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              ppu-job: "${JOB_NAME}"
          topologyKey: kubernetes.io/hostname
AFFINITY_EOF
)
fi

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
  schedulerName: ppu-scheduler
  hostname: ${JOB_NAME}-worker-${i}
  subdomain: ${JOB_NAME}
  restartPolicy: Never
${POD_AFFINITY_YAML}
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
      command: ["/bin/bash", "-c"]
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
${RESOURCE_LIMITS_YAML}
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
  kubectl create -f "$POD_MANIFEST"
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
  "status": "pending"
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
# 进程替换让 $! 指向重试子 shell 而非 sed；子进程放后台 wait，TERM 才能及时连带终止
(
  _log_child=""
  trap 'kill "$_log_child" 2>/dev/null; exit 0' TERM
  while true; do
    kubectl logs "$POD_W0" -n "$NAMESPACE" -f 2>/dev/null &
    _log_child=$!
    wait "$_log_child" && break
    sleep 3 &
    _log_child=$!
    wait "$_log_child" || true
  done
) > >(sed -u "s/^/[worker-0] /") &
LOG_PID=$!
START_TIME=$(date +%s)
FINAL_STATUS="timeout"
PENDING_NOTICE_SHOWN=false
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
    --field-selector=status.phase=Succeeded -o name 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  FAILED=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" \
    --field-selector=status.phase=Failed -o name 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  RUNNING=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  PENDING=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" \
    --field-selector=status.phase=Pending -o name 2>/dev/null | wc -l | tr -d ' ' || echo 0)

  if [ "$PENDING" -gt 0 ] && [ "$PENDING_NOTICE_SHOWN" = false ]; then
    log_info "${PENDING} 个 PPU Pod 处于 Pending，正在等待调度。"
    PENDING_NOTICE_SHOWN=true
  fi

  if [ -f "${TASK_FILE:-}" ] && command -v jq >/dev/null 2>&1; then
    TASK_RUNTIME_STATUS="pending"
    if [ "$RUNNING" -gt 0 ] || [ "$SUCCEEDED" -gt 0 ]; then
      TASK_RUNTIME_STATUS="running"
    fi
    TASK_RECORDED_STATUS=$(jq -r '.status // empty' "$TASK_FILE" 2>/dev/null || true)
    if [ "$TASK_RECORDED_STATUS" != "$TASK_RUNTIME_STATUS" ]; then
      jq --arg status "$TASK_RUNTIME_STATUS" '.status = $status' \
        "$TASK_FILE" > "${TASK_FILE}.tmp" && mv "${TASK_FILE}.tmp" "$TASK_FILE"
    fi
  fi

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

  if [ "$ELAPSED" -ge "$PENDING_WARN_THRESHOLD" ] && [ "$PENDING_WARNED" = false ] && [ "$PENDING" -gt 0 ]; then
    # Pending 也包含已调度、正在拉镜像的 Pod，排队只看未调度的
    UNSCHEDULED=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" -o json 2>/dev/null \
      | jq '[.items[] | select([.status.conditions[]? | select(.type == "PodScheduled" and .status == "True")] | length == 0)] | length' 2>/dev/null || echo 0)
    if [ "${UNSCHEDULED:-0}" -gt 0 ]; then
      QUEUE_REASON=$(kubectl get events -n "$NAMESPACE" --field-selector "reason=FailedScheduling" -o json 2>/dev/null \
        | jq -r --arg job "$JOB_NAME" '
            [.items[] | select(.involvedObject.name | startswith($job))]
            | sort_by(.lastTimestamp // .eventTime // "") | last | .message // empty' 2>/dev/null \
        | tr '\r\n' '  ' | sed 's/ *$//' | cut -c1-300 || true)
      log_warn "PPU queue: ${UNSCHEDULED}/${TOTAL_PODS} pod(s) still waiting for PPU scheduling after $(( ELAPSED / 60 ))m. Reason: ${QUEUE_REASON:-no FailedScheduling event yet}"
      echo "::group::FailedScheduling events"
      kubectl get events -n "$NAMESPACE" \
        --field-selector "reason=FailedScheduling" \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
      echo "::endgroup::"
      PENDING_WARNED=true
    fi
  fi

  echo "  ${ELAPSED}s/${TIMEOUT}s - pending=$PENDING running=$RUNNING succeeded=$SUCCEEDED failed=$FAILED"
  sleep "$POLL_INTERVAL"
done

# 停止日志流
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true

METRICS_END_EPOCH=$(date +%s)
METRICS_END_TIME=$(date +%Y-%m-%dT%H:%M:%S%z)
DURATION=$(( METRICS_END_EPOCH - START_TIME ))
POD_SNAPSHOT=$(kubectl get pods -n "$NAMESPACE" -l "ppu-job=$JOB_NAME" -o json 2>/dev/null || printf '{"items":[]}')

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
    [ "$_pod_queue_seconds" -ge "$PENDING_WARN_THRESHOLD" ] && LONG_QUEUE_PODS=$(( LONG_QUEUE_PODS + 1 ))
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

set_output "job_status" "$FINAL_STATUS"
set_output "duration_seconds" "$DURATION"
set_output "queue_duration_seconds" "$QUEUE_DURATION_SECONDS"
set_output "unscheduled_pods" "$UNSCHEDULED_PODS"
set_output "pod_queue" "$POD_QUEUE"
set_output "queue_reason" "$QUEUE_REASON"
set_output "occupied_ppu_card_hours" "$OCCUPIED_PPU_CARD_HOURS"
set_output "execution_ppu_card_hours" "$EXECUTION_PPU_CARD_HOURS"

PODS=$(printf '%s' "$POD_SNAPSHOT" | jq -r '.items[].metadata.name')
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
  log_info "任务记录已更新终态: ${TASK_FILE}"
fi
