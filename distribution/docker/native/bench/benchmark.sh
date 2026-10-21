#!/bin/bash

#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

# Exercises a Druid image with the cluster in docker-compose.yml and measures memory, start-up time and query
# latency. Run it once per image and compare the reports:
#
#   benchmark.sh druid:jvm-baseline jvm
#   benchmark.sh druid:native native
#
# The workload: batch-ingest the quickstart Wikipedia sample on the middleManager and the indexer, stream the same
# rows through Kafka, run a set of SQL queries repeatedly, and read the system tables. Memory is sampled from the
# container cgroups (docker stats) and from the resident set of each process. The report is written to
# <output-dir>/<label>.md (default output dir: /tmp/druid-bench).

set -euo pipefail

IMAGE="$1"
LABEL="$2"
OUTPUT_DIR="${3:-/tmp/druid-bench}"
ITERATIONS="${BENCH_QUERY_ITERATIONS:-15}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_FILE="$HERE/../../../../examples/quickstart/tutorial/wikiticker-2015-09-12-sampled.json.gz"
PROJECT="druid-$LABEL"
COMPOSE=(docker compose -p "$PROJECT" --project-directory "$HERE" -f "$HERE/docker-compose.yml")
COORDINATOR=http://localhost:18081
BROKER=http://localhost:18082
ROUTER=http://localhost:18888
SERVICES=(coordinator broker historical middlemanager indexer router)
HEALTH_URLS=("$COORDINATOR" "$BROKER" http://localhost:18083 http://localhost:18091 http://localhost:18092 "$ROUTER")

mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/$LABEL.md"
LOG="$OUTPUT_DIR/$LABEL.log"
: > "$REPORT"
: > "$LOG"
FAILURES=0

log() {
  echo "$(date -u +%H:%M:%S) $*" | tee -a "$LOG" >&2
}

# Records a failed check. The run continues so that the report is complete, but the script exits non-zero.
fail() {
  FAILURES=$((FAILURES + 1))
  log "FAILURE: $*"
}

report() {
  echo "$*" >> "$REPORT"
}

now_ms() {
  date +%s%3N
}

cleanup() {
  log "collecting container logs into $OUTPUT_DIR/$LABEL-logs"
  mkdir -p "$OUTPUT_DIR/$LABEL-logs"
  for service in "${SERVICES[@]}"; do
    "${COMPOSE[@]}" logs --no-color "$service" > "$OUTPUT_DIR/$LABEL-logs/$service.log" 2>&1 || true
  done
  "${COMPOSE[@]}" down -v --remove-orphans > /dev/null 2>&1 || true
}
trap cleanup EXIT

# --------------------------------------------------------------------------------------------------------------------
# Measurements
# --------------------------------------------------------------------------------------------------------------------

container_id() {
  "${COMPOSE[@]}" ps -q "$1"
}

# Memory of a container as docker reports it (cgroup usage without inactive page cache), in MiB.
container_memory_mib() {
  local id
  id="$(container_id "$1")"
  docker stats --no-stream --format '{{.MemUsage}}' "$id" | awk '{
    v = $1; unit = v; gsub(/[0-9.]/, "", unit); gsub(/[^0-9.]/, "", v);
    if (unit == "GiB") v *= 1024; else if (unit == "KiB") v /= 1024; else if (unit == "B") v /= 1048576;
    printf "%.0f", v }'
}

# Resident set size of every process in a container, "name:rssMiB" pairs, largest first.
process_rss() {
  "${COMPOSE[@]}" exec -T "$1" sh -c 'for s in /proc/[0-9]*/status; do n=$(sed -n "s/^Name:\t//p" $s); r=$(sed -n "s/^VmRSS:[ \t]*\([0-9]*\) kB/\1/p" $s); [ -n "$r" ] && echo "$n:$((r/1024))"; done' 2>/dev/null \
    | sort -t: -k2 -n -r | paste -sd ' ' -
}

snapshot_memory() {
  local phase="$1"
  report ""
  report "### Memory: $phase"
  report ""
  report "| Container | cgroup memory (MiB) | Process RSS (MiB) |"
  report "|---|---:|---|"
  for service in "${SERVICES[@]}"; do
    report "| $service | $(container_memory_mib "$service") | $(process_rss "$service") |"
  done
}

sql() {
  curl -sS -X POST -H 'Content-Type: application/json' --data-binary "$(printf '{"query":%s}' "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")" "$BROKER/druid/v2/sql"
}

