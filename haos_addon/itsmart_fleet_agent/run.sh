#!/usr/bin/env sh
set -u

OPT=/data/options.json
URL=$(jq -r .fleet_url "$OPT")
ID=$(jq -r .node_id "$OPT")
TOKEN=$(jq -r .node_token "$OPT")
HB=$(jq -r .heartbeat_interval "$OPT")
REP_H=$(jq -r .report_interval_hours "$OPT")

REP_S=$((REP_H * 3600))
LAST_REPORT=0

sup() {
  curl -fsS -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    "http://supervisor/$1" | jq -r "$2"
}

post() {
  curl -fsS -m 15 -X POST "$URL$1" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$2" >/dev/null
}

cpu_pct() {
  read -r _ a b c d e f g _ < /proc/stat
  T1=$((a+b+c+d+e+f+g))
  I1=$((d+e))
  sleep 1
  read -r _ a b c d e f g _ < /proc/stat
  T2=$((a+b+c+d+e+f+g))
  I2=$((d+e))
  DT=$((T2-T1))
  [ "$DT" -gt 0 ] && echo $((100*(DT-(I2-I1))/DT)) || echo null
}

mem_pct() {
  awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}
    END{if(t>0)printf "%d",(t-a)*100/t; else print "null"}' /proc/meminfo
}

disk_pct() {
  curl -fsS -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    http://supervisor/host/info |
    jq -r 'if .data.disk_total > 0 then
      ((.data.disk_used / .data.disk_total * 100) | floor)
      else null end' 2>/dev/null || echo null
}

metrics() {
  jq -n --arg id "$ID" \
    --argjson c "$(cpu_pct)" \
    --argjson m "$(mem_pct)" \
    --argjson d "$(disk_pct)" \
    '{node_id:$id,cpu_percent:$c,memory_percent:$m,disk_percent:$d}'
}

echo "ITsmart Fleet Agent started: node=$ID"

while true; do
  NOW=$(date +%s)

  if [ $((NOW - LAST_REPORT)) -ge "$REP_S" ]; then
    BODY=$(jq -n --arg id "$ID" \
      --arg c "$(sup core/info .data.version)" \
      --arg s "$(sup supervisor/info .data.version)" \
      --arg o "$(sup os/info .data.version)" \
      '{node_id:$id,core_version:$c,supervisor_version:$s,os_version:$o}')

    if post /api/v1/report "$BODY"; then
      LAST_REPORT=$NOW
      echo "Version report sent"
    else
      echo "Version report failed; will retry"
    fi
  fi

  if post /api/v1/heartbeat "$(metrics)"; then
    echo "Heartbeat sent"
  else
    echo "Heartbeat failed"
  fi

  sleep "$HB"
done