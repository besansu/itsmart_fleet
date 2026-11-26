
#!/command/with-contenv bash
set -eu

CONFIG_PATH=/data/options.json

FLEET_URL=$(jq -r '.fleet_url' "$CONFIG_PATH")
NODE_ID=$(jq -r '.node_id' "$CONFIG_PATH")
NODE_TOKEN=$(jq -r '.node_token' "$CONFIG_PATH")
HEARTBEAT_INTERVAL=$(jq -r '.heartbeat_interval' "$CONFIG_PATH")
REPORT_INTERVAL_HOURS=$(jq -r '.report_interval_hours' "$CONFIG_PATH")

SUP_TOKEN="${SUPERVISOR_TOKEN:-}"

log() {
  echo "[ITsmart Fleet] $1"
}

api_get() {
  curl -fsS \
    -H "Authorization: Bearer $SUP_TOKEN" \
    "http://supervisor/$1"
}

cpu_usage() {
  read -r _ u n s i w irq sirq st _ < /proc/stat
  idle1=$((i + w))
  total1=$((u + n + s + i + w + irq + sirq + st))
  sleep 1
  read -r _ u n s i w irq sirq st _ < /proc/stat
  idle2=$((i + w))
  total2=$((u + n + s + i + w + irq + sirq + st))
  total=$((total2 - total1))
  [ "$total" -gt 0 ] || { echo 0; return; }
  echo $((100 * (total - (idle2 - idle1)) / total))
}

memory_usage() {
  awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {
    if (t>0) printf "%d", (t-a)*100/t; else print 0
  }' /proc/meminfo
}

disk_info() {
  df -Pk /config | awk 'NR==2 {
    printf "{\"percent\":%d,\"used_gb\":%.2f,\"total_gb\":%.2f}",
    $5+0, $3/1048576, $2/1048576
  }'
}

get_versions() {
  if [ -z "$SUP_TOKEN" ]; then
    echo '{"core_version":"unknown","supervisor_version":"unknown","os_version":"unknown"}'
    return
  fi

  info=$(api_get info 2>/dev/null || echo '{}')
  host=$(api_get host/info 2>/dev/null || echo '{}')
  supervisor=$(api_get supervisor/info 2>/dev/null || echo '{}')

  jq -n \
    --arg core "$(echo "$info" | jq -r '.data.version // "unknown"')" \
    --arg supervisor "$(echo "$supervisor" | jq -r '.data.version // "unknown"')" \
    --arg os "$(echo "$host" | jq -r '.data.operating_system // .data.os_version // "unknown"')" \
    '{core_version:$core,supervisor_version:$supervisor,os_version:$os}'
}

send_heartbeat() {
  cpu=$(cpu_usage)
  mem=$(memory_usage)
  disk=$(disk_info)

  payload=$(jq -n \
    --arg id "$NODE_ID" \
    --argjson cpu "$cpu" \
    --argjson mem "$mem" \
    --argjson disk "$disk" \
    '{
      node_id:$id,
      cpu_percent:$cpu,
      memory_percent:$mem,
      disk_percent:$disk.percent,
      disk_used_gb:$disk.used_gb,
      disk_total_gb:$disk.total_gb
    }')

  curl -fsS -X POST "$FLEET_URL/api/v1/heartbeat" \
    -H "Authorization: Bearer $NODE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null

  log "Heartbeat sent: CPU ${cpu}%, RAM ${mem}%, disk $(echo "$disk" | jq -r '.percent')%"
}

send_report() {
  versions=$(get_versions)

  curl -fsS -X POST "$FLEET_URL/api/v1/report" \
    -H "Authorization: Bearer $NODE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$versions" >/dev/null

  log "Version report sent: $versions"
}

log "Agent started. Supervisor token: $([ -n "$SUP_TOKEN" ] && echo YES || echo NO)"

last_report=0
while true; do
  send_heartbeat || log "Heartbeat failed"
  now=$(date +%s)
  interval=$((REPORT_INTERVAL_HOURS * 3600))

  if [ "$last_report" -eq 0 ] || [ $((now - last_report)) -ge "$interval" ]; then
    send_report || log "Version report failed"
    last_report=$now
  fi

  sleep "$HEARTBEAT_INTERVAL"
done