sql_timed() {
  # prints seconds taken; output discarded; non-2xx reported as "error"
  local body code
  body="$(printf '{"query":%s}' "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")"
  curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' --data-binary "$body" -w '%{time_total} %{http_code}\n' "$BROKER/druid/v2/sql" || echo "0 000"
}

wait_task() {
  local task_id="$1" status=""
  for _ in $(seq 1 900); do
    status="$(curl -s "$COORDINATOR/druid/indexer/v1/task/$task_id/status" | sed -n 's/.*"statusCode":"\([A-Z]*\)".*/\1/p')"
    case "$status" in
      SUCCESS|FAILED) echo "$status"; return ;;
    esac
    sleep 1
  done
  echo "TIMEOUT"
}

batch_spec() {
  cat <<SPEC
{
  "type": "index_parallel",
  "spec": {
    "ioConfig": {
      "type": "index_parallel",
      "inputSource": {"type": "local", "baseDir": "/opt/data", "filter": "wikiticker-2015-09-12-sampled.json.gz"},
      "inputFormat": {"type": "json"}
    },
    "tuningConfig": {"type": "index_parallel", "partitionsSpec": {"type": "dynamic", "maxRowsPerSegment": 50000}, "maxNumConcurrentSubTasks": 1},
    "dataSchema": {
      "dataSource": "$1",
      "timestampSpec": {"column": "time", "format": "iso"},
      "dimensionsSpec": {"useSchemaDiscovery": true},
      "granularitySpec": {"queryGranularity": "none", "rollup": false, "segmentGranularity": "day"}
    }
  }
}
SPEC
}

# --------------------------------------------------------------------------------------------------------------------
# Start
# --------------------------------------------------------------------------------------------------------------------

report "# Druid image benchmark: \`$IMAGE\` ($LABEL)"
report ""
report "Image size: $(docker image inspect --format '{{.Size}}' "$IMAGE" | awk '{printf "%.0f MiB", $1/1048576}')"
report ""

log "starting cluster from $IMAGE"
export DRUID_IMAGE="$IMAGE"
export DRUID_DATA_DIR="$(dirname "$DATA_FILE")"
"${COMPOSE[@]}" up -d --quiet-pull >> "$LOG" 2>&1
START_MS="$(now_ms)"

report "## Start-up"
report ""
report "| Service | Time to healthy (s) |"
report "|---|---:|"
declare -A HEALTHY_AT
pending=("${!SERVICES[@]}")
deadline=$(( $(date +%s) + 600 ))
while [ "${#pending[@]}" -gt 0 ] && [ "$(date +%s)" -lt "$deadline" ]; do
  still=()
  for i in "${pending[@]}"; do
    if [ "$(curl -s --max-time 2 "${HEALTH_URLS[$i]}/status/health" 2>/dev/null)" = "true" ]; then
      HEALTHY_AT[${SERVICES[$i]}]=$(( ($(now_ms) - START_MS) ))
      log "${SERVICES[$i]} healthy after ${HEALTHY_AT[${SERVICES[$i]}]} ms"
    else
      still+=("$i")
    fi
  done
  pending=("${still[@]+"${still[@]}"}")
  sleep 1
done
if [ "${#pending[@]}" -gt 0 ]; then
  for i in "${pending[@]}"; do
    log "ERROR: ${SERVICES[$i]} did not become healthy"
    "${COMPOSE[@]}" logs --no-color --tail 40 "${SERVICES[$i]}" >&2 || true
  done
  exit 1
fi
for service in "${SERVICES[@]}"; do
  report "| $service | $(awk "BEGIN {printf \"%.1f\", ${HEALTHY_AT[$service]}/1000}") |"
done

# Give the services a minute to settle (leader election, segment polling, lookup sync) before the idle snapshot.
sleep 60
snapshot_memory "idle after start-up"

# --------------------------------------------------------------------------------------------------------------------
# Batch ingestion on the middleManager and the indexer
# --------------------------------------------------------------------------------------------------------------------

