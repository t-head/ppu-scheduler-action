#!/usr/bin/env bash
# Periodic etcd maintenance: defrag when fragmented, emergency compact + defrag + disarm on NOSPACE.
set -euo pipefail

exec 9>/run/etcd-defrag.lock
flock -n 9 || { echo "another run in progress, skip"; exit 0; }

ETCDCTL="${ETCDCTL:-/usr/local/bin/etcdctl}"
PKI=/etc/kubernetes/pki/etcd
MIN_DB_BYTES="${MIN_DB_BYTES:-268435456}"       # skip routine defrag below 256MiB
FRAG_PERCENT="${FRAG_PERCENT:-50}"               # defrag when free pages >= 50% of file
EMERGENCY_INUSE_PERCENT="${EMERGENCY_INUSE_PERCENT:-80}"

ctl() {
  "$ETCDCTL" --endpoints=https://127.0.0.1:2379 \
    --cacert="$PKI/ca.crt" --cert="$PKI/server.crt" --key="$PKI/server.key" \
    --command-timeout=180s "$@"
}

field() { grep -o "\"$1\":[0-9]*" <<<"$2" | head -1 | cut -d: -f2; }

mib() { echo "$(( $1 / 1048576 ))MiB"; }

status="$(ctl endpoint status -w json)"
db=$(field dbSize "$status")
inuse=$(field dbSizeInUse "$status")
quota=$(field dbSizeQuota "$status")
rev=$(field revision "$status")
frag=$(( (db - inuse) * 100 / db ))
alarms="$(ctl alarm list || true)"

echo "db=$(mib "$db") inuse=$(mib "$inuse") quota=$(mib "$quota") frag=${frag}% rev=$rev alarms=[${alarms//$'\n'/ }]"

emergency=0
if grep -q NOSPACE <<<"$alarms" || (( inuse * 100 >= quota * EMERGENCY_INUSE_PERCENT )); then
  emergency=1
fi

if (( emergency )); then
  echo "EMERGENCY: compacting to current revision $rev"
  ctl compaction "$rev" --physical || echo "compact failed (may already be compacted)"
elif (( db < MIN_DB_BYTES || frag < FRAG_PERCENT )); then
  exit 0
fi

echo "defragmenting"
ctl defrag
if grep -q NOSPACE <<<"$alarms"; then
  echo "disarming NOSPACE alarm"
  ctl alarm disarm
fi

status="$(ctl endpoint status -w json)"
echo "after: db=$(mib "$(field dbSize "$status")") inuse=$(mib "$(field dbSizeInUse "$status")")"
