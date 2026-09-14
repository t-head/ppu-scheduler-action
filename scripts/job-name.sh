#!/usr/bin/env bash
# 输出本 job 的资源名：可读前缀 + 6 位 hash，hash 永远保留在末尾不被截断。
# runner.name 在同一时刻只对应一个 job，用于区分 job id 与 matrix 都相同的不同 reusable workflow。
set -uo pipefail

sanitize_name() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/^-*//; s/-*$//'
}

_owner=$(sanitize_name "${GITHUB_REPOSITORY_OWNER:-unknown}" | cut -c1-20 | sed 's/-*$//')
_matrix="${MATRIX_JSON:-}"
[ "$_matrix" = "null" ] && _matrix=""

if [ -n "${INPUT_JOB_SUFFIX:-}" ]; then
  _readable=$(sanitize_name "$INPUT_JOB_SUFFIX")
else
  _readable=$(sanitize_name "${GITHUB_JOB_NAME:-job}" | cut -c1-20 | sed 's/-*$//')
  if [ -n "$_matrix" ]; then
    _first=$(printf '%s' "$_matrix" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    vals = [str(v) for v in d.values() if v is not None and str(v).strip()] if isinstance(d, dict) else []
    print(vals[0] if vals else '')
except Exception:
    print('')
" 2>/dev/null || true)
    _first=$(sanitize_name "$_first" | cut -c1-8 | sed 's/-*$//')
    [ -n "$_first" ] && _readable="${_readable}-${_first}"
  fi
fi

_hash=$(printf '%s\n%s\n%s\n%s' "${PPU_RUNNER_NAME:-}" "${GITHUB_JOB_NAME:-}" "${INPUT_JOB_SUFFIX:-}" "$_matrix" \
  | md5sum | cut -c1-6)

# 52 = 63(hostname 上限) - "-worker-NN" 预留；前缀截到 45，再拼 "-" + 6 位 hash
_prefix=$(echo "ppu-${_owner}-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}-${_readable}" | cut -c1-45 | sed 's/-*$//')
echo "${_prefix}-${_hash}"