report ""
report "## Batch ingestion (Wikipedia sample, $(zcat "$DATA_FILE" | wc -l) rows)"
report ""
INGEST_START="$(now_ms)"
task_a="$(curl -sS -X POST -H 'Content-Type: application/json' --data-binary "$(batch_spec wikipedia)" "$COORDINATOR/druid/indexer/v1/task" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')"
task_b="$(curl -sS -X POST -H 'Content-Type: application/json' --data-binary "$(batch_spec wikipedia_b)" "$COORDINATOR/druid/indexer/v1/task" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')"
log "submitted batch tasks $task_a and $task_b"
sleep 20
snapshot_memory "during batch ingestion"
report ""
report "| Task | Result | Duration (s) |"
report "|---|---|---:|"
for task in "$task_a" "$task_b"; do
  result="$(wait_task "$task")"
  report "| $task | $result | $(awk "BEGIN {printf \"%.0f\", ($(now_ms) - $INGEST_START)/1000}") |"
  log "task $task finished with $result"
  [ "$result" = SUCCESS ] || fail "batch task $task finished with $result"
done

for _ in $(seq 1 300); do
  loadstatus="$(curl -s "$COORDINATOR/druid/coordinator/v1/loadstatus")"
  if echo "$loadstatus" | grep -q '"wikipedia":100' && echo "$loadstatus" | grep -q '"wikipedia_b":100'; then
    break
  fi
  sleep 1
done
log "segments loaded"

# --------------------------------------------------------------------------------------------------------------------
# Streaming ingestion from Kafka
# --------------------------------------------------------------------------------------------------------------------

report ""
report "## Kafka ingestion"
report ""
"${COMPOSE[@]}" exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --topic wikipedia --partitions 1 --replication-factor 1 >> "$LOG" 2>&1 || true
curl -sS -X POST -H 'Content-Type: application/json' --data-binary '{
  "type": "kafka",
  "spec": {
    "dataSchema": {
      "dataSource": "wikipedia_kafka",
      "timestampSpec": {"column": "time", "format": "iso"},
      "dimensionsSpec": {"useSchemaDiscovery": true},
      "granularitySpec": {"type": "uniform", "segmentGranularity": "DAY", "queryGranularity": "NONE", "rollup": false}
    },
    "ioConfig": {
      "topic": "wikipedia",
      "inputFormat": {"type": "json"},
      "consumerProperties": {"bootstrap.servers": "kafka:9092"},
      "taskCount": 1, "replicas": 1, "taskDuration": "PT3M", "useEarliestOffset": true
    },
    "tuningConfig": {"type": "kafka", "maxRowsPerSegment": 50000, "maxRowsInMemory": 20000}
  }
}' "$COORDINATOR/druid/indexer/v1/supervisor" >> "$LOG" 2>&1
KAFKA_START="$(now_ms)"
zcat "$DATA_FILE" | "${COMPOSE[@]}" exec -T kafka /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic wikipedia >> "$LOG" 2>&1
expected="$(zcat "$DATA_FILE" | wc -l)"
kafka_rows=0
for _ in $(seq 1 300); do
  kafka_rows="$(sql "SELECT COUNT(*) AS c FROM wikipedia_kafka" 2>/dev/null | sed -n 's/.*"c":\([0-9]*\).*/\1/p')"
  if [ "${kafka_rows:-0}" -ge "$expected" ]; then
    break
  fi
  sleep 2
done
report "Rows visible through the broker after $(awk "BEGIN {printf \"%.0f\", ($(now_ms) - $KAFKA_START)/1000}") s: ${kafka_rows:-0} of $expected"
[ "${kafka_rows:-0}" -ge "$expected" ] || fail "kafka ingestion: ${kafka_rows:-0} of $expected rows visible"
snapshot_memory "during Kafka ingestion"
curl -sS -X POST "$COORDINATOR/druid/indexer/v1/supervisor/wikipedia_kafka/suspend" >> "$LOG" 2>&1
log "kafka supervisor suspended; waiting for the task to publish"
for _ in $(seq 1 300); do
  if ! curl -s "$COORDINATOR/druid/indexer/v1/runningTasks" | grep -q index_kafka; then
    break
  fi
  sleep 2
done
curl -sS -X POST "$COORDINATOR/druid/indexer/v1/supervisor/wikipedia_kafka/terminate" >> "$LOG" 2>&1

# --------------------------------------------------------------------------------------------------------------------
# Queries
# --------------------------------------------------------------------------------------------------------------------

