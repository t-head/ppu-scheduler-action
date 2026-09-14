# 锚点法避免 --since 的时钟换算和重复时间戳造成漏记。
_ppu_dmesg_awk='
function fmt(e,   d, s, z, era, doe, yoe, y, doy, mp, dd, m) {
  e = int(e) + 28800
  d = int(e / 86400); s = e - d * 86400
  z = d + 719468; era = int(z / 146097); doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400
  doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153)
  dd = doy - int((153 * mp + 2) / 5) + 1
  m = (mp < 10) ? mp + 3 : mp - 9
  if (m <= 2) y++
  return sprintf("%04d-%02d-%02d %02d:%02d:%02d", y, m, dd, int(s / 3600), int((s % 3600) / 60), s % 60)
}
function emit(s) {
  if (match(s, /^\[ *[0-9]+\.[0-9]+\]/))
    printf "[%s] %s\n", fmt(BOOT + substr(s, 2, RLENGTH - 2)), s >> OUT
  else
    print s >> OUT
}
BEGIN {
  have = 0
  if ((getline anchor < STATE) > 0) { have = 1; if ((getline skip < STATE) <= 0) skip = 0 }
  close(STATE)
}
{
  line[NR] = $0
  if ($0 ~ /^\[ *[0-9]+\.[0-9]+\]/) last_ts = NR
  if (have && $0 == anchor) pos = NR
}
END {
  if (INIT == 1) start = NR + 1
  else if (pos) start = pos + 1 + skip
  else {
    print "[ppu-action] 内核日志缓冲区已回绕或锚点丢失，此处之前可能有日志丢失" >> OUT
    start = 1
  }
  for (i = start; i <= NR; i++) emit(line[i])
  if (last_ts) { print line[last_ts] > STATE; print NR - last_ts > STATE }
}
'

_ppu_dmesg_poll() {
  dmesg > "$_ppu_dmesg_snap" 2>/dev/null || return 1
  awk -v STATE="$_ppu_dmesg_state" -v OUT="$_ppu_dmesg_file" -v BOOT="$_ppu_dmesg_boot" \
    -v INIT="${1:-0}" "$_ppu_dmesg_awk" "$_ppu_dmesg_snap" 2>/dev/null || true
}

_ppu_dmesg_begin() {
  if ! command -v dmesg >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
    echo "[ppu-action] 镜像内缺少 dmesg 或 awk，跳过 dmesg 采集" >&2
    return 0
  fi
  _ppu_dmesg_file="${PPU_DMESG_DIR}/worker-${NODE_RANK:-0}-${NODE_NAME:-unknown}.log"
  _ppu_dmesg_snap="${TMPDIR:-/tmp}/.ppu-dmesg-snap.$$"
  _ppu_dmesg_state="${TMPDIR:-/tmp}/.ppu-dmesg-state.$$"
  local _up
  read -r _up _ < /proc/uptime
  _ppu_dmesg_boot=$(awk -v now="$(date +%s)" -v up="$_up" 'BEGIN { printf "%.6f", now - up }')
  mkdir -p "$PPU_DMESG_DIR" 2>/dev/null
  if ! echo "# ppu-action dmesg pod=${HOSTNAME:-} node=${NODE_NAME:-} rank=${NODE_RANK:-0} start_uptime=${_up} 时间按 UTC+8 换算" > "$_ppu_dmesg_file" 2>/dev/null; then
    echo "[ppu-action] 无法写入 ${_ppu_dmesg_file}，跳过 dmesg 采集" >&2
    return 0
  fi
  if ! _ppu_dmesg_poll 1; then
    echo "[ppu-action] 当前容器无权读取 dmesg，跳过 dmesg 采集" >&2
    rm -f "$_ppu_dmesg_file" "$_ppu_dmesg_snap" "$_ppu_dmesg_state"
    return 0
  fi
  (
    _ppu_stop=0
    trap '_ppu_stop=1' TERM
    while :; do
      sleep 5 & wait $!
      _ppu_dmesg_poll || true
      [ "$_ppu_stop" = 1 ] && break
    done
  ) &
  _ppu_dmesg_pid=$!
  echo "[ppu-action] dmesg 采集已启动 → ${_ppu_dmesg_file}"
}

_ppu_dmesg_end() {
  [ -n "${_ppu_dmesg_pid:-}" ] || return 0
  kill -TERM "$_ppu_dmesg_pid" 2>/dev/null
  wait "$_ppu_dmesg_pid" 2>/dev/null
  echo "# ppu-action dmesg 采集结束 exit_code=$1" >> "$_ppu_dmesg_file" 2>/dev/null
  rm -f "$_ppu_dmesg_snap" "$_ppu_dmesg_state"
}
