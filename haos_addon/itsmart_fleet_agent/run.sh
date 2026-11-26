#!/usr/bin/env sh
set -u

OPT=/data/options.json
URL=$(jq -r '.fleet_url' "$OPT")
ID=$(jq -r '.node_id' "$OPT")
TOKEN=$(jq -r '.node_token' "$OPT")
HB=$(jq -r '.heartbeat_interval' "$OPT")
REP_H=$(jq -r '.report_interval_hours' "$OPT")

SUP_TOKEN="${SUPERVISOR_TOKEN:-}"
REP_S=$((REP_H * 3600))
LAST_REPORT=0

sup() {
  if [ -z "$SUP_TOKEN" ]; then
    echo "unknown"
    return
  fi

  curl -fsS -H "Authorization: Bearer $SUP_TOKEN" \
    "http://supervisor/$1" 2>/dev/null |
    jq -r "$2 // \"unknown\"" 2>/dev/null || echo "unknown"
}

post() {
  curl -fsS -m 15 -X POST "$URL$1" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$2" >/dev/null
}

cpu_pct() {
  read -r _ a b c d e f g h _ < /proc/stat
  T1=$((a+b+c+d+e+f+g+h))
  I1=$((d+e))
  sleep 1
  read -r _ a b c d e f g h _ < /proc/stat
  T2=$((a+b+c+d+e+f+g+h))
  I2=$((d+e))
  DT=$((T2-T1))
  if [ "$DT" -gt 0 ]; then
    echo $((100*(DT-(I2-I1))/DT))
  else
    echo null
  fi
}

mem_pct() {
  awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}
    END {
      if (t>0) printf "%d",(t-a)*100/t;
      else print "null"
    }' /proc/meminfo
}

disk_pct() {
  if [ -z "$SUP_TOKEN" ]; then
    echo null
    return
  fi

  RESPONSE=$(curl -fsS -H "Authorization: Bearer $SUP_TOKEN" \
    http://supervisor/host/info 2>/dev/null) || {
      echo null
      return
    }

  echo "$RESPONSE" | jq -r '
    if (.data.disk_total // 0) > 0 then
      ((.data.disk_used / .data.disk_total * 100) | floor)
    else null end
  ' 2>/dev/null || echo null
}

metrics() {
  C=$(cpu_pct)
  M=$(mem_pct)
  D=$(disk_pct)

  jq -n \
    --arg id "$ID" \
    --arg c "$C" \
    --arg m "$M" \
    --arg d "$D" \
    '{
      node_id: $id,
      cpu_percent: (try ($c | tonumber) catch null),
      memory_percent: (try ($m | tonumber) catch null),
      disk_percent: (try ($d | tonumber) catch null)
    }'
}

echo "ITsmart Fleet Agent started: node=$ID"

if [ -z "$SUP_TOKEN" ]; then
  echo "WARNING: Supervisor token unavailable; disk and version reporting limited"
fi

while true; do
  NOW=$(date +%s)

  if [ $((NOW - LAST_REPORT)) -ge "$REP_S" ]; then
    BODY=$(jq -n \
      --arg id "$ID" \
      --arg c "$(sup core/info .data.version)" \
      --arg s "$(sup supervisor/info .data.version)" \
      --arg o "$(sup os/info .data.version)" \
      '{
        node_id: $id,
        core_version: $c,
        supervisor_version: $s,
        os_version: $o
      }')

    if post /api/v1/report "$BODY"; then
      LAST_REPORT=$NOW
      echo "Version report sent"
    else
      echo "Version report failed; will retry"
    fi
  fi

  BODY=$(metrics)
  echo "Heartbeat payload: $BODY"

  if post /api/v1/heartbeat "$BODY"; then
    echo "Heartbeat sent"
  else
    echo "Heartbeat failed"
  fi

  sleep "$HB"
done