QUERIES=(
  "SELECT COUNT(*) FROM wikipedia"
  "SELECT channel, COUNT(*) AS cnt, SUM(added) AS added FROM wikipedia GROUP BY channel ORDER BY cnt DESC LIMIT 10"
  "SELECT TIME_FLOOR(__time, 'PT1H') AS t, COUNT(DISTINCT \"user\") AS users, SUM(delta) AS delta FROM wikipedia GROUP BY 1 ORDER BY 1"
  "SELECT page, SUM(delta) AS delta FROM wikipedia WHERE countryName = 'United States' AND isRobot = 'false' GROUP BY page ORDER BY delta DESC LIMIT 20"
  "SELECT APPROX_COUNT_DISTINCT_DS_THETA(\"user\") AS users, APPROX_QUANTILE_DS(added, 0.95) AS p95, VARIANCE(added) AS var FROM wikipedia WHERE channel LIKE '#en%'"
  "SELECT __time, page, \"user\", added FROM wikipedia WHERE comment LIKE '%bot%' ORDER BY __time DESC LIMIT 50"
  "SELECT w.channel, COUNT(*) AS cnt FROM wikipedia w JOIN (SELECT channel FROM wikipedia_b GROUP BY channel HAVING COUNT(*) > 500) c ON w.channel = c.channel GROUP BY w.channel ORDER BY cnt DESC"
  "SELECT COUNT(*) FROM wikipedia_kafka WHERE isAnonymous = 'true'"
  "SELECT server, server_type, curr_size FROM sys.servers WHERE server_type <> 'peon' ORDER BY server"
  "SELECT datasource, COUNT(*) AS segments, SUM(\"size\") AS bytes FROM sys.segments WHERE is_published = 1 GROUP BY datasource ORDER BY datasource"
  "SELECT TABLE_NAME, COUNT(*) AS columns FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'druid' GROUP BY TABLE_NAME ORDER BY TABLE_NAME"
)

report ""
report "## Queries ($ITERATIONS iterations each, after one warm-up)"
report ""
report "| Query | Result | Median (ms) | Mean (ms) | Max (ms) |"
report "|---|---|---:|---:|---:|"
for query in "${QUERIES[@]}"; do
  sql_timed "$query" > /dev/null || true
  times=()
  codes=""
  for _ in $(seq 1 "$ITERATIONS"); do
    read -r t code < <(sql_timed "$query")
    times+=("$t")
    codes="$codes $code"
  done
  stats="$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1*1000; s+=$1*1000} END {m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; printf "%.0f | %.0f | %.0f", m, s/NR, a[NR]}')"
  if echo "$codes" | grep -q -v -E '^( 200)+$'; then
    result="HTTP$(echo "$codes" | tr ' ' '\n' | sort -u | paste -sd '/' -)"
    fail "query returned $result: ${query:0:90}"
  else
    result="ok"
  fi
  report "| \`${query:0:90}\` | $result | $stats |"
  log "query [$result] ${query:0:70}"
done
snapshot_memory "after queries"

# --------------------------------------------------------------------------------------------------------------------
# Web console and system APIs through the router
# --------------------------------------------------------------------------------------------------------------------

report ""
report "## Router and console"
report ""
report "| Request | HTTP status |"
report "|---|---|"
check_router() {
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' "$ROUTER$1")"
  report "| \`$1\` | $status |"
  [ "$status" = 200 ] || fail "router request $1 returned HTTP $status"
}
for path in /status/health /unified-console.html /console-config.js /druid/router/v1/brokers /proxy/coordinator/druid/coordinator/v1/datasources /proxy/overlord/druid/indexer/v1/completeTasks; do
  check_router "$path"
done
asset="$(curl -s "$ROUTER/unified-console.html" | grep -o 'public/web-console-[^"]*\.js' | head -1)"
if [ -n "$asset" ]; then
  check_router "/$asset"
else
  fail "the console page does not reference a web-console asset"
fi
sql_result="$(sql "SELECT COUNT(*) AS c FROM sys.tasks WHERE status = 'SUCCESS'" || true)"
report "| sys.tasks via SQL | ${sql_result:0:120} |"
echo "$sql_result" | grep -q '"c":' || fail "sys.tasks query failed: ${sql_result:0:200}"

report ""
if [ "$FAILURES" -gt 0 ]; then
  report "**$FAILURES check(s) failed**; see \`$LOG\`."
  log "benchmark finished with $FAILURES failed check(s); report at $REPORT"
  exit 1
fi
report "All checks passed."
log "benchmark finished; report at $REPORT"
