#!/usr/bin/env bash
set -uo pipefail

[ -n "${JOB_NAME:-}" ] || { echo "未获取到 job_name，跳过 dmesg 打印"; exit 0; }
DMESG_DIR="/wl_nas/devops/dmesg/${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}/${JOB_NAME}"

files=$(ls -1 "$DMESG_DIR" 2>/dev/null | grep -E '^worker-[0-9]+-.*\.log$' | sort -t- -k2,2n)
if [ -z "$files" ]; then
  echo "未找到 dmesg 日志: ${DMESG_DIR}"
  exit 0
fi

echo "dmesg 日志 NAS 路径: ${DMESG_DIR}"
while IFS= read -r f; do echo "  ${DMESG_DIR}/${f}"; done <<< "$files"

# 内核日志含进程名等外部内容，屏蔽其中的 workflow 命令
token="dmesg-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
while IFS= read -r f; do
  rank=${f#worker-}; node=${rank#*-}; rank=${rank%%-*}; node=${node%.log}
  echo "::group::dmesg worker-${rank} (${node})"
  echo "::stop-commands::${token}"
  awk 1 "${DMESG_DIR}/${f}"
  echo "::${token}::"
  echo "::endgroup::"
done <<< "$files"
