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

# Records reachability metadata for the native image by running a complete Druid cluster on a JVM with the GraalVM
# tracing agent attached, then driving it through ingestion, queries, lookups, supervisors and coordination APIs.
#
#   trace.sh <druid-home> <lib-dir> <output-dir>
#
# <druid-home> is the extracted distribution (used for bin/run-java, which the middleManager uses to fork peons),
# <lib-dir> the flat class path assembled by NativeImageBuildTool collect, and <output-dir> receives one directory
# of agent output per service (coordinator, broker, ...), ready for -H:ConfigurationFileDirectories.
#
# Every service runs with all compiled-in extensions loaded through the class path, exactly like the native image,
# so the recording also verifies that the extensions coexist. The cluster uses ZooKeeper (started from the ZooKeeper
# jar on the class path) and Derby, and basic-security authentication so that code path is recorded too.

set -euo pipefail

DRUID_HOME="$1"
LIB_DIR="$2"
OUTPUT_DIR="$3"

WORK="${TRACE_WORK_DIR:-/tmp/druid-trace}"
CONF="$WORK/conf"
LOGS="$WORK/logs"
VAR="$WORK/var"
AUTH="admin:password1"
STARTUP_TIMEOUT="${TRACE_STARTUP_TIMEOUT:-600}"
TASK_TIMEOUT="${TRACE_TASK_TIMEOUT:-600}"
# Set TRACE_AGENT=0 to run the same cluster and workload without the agent, to debug the workload itself.
TRACE_AGENT="${TRACE_AGENT:-1}"
CURL=(curl -sS --max-time 120 -u "$AUTH")

COORDINATOR=http://localhost:8081
BROKER=http://localhost:8082
HISTORICAL=http://localhost:8083
MIDDLE_MANAGER=http://localhost:8091
INDEXER=http://localhost:8092
ROUTER=http://localhost:8888

rm -rf "$WORK"
mkdir -p "$CONF/_common" "$LOGS" "$VAR" "$OUTPUT_DIR"
for service in coordinator broker historical middleManager indexer router peon; do
  mkdir -p "$OUTPUT_DIR/$service"
done

declare -a PIDS=()
ZK_PID=""
declare -a FAILED_STEPS=()
declare -a PASSED_STEPS=()

log() {
  echo "$(date -u +%H:%M:%S) trace: $*" >&2
}

step_ok() {
  PASSED_STEPS+=("$1")
  log "ok   $1"
}

step_failed() {
  FAILED_STEPS+=("$1")
  log "FAIL $1${2:+: $2}"
}

stop_cluster() {
  # Services first, so that they can unannounce themselves; ZooKeeper last.
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  # The agent writes its metadata while the JVM shuts down, so give each service time to exit on its own.
  for pid in "${PIDS[@]}"; do
    for _ in $(seq 1 120); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      log "process $pid did not stop within 120 s; killing it (its trace may be incomplete)"
      kill -9 "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  done
  PIDS=()
  if [ -n "$ZK_PID" ]; then
    kill "$ZK_PID" 2>/dev/null || true
    wait "$ZK_PID" 2>/dev/null || true
    ZK_PID=""
  fi
}

cleanup() {
  log "stopping services"
  stop_cluster
}
trap cleanup EXIT

# --------------------------------------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------------------------------------

cat > "$CONF/_common/common.runtime.properties" <<PROPS
# Every extension is on the class path; nothing is loaded from the extensions directory.
druid.extensions.loadList=[]
druid.extensions.directory=$WORK/no-extensions
druid.startup.logging.logProperties=true

druid.zk.service.host=localhost
druid.zk.paths.base=/druid

druid.metadata.storage.type=derby
druid.metadata.storage.connector.connectURI=jdbc:derby://localhost:1527/$VAR/metadata.db;create=true
druid.metadata.storage.connector.host=localhost
druid.metadata.storage.connector.port=1527

druid.storage.type=local
druid.storage.storageDirectory=$VAR/segments
druid.indexer.logs.type=file
druid.indexer.logs.directory=$VAR/indexing-logs

druid.selectors.indexing.serviceName=druid/overlord
druid.selectors.coordinator.serviceName=druid/coordinator

druid.monitoring.monitors=["org.apache.druid.java.util.metrics.JvmMonitor","org.apache.druid.server.metrics.ServiceStatusMonitor"]
druid.monitoring.emissionPeriod=PT10S
druid.emitter=composing
druid.emitter.composing.emitters=["logging","prometheus"]
druid.emitter.logging.logLevel=debug
druid.emitter.prometheus.strategy=exporter
druid.emitter.prometheus.addHostAsLabel=true

druid.indexing.doubleStorage=double
druid.sql.enable=true
druid.sql.planner.useGroupingSetForExactDistinct=true
druid.server.http.numThreads=12
druid.processing.buffer.sizeBytes=25000000
druid.processing.numMergeBuffers=2
druid.processing.numThreads=1
druid.processing.tmpDir=$VAR/processing

druid.auth.authenticatorChain=["basic"]
druid.auth.authenticator.basic.type=basic
druid.auth.authenticator.basic.initialAdminPassword=password1
druid.auth.authenticator.basic.initialInternalClientPassword=password2
druid.auth.authenticator.basic.credentialsValidator.type=metadata
druid.auth.authenticator.basic.skipOnFailure=false
druid.auth.authenticator.basic.authorizerName=basic
druid.escalator.type=basic
druid.escalator.internalClientUsername=druid_system
druid.escalator.internalClientPassword=password2
druid.escalator.authorizerName=basic
druid.auth.authorizers=["basic"]
druid.auth.authorizer.basic.type=basic

druid.lookup.lookupTier=__default
PROPS

# Logs go to the console through the same routing appender as the distribution's log4j2.xml, so that the indexer's
# per-task log files and the lookups behind them are exercised under the agent.
cat > "$CONF/_common/log4j2.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" ?>
<Configuration status="WARN">
  <Appenders>
    <Console name="Console" target="SYSTEM_OUT">
      <PatternLayout pattern="%d{ISO8601} %p [%t] %c -%notEmpty{ [%markerSimpleName]} %m%n"/>
    </Console>
    <Routing name="RoutingAppender">
      <Routes pattern="$${ctx:task.log.id}">
        <Route>
          <File name="task-${ctx:task.log.id}" fileName="${ctx:task.log.file}">
            <PatternLayout pattern="%d{ISO8601} %p [%t] %c -%notEmpty{ [%markerSimpleName]} %m%n"/>
          </File>
        </Route>
        <Route key="$${ctx:task.log.id}" ref="Console"/>
      </Routes>
    </Routing>
  </Appenders>
  <Loggers>
    <Root level="info">
      <AppenderRef ref="RoutingAppender"/>
    </Root>
    <Logger name="org.apache.druid.jetty.RequestLog" level="info" additivity="false">
      <AppenderRef ref="RoutingAppender"/>
    </Logger>
  </Loggers>
</Configuration>
XML

write_service_conf() {
  local service="$1"
  mkdir -p "$CONF/$service"
  cat > "$CONF/$service/runtime.properties"
}

write_service_conf coordinator <<PROPS
druid.service=druid/coordinator
druid.plaintextPort=8081
druid.emitter.prometheus.port=9081
druid.coordinator.startDelay=PT5S
druid.coordinator.period=PT5S
druid.coordinator.asOverlord.enabled=true
druid.coordinator.asOverlord.overlordService=druid/overlord
druid.manager.segments.pollDuration=PT5S
druid.indexer.queue.startDelay=PT5S
druid.indexer.storage.type=metadata
# The Kubernetes overlord extension makes k8s the default runner whenever it is loaded.
druid.indexer.runner.type=httpRemote
PROPS

write_service_conf broker <<PROPS
druid.service=druid/broker
druid.plaintextPort=8082
druid.emitter.prometheus.port=9082
druid.broker.http.numConnections=5
druid.sql.planner.metadataSegmentPollPeriod=5000
druid.sql.planner.metadataRefreshPeriod=PT5S
PROPS

write_service_conf historical <<PROPS
druid.service=druid/historical
druid.plaintextPort=8083
druid.emitter.prometheus.port=9083
druid.segmentCache.locations=[{"path":"$VAR/segment-cache","maxSize":"1g"}]
druid.server.maxSize=1g
druid.historical.cache.useCache=true
druid.historical.cache.populateCache=true
druid.cache.type=caffeine
druid.cache.sizeInBytes=10000000
PROPS

PEON_AGENT_OPT=""
if [ "$TRACE_AGENT" = 1 ]; then
  PEON_AGENT_OPT=",\"-agentlib:native-image-agent=config-merge-dir=$OUTPUT_DIR/peon\""
fi
write_service_conf middleManager <<PROPS
druid.service=druid/middleManager
druid.plaintextPort=8091
druid.emitter.prometheus.port=9091
druid.worker.capacity=1
druid.indexer.runner.javaOptsArray=["-Xmx512m","-XX:MaxDirectMemorySize=512m","-Duser.timezone=UTC","-Dfile.encoding=UTF-8","-Djava.util.logging.manager=org.apache.logging.log4j.jul.LogManager","-Ddruid.sql.calcite.runtimeCodeGeneration=false"$PEON_AGENT_OPT]
druid.indexer.task.baseTaskDir=$VAR/task
druid.indexer.fork.property.druid.processing.buffer.sizeBytes=25000000
druid.indexer.fork.property.druid.processing.numMergeBuffers=2
druid.indexer.fork.property.druid.processing.numThreads=1
druid.indexer.fork.property.druid.processing.tmpDir=$VAR/processing
PROPS

write_service_conf indexer <<PROPS
druid.service=druid/indexer
druid.plaintextPort=8092
druid.emitter.prometheus.port=9092
druid.worker.capacity=1
druid.worker.globalIngestionHeapLimitBytes=100000000
druid.indexer.task.baseTaskDir=$VAR/indexer-task
PROPS

write_service_conf router <<PROPS
druid.service=druid/router
druid.plaintextPort=8888
druid.emitter.prometheus.port=9888
druid.router.http.numConnections=10
druid.router.managementProxy.enabled=true
druid.router.sql.enable=true
PROPS

# --------------------------------------------------------------------------------------------------------------------
# Processes
# --------------------------------------------------------------------------------------------------------------------

CLASSPATH_JARS="$(find "$LIB_DIR" -name '*.jar' | sort | paste -sd ':' -)"

start_zookeeper() {
  mkdir -p "$VAR/zk"
  java -Xmx256m -Dzookeeper.admin.enableServer=false \
    -cp "$CLASSPATH_JARS" org.apache.zookeeper.server.ZooKeeperServerMain 2181 "$VAR/zk" \
    > "$LOGS/zookeeper.log" 2>&1 &
  ZK_PID="$!"
  for _ in $(seq 1 60); do
    if (exec 3<>/dev/tcp/127.0.0.1/2181) 2>/dev/null; then
      log "zookeeper is listening"
      return
    fi
    sleep 1
  done
  echo "ZooKeeper did not start; see $LOGS/zookeeper.log" >&2
  exit 1
}

start_service() {
  local service="$1"
  local heap="$2"
  log "starting $service"
  local -a agent=()
  if [ "$TRACE_AGENT" = 1 ]; then
    agent=("-agentlib:native-image-agent=config-output-dir=$OUTPUT_DIR/$service,config-write-period-secs=30,config-write-initial-delay-secs=15")
  fi
  (
    cd "$DRUID_HOME"
    exec java \
      "${agent[@]}" \
      -Xms"$heap" -Xmx"$heap" -XX:MaxDirectMemorySize=512m \
      -Duser.timezone=UTC -Dfile.encoding=UTF-8 \
      -Djava.util.logging.manager=org.apache.logging.log4j.jul.LogManager \
      -Ddruid.node.type="$service" \
      -Ddruid.sql.calcite.runtimeCodeGeneration=false \
      --add-exports=java.base/jdk.internal.misc=ALL-UNNAMED \
      --add-exports=java.base/jdk.internal.ref=ALL-UNNAMED \
      --add-opens=java.base/java.nio=ALL-UNNAMED \
      --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
      --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED \
      --add-opens=java.base/java.io=ALL-UNNAMED \
      --add-opens=java.base/java.lang=ALL-UNNAMED \
      --add-opens=jdk.management/com.sun.management.internal=ALL-UNNAMED \
      --add-modules=jdk.incubator.vector \
      -cp "$CONF/_common:$CONF/$service:$CLASSPATH_JARS" \
      org.apache.druid.cli.Main server "$service"
  ) > "$LOGS/$service.log" 2>&1 &
  PIDS+=("$!")
}

wait_healthy() {
  local name="$1"
  local url="$2"
  for _ in $(seq 1 "$STARTUP_TIMEOUT"); do
    if [ "$("${CURL[@]}" "$url/status/health" 2>/dev/null)" = "true" ]; then
      log "$name is healthy"
      return 0
    fi
    sleep 1
  done
  echo "$name did not become healthy within ${STARTUP_TIMEOUT}s; see $LOGS" >&2
  tail -50 "$LOGS/$name.log" >&2 || true
  exit 1
}

# --------------------------------------------------------------------------------------------------------------------
# HTTP helpers
# --------------------------------------------------------------------------------------------------------------------

api() {
  # api <step> <method> <url> [json-body]
  local step="$1" method="$2" url="$3" body="${4:-}"
  local response
  if [ -n "$body" ]; then
    response="$("${CURL[@]}" -X "$method" -H 'Content-Type: application/json' --data-binary "$body" -w '\n%{http_code}' "$url")" || response=$'curl failed\n000'
  else
    response="$("${CURL[@]}" -X "$method" -w '\n%{http_code}' "$url")" || response=$'curl failed\n000'
  fi
  local code="${response##*$'\n'}"
  local payload="${response%$'\n'*}"
  if [ "${code:0:1}" = "2" ]; then
    step_ok "$step"
  else
    step_failed "$step" "HTTP $code ${payload:0:300}"
  fi
  printf '%s' "$payload"
}

sql() {
  # sql <step> <base-url> <query>
  local step="$1" base="$2" query="$3"
  local escaped
  escaped="$(printf '%s' "$query" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  api "$step" POST "$base/druid/v2/sql" "{\"query\":\"$escaped\",\"context\":{\"sqlQueryId\":\"trace-$RANDOM\"}}"
}

task_status() {
  "${CURL[@]}" "$COORDINATOR/druid/indexer/v1/task/$1/status" | sed -n 's/.*"statusCode":"\([A-Z]*\)".*/\1/p'
}

submit_task() {
  # submit_task <step> <json>  -> prints task id, waits for completion
  local step="$1" json="$2"
  local response task_id status
  response="$("${CURL[@]}" -X POST -H 'Content-Type: application/json' --data-binary "$json" "$COORDINATOR/druid/indexer/v1/task")" || true
  task_id="$(printf '%s' "$response" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')"
  if [ -z "$task_id" ]; then
    step_failed "$step" "task not accepted: ${response:0:300}"
    return 1
  fi
  for _ in $(seq 1 "$TASK_TIMEOUT"); do
    status="$(task_status "$task_id")"
    case "$status" in
      SUCCESS) step_ok "$step"; printf '%s' "$task_id"; return 0 ;;
      FAILED) step_failed "$step" "task $task_id failed"; printf '%s' "$task_id"; return 1 ;;
    esac
    sleep 1
  done
  step_failed "$step" "task $task_id did not finish within ${TASK_TIMEOUT}s"
  return 1
}

submit_sql_task() {
  # submit_sql_task <step> <sql> -> waits for completion
  local step="$1" query="$2"
  local escaped response task_id status
  escaped="$(printf '%s' "$query" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  response="$("${CURL[@]}" -X POST -H 'Content-Type: application/json' \
    --data-binary "{\"query\":\"$escaped\",\"context\":{\"finalizeAggregations\":false,\"maxNumTasks\":2}}" \
    "$BROKER/druid/v2/sql/task")" || true
  task_id="$(printf '%s' "$response" | sed -n 's/.*"taskId":"\([^"]*\)".*/\1/p')"
  if [ -z "$task_id" ]; then
    step_failed "$step" "sql task not accepted: ${response:0:300}"
    return 1
  fi
  for _ in $(seq 1 "$TASK_TIMEOUT"); do
    status="$(task_status "$task_id")"
    case "$status" in
      SUCCESS) step_ok "$step"; return 0 ;;
      FAILED) step_failed "$step" "task $task_id failed"; return 1 ;;
    esac
    sleep 1
  done
  step_failed "$step" "task $task_id did not finish within ${TASK_TIMEOUT}s"
  return 1
}

wait_for_segments() {
  # wait_for_segments <step> <datasource>
  local step="$1" datasource="$2"
  for _ in $(seq 1 "$TASK_TIMEOUT"); do
    if "${CURL[@]}" "$COORDINATOR/druid/coordinator/v1/loadstatus" | grep -q "\"$datasource\":100"; then
      step_ok "$step"
      return 0
    fi
    sleep 1
  done
  step_failed "$step" "segments of $datasource were not loaded within ${TASK_TIMEOUT}s"
  return 1
}

# --------------------------------------------------------------------------------------------------------------------
# Start the cluster
# --------------------------------------------------------------------------------------------------------------------

start_zookeeper
start_service coordinator 768m
wait_healthy coordinator "$COORDINATOR"
start_service broker 768m
start_service historical 768m
start_service middleManager 512m
start_service indexer 768m
start_service router 384m
wait_healthy broker "$BROKER"
wait_healthy historical "$HISTORICAL"
wait_healthy middleManager "$MIDDLE_MANAGER"
wait_healthy indexer "$INDEXER"
wait_healthy router "$ROUTER"

for _ in $(seq 1 120); do
  leader="$("${CURL[@]}" "$COORDINATOR/druid/coordinator/v1/leader" 2>/dev/null || true)"
  overlord="$("${CURL[@]}" "$COORDINATOR/druid/indexer/v1/leader" 2>/dev/null || true)"
  if [ -n "$leader" ] && [ -n "$overlord" ]; then
    break
  fi
  sleep 1
done
log "coordinator leader [$leader], overlord leader [$overlord]"

# From here on every step records its own outcome; a failing step must not end the recording.
set +e

# --------------------------------------------------------------------------------------------------------------------
# Ingestion: one task for the middleManager, one for the indexer (each has capacity 1, both are submitted together)
# --------------------------------------------------------------------------------------------------------------------

INLINE_DATA='{\"time\":\"2015-09-12T00:46:58.771Z\",\"page\":\"Druid\",\"user\":\"alice\",\"country\":\"BR\",\"added\":36,\"deleted\":0,\"delta\":36.0}\n{\"time\":\"2015-09-12T01:46:58.771Z\",\"page\":\"GraalVM\",\"user\":\"bob\",\"country\":\"US\",\"added\":17,\"deleted\":3,\"delta\":14.0}\n{\"time\":\"2015-09-12T02:46:58.771Z\",\"page\":\"Druid\",\"user\":\"carol\",\"country\":\"BR\",\"added\":5,\"deleted\":1,\"delta\":4.0}\n{\"time\":\"2015-09-12T03:46:58.771Z\",\"page\":\"Kafka\",\"user\":\"alice\",\"country\":\"DE\",\"added\":100,\"deleted\":10,\"delta\":90.0}\n{\"time\":\"2015-09-12T04:46:58.771Z\",\"page\":\"GraalVM\",\"user\":\"dave\",\"country\":\"US\",\"added\":8,\"deleted\":8,\"delta\":0.0}\n{\"time\":\"2015-09-12T05:46:58.771Z\",\"page\":\"Druid\",\"user\":\"erin\",\"country\":\"FR\",\"added\":42,\"deleted\":2,\"delta\":40.0}'

index_task() {
  local datasource="$1"
  cat <<TASK
{
  "type": "index_parallel",
  "spec": {
    "ioConfig": {
      "type": "index_parallel",
      "inputSource": {"type": "inline", "data": "$INLINE_DATA"},
      "inputFormat": {"type": "json"}
    },
    "tuningConfig": {"type": "index_parallel", "partitionsSpec": {"type": "dynamic"}, "maxNumConcurrentSubTasks": 1},
    "dataSchema": {
      "dataSource": "$datasource",
      "timestampSpec": {"column": "time", "format": "iso"},
      "dimensionsSpec": {"dimensions": ["page", "user", "country"]},
      "granularitySpec": {"queryGranularity": "none", "rollup": true, "segmentGranularity": "day"},
      "metricsSpec": [
        {"type": "count", "name": "count"},
        {"type": "longSum", "name": "added", "fieldName": "added"},
        {"type": "longSum", "name": "deleted", "fieldName": "deleted"},
        {"type": "doubleSum", "name": "delta", "fieldName": "delta"},
        {"type": "thetaSketch", "name": "user_theta", "fieldName": "user"},
        {"type": "HLLSketchBuild", "name": "user_hll", "fieldName": "user"},
        {"type": "quantilesDoublesSketch", "name": "added_quantiles", "fieldName": "added"},
        {"type": "variance", "name": "added_variance", "fieldName": "added", "inputType": "long"},
        {"type": "longMax", "name": "added_max", "fieldName": "added"},
        {"type": "timeMin", "name": "time_min", "fieldName": "__time"},
        {"type": "timeMax", "name": "time_max", "fieldName": "__time"}
      ]
    }
  }
}
TASK
}

first_response="$("${CURL[@]}" -X POST -H 'Content-Type: application/json' --data-binary "$(index_task trace)" "$COORDINATOR/druid/indexer/v1/task")" || true
second_response="$("${CURL[@]}" -X POST -H 'Content-Type: application/json' --data-binary "$(index_task trace_indexer)" "$COORDINATOR/druid/indexer/v1/task")" || true
first_task="$(printf '%s' "$first_response" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')"
second_task="$(printf '%s' "$second_response" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')"
log "submitted ingestion tasks [$first_task] and [$second_task]"
ingestion_ok=1
for task in "$first_task" "$second_task"; do
  if [ -z "$task" ]; then
    ingestion_ok=0
    continue
  fi
  for _ in $(seq 1 "$TASK_TIMEOUT"); do
    status="$(task_status "$task")"
    if [ "$status" = "SUCCESS" ] || [ "$status" = "FAILED" ]; then
      break
    fi
    sleep 1
  done
  if [ "$status" = "SUCCESS" ]; then
    step_ok "ingestion task $task"
  else
    step_failed "ingestion task $task" "status [$status]"
    ingestion_ok=0
  fi
done
if [ "$ingestion_ok" != 1 ]; then
  echo "Ingestion failed; the trace cannot continue. Logs are in $LOGS" >&2
  tail -100 "$LOGS/middleManager.log" >&2 || true
  exit 1
fi
wait_for_segments "segments loaded (trace)" trace
wait_for_segments "segments loaded (trace_indexer)" trace_indexer
sleep 10

# --------------------------------------------------------------------------------------------------------------------
# Lookups
# --------------------------------------------------------------------------------------------------------------------

printf 'Druid,database\nGraalVM,compiler\nKafka,broker\n' > "$VAR/lookup.csv"
api "lookups: initialize" POST "$COORDINATOR/druid/coordinator/v1/lookups/config" '{}' > /dev/null
api "lookups: configure" POST "$COORDINATOR/druid/coordinator/v1/lookups/config" "{\"__default\": {
  \"trace_map\": {\"version\": \"v1\", \"lookupExtractorFactory\": {\"type\": \"map\", \"map\": {\"BR\": \"Brazil\", \"US\": \"United States\", \"DE\": \"Germany\", \"FR\": \"France\"}}},
  \"trace_file\": {\"version\": \"v1\", \"lookupExtractorFactory\": {\"type\": \"cachedNamespace\", \"extractionNamespace\": {\"type\": \"uri\", \"uri\": \"file://$VAR/lookup.csv\", \"namespaceParseSpec\": {\"format\": \"csv\", \"columns\": [\"key\", \"value\"]}, \"pollPeriod\": \"PT1M\"}, \"firstCacheTimeout\": 30000}}
}}" > /dev/null
for _ in $(seq 1 120); do
  if "${CURL[@]}" "$BROKER/druid/listen/v1/lookups" | grep -q trace_file && "${CURL[@]}" "$HISTORICAL/druid/listen/v1/lookups" | grep -q trace_file; then
    break
  fi
  sleep 1
done
api "lookups: status" GET "$COORDINATOR/druid/coordinator/v1/lookups/status" > /dev/null
api "lookups: node status" GET "$COORDINATOR/druid/coordinator/v1/lookups/nodeStatus" > /dev/null

# --------------------------------------------------------------------------------------------------------------------
# SQL through the broker and the router
# --------------------------------------------------------------------------------------------------------------------

sql "sql: count" "$BROKER" "SELECT COUNT(*), SUM(added), MAX(delta) FROM trace" > /dev/null
sql "sql: group by with sketches" "$BROKER" "SELECT page, APPROX_COUNT_DISTINCT_DS_THETA(user_theta), APPROX_COUNT_DISTINCT_DS_HLL(user_hll), DS_GET_QUANTILE(DS_QUANTILES_SKETCH(added_quantiles), 0.5), VARIANCE(added_variance), THETA_SKETCH_ESTIMATE(DS_THETA(user_theta)) FROM trace GROUP BY page ORDER BY page" > /dev/null
sql "sql: time functions and filters" "$BROKER" "SELECT TIME_FLOOR(__time, 'PT1H') AS hr, country, SUM(added) FROM trace WHERE country IN ('BR', 'US') AND __time >= TIMESTAMP '2015-09-12 00:00:00' GROUP BY 1, 2 ORDER BY 1 LIMIT 10" > /dev/null
sql "sql: lookups" "$BROKER" "SELECT LOOKUP(country, 'trace_map') AS country_name, LOOKUP(page, 'trace_file') AS kind, COUNT(*) FROM trace GROUP BY 1, 2" > /dev/null
sql "sql: join and subquery" "$BROKER" "SELECT t.page, i.cnt FROM trace t INNER JOIN (SELECT page, COUNT(*) AS cnt FROM trace_indexer GROUP BY page) i ON t.page = i.page GROUP BY t.page, i.cnt" > /dev/null
sql "sql: union all" "$BROKER" "SELECT page, SUM(added) FROM (SELECT page, added FROM trace UNION ALL SELECT page, added FROM trace_indexer) GROUP BY page ORDER BY page" > /dev/null
sql "sql: window" "$BROKER" "SELECT page, added, SUM(added) OVER (PARTITION BY page ORDER BY __time) AS running_total FROM trace LIMIT 20" > /dev/null
sql "sql: scan with expressions" "$BROKER" "SELECT __time, UPPER(page), CONCAT(user, '@', country), added * 2 + deleted, CASE WHEN delta > 10 THEN 'big' ELSE 'small' END, MV_TO_ARRAY(page), STRING_TO_ARRAY(user, ',') FROM trace ORDER BY __time DESC LIMIT 5" > /dev/null
sql "sql: time boundary and min/max" "$BROKER" "SELECT MIN(__time), MAX(__time), MIN(time_min), MAX(time_max) FROM trace" > /dev/null
sql "sql: explain" "$BROKER" "EXPLAIN PLAN FOR SELECT page, COUNT(*) FROM trace GROUP BY page" > /dev/null
sql "sql: sys.segments" "$BROKER" "SELECT segment_id, datasource, size, is_published, is_available FROM sys.segments WHERE datasource = 'trace' AND is_published = 1 ORDER BY segment_id" > /dev/null
sql "sql: sys.servers" "$BROKER" "SELECT server, server_type, tier, curr_size FROM sys.servers WHERE server_type <> 'peon' ORDER BY server" > /dev/null
sql "sql: sys.tasks" "$BROKER" "SELECT task_id, type, status FROM sys.tasks WHERE type = 'index_parallel' ORDER BY created_time DESC LIMIT 5" > /dev/null
sql "sql: sys.supervisors" "$BROKER" "SELECT supervisor_id, state FROM sys.supervisors" > /dev/null
sql "sql: information_schema" "$BROKER" "SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'druid' AND TABLE_NAME LIKE 'trace%' ORDER BY TABLE_NAME, ORDINAL_POSITION" > /dev/null
sql "sql: information_schema.schemata" "$BROKER" "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA ORDER BY SCHEMA_NAME" > /dev/null
sql "sql: via router" "$ROUTER" "SELECT country, COUNT(*) FROM trace GROUP BY country" > /dev/null
sql "sql: array and json functions" "$BROKER" "SELECT ARRAY_LENGTH(ARRAY[1, 2, 3]), JSON_VALUE(PARSE_JSON('{\"a\": 1}'), '\$.a'), TIME_PARSE('2015-09-12T00:00:00Z'), TIME_FORMAT(__time, 'yyyy-MM-dd'), REGEXP_EXTRACT(page, '^(.)'), STRING_FORMAT('%s-%s', page, user) FROM trace LIMIT 3" > /dev/null

# --------------------------------------------------------------------------------------------------------------------
# Native queries
# --------------------------------------------------------------------------------------------------------------------

api "native: timeseries" POST "$BROKER/druid/v2" '{"queryType":"timeseries","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"granularity":"hour","aggregations":[{"type":"longSum","name":"added","fieldName":"added"},{"type":"thetaSketch","name":"users","fieldName":"user_theta"}],"postAggregations":[{"type":"thetaSketchEstimate","name":"users_estimate","field":{"type":"fieldAccess","fieldName":"users"}}]}' > /dev/null
api "native: topN" POST "$BROKER/druid/v2" '{"queryType":"topN","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"granularity":"all","dimension":"page","metric":"added","threshold":3,"aggregations":[{"type":"longSum","name":"added","fieldName":"added"}]}' > /dev/null
api "native: groupBy" POST "$BROKER/druid/v2" '{"queryType":"groupBy","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"granularity":"all","dimensions":["page",{"type":"extraction","dimension":"country","outputName":"country_name","extractionFn":{"type":"registeredLookup","lookup":"trace_map","retainMissingValue":true}}],"aggregations":[{"type":"count","name":"rows"},{"type":"HLLSketchMerge","name":"users","fieldName":"user_hll"},{"type":"quantilesDoublesSketch","name":"added_quantiles","fieldName":"added_quantiles"}],"postAggregations":[{"type":"quantilesDoublesSketchToQuantile","name":"median","field":{"type":"fieldAccess","fieldName":"added_quantiles"},"fraction":0.5}],"having":{"type":"greaterThan","aggregation":"rows","value":0},"limitSpec":{"type":"default","limit":10,"columns":[{"dimension":"rows","direction":"descending"}]}}' > /dev/null
api "native: scan" POST "$BROKER/druid/v2" '{"queryType":"scan","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"columns":["__time","page","user","added"],"filter":{"type":"and","fields":[{"type":"selector","dimension":"country","value":"BR"},{"type":"bound","dimension":"added","lower":"1","ordering":"numeric"}]},"limit":10,"resultFormat":"compactedList"}' > /dev/null
api "native: search" POST "$BROKER/druid/v2" '{"queryType":"search","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"granularity":"all","searchDimensions":["page","user"],"query":{"type":"insensitive_contains","value":"ru"}}' > /dev/null
api "native: timeBoundary" POST "$BROKER/druid/v2" '{"queryType":"timeBoundary","dataSource":"trace"}' > /dev/null
api "native: segmentMetadata" POST "$BROKER/druid/v2" '{"queryType":"segmentMetadata","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"analysisTypes":["cardinality","interval","minmax","size","aggregators","rollup"],"merge":true}' > /dev/null
api "native: dataSourceMetadata" POST "$BROKER/druid/v2" '{"queryType":"dataSourceMetadata","dataSource":"trace"}' > /dev/null
api "native: movingAverage" POST "$BROKER/druid/v2" '{"queryType":"movingAverage","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"granularity":"hour","aggregations":[{"type":"longSum","name":"added","fieldName":"added"}],"averagers":[{"type":"doubleMean","name":"added_avg","fieldName":"added","buckets":3}]}' > /dev/null
api "native: historical direct" POST "$HISTORICAL/druid/v2" '{"queryType":"timeseries","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"granularity":"all","aggregations":[{"type":"count","name":"rows"}]}' > /dev/null
api "native: candidates" POST "$BROKER/druid/v2/candidates" '{"queryType":"timeseries","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"granularity":"all","aggregations":[{"type":"count","name":"rows"}]}' > /dev/null
api "native: datasources" GET "$BROKER/druid/v2/datasources/trace" > /dev/null

# --------------------------------------------------------------------------------------------------------------------
# Multi-stage query, compaction and kill tasks
# --------------------------------------------------------------------------------------------------------------------

submit_sql_task "msq: replace from extern" "REPLACE INTO trace_msq OVERWRITE ALL SELECT TIME_PARSE(\"time\") AS __time, page, user, country, added, deleted FROM TABLE(EXTERN('{\"type\":\"inline\",\"data\":\"$INLINE_DATA\"}', '{\"type\":\"json\"}', '[{\"name\":\"time\",\"type\":\"string\"},{\"name\":\"page\",\"type\":\"string\"},{\"name\":\"user\",\"type\":\"string\"},{\"name\":\"country\",\"type\":\"string\"},{\"name\":\"added\",\"type\":\"long\"},{\"name\":\"deleted\",\"type\":\"long\"}]')) PARTITIONED BY DAY CLUSTERED BY page" || true
submit_sql_task "msq: insert from table" "INSERT INTO trace_msq SELECT __time, page, user, country, added, deleted FROM trace_indexer PARTITIONED BY DAY" || true
wait_for_segments "segments loaded (trace_msq)" trace_msq || true
sql "sql: query msq result" "$BROKER" "SELECT page, COUNT(*) FROM trace_msq GROUP BY page" > /dev/null
api "msq: statement api async" POST "$BROKER/druid/v2/sql/statements" '{"query":"SELECT page, COUNT(*) FROM trace GROUP BY page","context":{"executionMode":"ASYNC"}}' > /dev/null

submit_task "compaction task" '{"type":"compact","dataSource":"trace","ioConfig":{"type":"compact","inputSpec":{"type":"interval","interval":"2015-09-12/2015-09-13"}},"tuningConfig":{"type":"index_parallel","partitionsSpec":{"type":"dynamic"},"maxNumConcurrentSubTasks":1}}' > /dev/null || true

api "coordinator: mark unused" DELETE "$COORDINATOR/druid/coordinator/v1/datasources/trace_indexer" > /dev/null
sleep 5
submit_task "kill task" '{"type":"kill","dataSource":"trace_indexer","interval":"1000-01-01/3000-01-01"}' > /dev/null || true

# --------------------------------------------------------------------------------------------------------------------
# Supervisors (the Kafka cluster does not exist; this records the Kafka client set-up and error handling)
# --------------------------------------------------------------------------------------------------------------------

api "supervisor: create kafka" POST "$COORDINATOR/druid/indexer/v1/supervisor" '{"type":"kafka","spec":{"dataSchema":{"dataSource":"trace_kafka","timestampSpec":{"column":"time","format":"iso"},"dimensionsSpec":{"dimensions":["page"]},"granularitySpec":{"type":"uniform","segmentGranularity":"HOUR","queryGranularity":"NONE"}},"ioConfig":{"topic":"trace","inputFormat":{"type":"json"},"consumerProperties":{"bootstrap.servers":"localhost:19092","default.api.timeout.ms":"5000","request.timeout.ms":"5000"},"taskCount":1,"replicas":1,"taskDuration":"PT1H","useEarliestOffset":true,"period":"PT5S"},"tuningConfig":{"type":"kafka","maxRowsPerSegment":5000000}}}' > /dev/null
sleep 25
api "supervisor: list" GET "$COORDINATOR/druid/indexer/v1/supervisor?full" > /dev/null
api "supervisor: status" GET "$COORDINATOR/druid/indexer/v1/supervisor/trace_kafka/status" > /dev/null
api "supervisor: suspend" POST "$COORDINATOR/druid/indexer/v1/supervisor/trace_kafka/suspend" > /dev/null
api "supervisor: terminate" POST "$COORDINATOR/druid/indexer/v1/supervisor/trace_kafka/terminate" > /dev/null
api "supervisor: history" GET "$COORDINATOR/druid/indexer/v1/supervisor/history" > /dev/null

# --------------------------------------------------------------------------------------------------------------------
# Coordinator, overlord, router and security APIs
# --------------------------------------------------------------------------------------------------------------------

api "coordinator: datasources" GET "$COORDINATOR/druid/coordinator/v1/datasources?full" > /dev/null
api "coordinator: metadata datasources" GET "$COORDINATOR/druid/coordinator/v1/metadata/datasources?includeUnused" > /dev/null
api "coordinator: metadata segments" GET "$COORDINATOR/druid/coordinator/v1/metadata/datasources/trace/segments?full" > /dev/null
api "coordinator: servers" GET "$COORDINATOR/druid/coordinator/v1/servers?full" > /dev/null
api "coordinator: load queue" GET "$COORDINATOR/druid/coordinator/v1/loadqueue?simple" > /dev/null
api "coordinator: load status" GET "$COORDINATOR/druid/coordinator/v1/loadstatus?full" > /dev/null
api "coordinator: rules" GET "$COORDINATOR/druid/coordinator/v1/rules" > /dev/null
api "coordinator: set rules" POST "$COORDINATOR/druid/coordinator/v1/rules/trace" '[{"type":"loadForever","tieredReplicants":{"_default_tier":1}}]' > /dev/null
api "coordinator: dynamic config" GET "$COORDINATOR/druid/coordinator/v1/config" > /dev/null
api "coordinator: set dynamic config" POST "$COORDINATOR/druid/coordinator/v1/config" '{"maxSegmentsToMove":10,"replicationThrottleLimit":50,"balancerComputeThreads":1}' > /dev/null
api "coordinator: compaction config" GET "$COORDINATOR/druid/coordinator/v1/config/compaction" > /dev/null
api "coordinator: set compaction config" POST "$COORDINATOR/druid/coordinator/v1/config/compaction" '{"dataSource":"trace","taskPriority":25,"inputSegmentSizeBytes":100000000000000,"skipOffsetFromLatest":"P1D","tuningConfig":{"partitionsSpec":{"type":"dynamic","maxRowsPerSegment":5000000}}}' > /dev/null
api "coordinator: compaction status" GET "$COORDINATOR/druid/coordinator/v1/compaction/status" > /dev/null
api "coordinator: tiers" GET "$COORDINATOR/druid/coordinator/v1/tiers?simple" > /dev/null
api "coordinator: intervals" GET "$COORDINATOR/druid/coordinator/v1/datasources/trace/intervals?full" > /dev/null
api "coordinator: cluster" GET "$COORDINATOR/druid/coordinator/v1/cluster" > /dev/null
api "coordinator: segment metadata" GET "$COORDINATOR/druid/coordinator/v1/metadata/datasources/trace" > /dev/null
api "overlord: tasks" GET "$COORDINATOR/druid/indexer/v1/tasks?max=50" > /dev/null
api "overlord: complete tasks" GET "$COORDINATOR/druid/indexer/v1/completeTasks" > /dev/null
api "overlord: workers" GET "$COORDINATOR/druid/indexer/v1/workers" > /dev/null
api "overlord: worker config" GET "$COORDINATOR/druid/indexer/v1/worker" > /dev/null
api "overlord: set worker config" POST "$COORDINATOR/druid/indexer/v1/worker" '{"selectStrategy":{"type":"equalDistribution"}}' > /dev/null
api "overlord: scaling" GET "$COORDINATOR/druid/indexer/v1/scaling" > /dev/null
# Only the middleManager pushes per-task log files (the indexer logs tasks through log4j routing, which this trace
# does not configure), so one of the two tasks has a log.
task_log_found=0
for task in "$first_task" "$second_task"; do
  if [ "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$COORDINATOR/druid/indexer/v1/task/$task/log")" = 200 ]; then
    task_log_found=1
  fi
done
if [ "$task_log_found" = 1 ]; then
  step_ok "overlord: task log"
else
  step_failed "overlord: task log" "no log served for either ingestion task"
fi
api "overlord: task reports" GET "$COORDINATOR/druid/indexer/v1/task/$first_task/reports" > /dev/null
api "overlord: task payload" GET "$COORDINATOR/druid/indexer/v1/task/$first_task" > /dev/null
api "overlord: locks" POST "$COORDINATOR/druid/indexer/v1/lockedIntervals/v2" '[{"datasource":"trace","priority":0}]' > /dev/null
api "security: users" GET "$COORDINATOR/druid-ext/basic-security/authentication/db/basic/users" > /dev/null
api "security: create user" POST "$COORDINATOR/druid-ext/basic-security/authentication/db/basic/users/tracer" > /dev/null
api "security: set credentials" POST "$COORDINATOR/druid-ext/basic-security/authentication/db/basic/users/tracer/credentials" '{"password":"tracer1","iterations":1000}' > /dev/null
api "security: authorizer user" POST "$COORDINATOR/druid-ext/basic-security/authorization/db/basic/users/tracer" > /dev/null
api "security: create role" POST "$COORDINATOR/druid-ext/basic-security/authorization/db/basic/roles/reader" > /dev/null
api "security: role permissions" POST "$COORDINATOR/druid-ext/basic-security/authorization/db/basic/roles/reader/permissions" '[{"resource":{"name":".*","type":"DATASOURCE"},"action":"READ"},{"resource":{"name":".*","type":"STATE"},"action":"READ"}]' > /dev/null
api "security: assign role" POST "$COORDINATOR/druid-ext/basic-security/authorization/db/basic/users/tracer/roles/reader" > /dev/null
api "security: cached maps" GET "$COORDINATOR/druid-ext/basic-security/authentication/db/basic/cachedSerializedUserMap" > /dev/null
sleep 6
if [ "$(curl -s --max-time 60 -u tracer:tracer1 "$BROKER/status/health")" = "true" ]; then
  step_ok "security: new user can authenticate"
else
  step_failed "security: new user can authenticate"
fi
api "router: brokers" GET "$ROUTER/druid/router/v1/brokers" > /dev/null
api "router: console" GET "$ROUTER/unified-console.html" > /dev/null
api "router: console config" GET "$ROUTER/console-config.js" > /dev/null
console_asset="$("${CURL[@]}" "$ROUTER/unified-console.html" | grep -o 'public/web-console-[^"]*\.js' | head -1)"
api "router: console assets" GET "$ROUTER/${console_asset:-public/missing.js}" > /dev/null
api "router: proxy coordinator" GET "$ROUTER/proxy/coordinator/druid/coordinator/v1/datasources" > /dev/null
api "router: proxy overlord" GET "$ROUTER/proxy/overlord/druid/indexer/v1/tasks" > /dev/null
api "router: query via native" POST "$ROUTER/druid/v2" '{"queryType":"timeseries","dataSource":"trace","intervals":["2015-09-12/2015-09-13"],"granularity":"all","aggregations":[{"type":"count","name":"rows"}]}' > /dev/null
api "status: properties" GET "$BROKER/status/properties" > /dev/null
api "status: selfDiscovered" GET "$BROKER/status/selfDiscovered/status" > /dev/null
api "broker: segment metadata cache" GET "$BROKER/druid/broker/v1/loadstatus" > /dev/null
api "historical: segments" GET "$HISTORICAL/druid/historical/v1/loadstatus" > /dev/null
api "historical: segment list" GET "$HISTORICAL/druid-internal/v1/segments?counter=-1&hash=0&timeout=1000" > /dev/null
api "middleManager: workers" GET "$MIDDLE_MANAGER/druid/worker/v1/tasks" > /dev/null
api "middleManager: disable" POST "$MIDDLE_MANAGER/druid/worker/v1/disable" > /dev/null
api "middleManager: enable" POST "$MIDDLE_MANAGER/druid/worker/v1/enable" > /dev/null
api "indexer: tasks" GET "$INDEXER/druid/worker/v1/tasks" > /dev/null
for port in 9081 9082 9083 9091 9092 9888; do
  api "prometheus: metrics on $port" GET "http://localhost:$port/metrics" > /dev/null
done
api "coordinator: drop datasource" DELETE "$COORDINATOR/druid/coordinator/v1/datasources/trace_msq" > /dev/null

# Let periodic work (metrics emission, compaction scheduling, segment balancing) run once more.
sleep 20

# --------------------------------------------------------------------------------------------------------------------
# Shut down gracefully so every agent writes its final configuration
# --------------------------------------------------------------------------------------------------------------------

log "stopping the cluster"
stop_cluster

{
  echo "Trace summary: ${#PASSED_STEPS[@]} steps passed, ${#FAILED_STEPS[@]} failed"
  for step in "${FAILED_STEPS[@]}"; do
    echo "  failed: $step"
  done
  for step in "${PASSED_STEPS[@]}"; do
    echo "  passed: $step"
  done
} > "$OUTPUT_DIR/trace-summary.txt"
echo
head -n $(( ${#FAILED_STEPS[@]} + 1 )) "$OUTPUT_DIR/trace-summary.txt"
echo
echo "Agent output:"
find "$OUTPUT_DIR" -type f | sort | xargs -r ls -la

# Cluster start-up must always succeed. With TRACE_STRICT=1 so must every workload step; without it, a failed step
# only costs coverage, which is convenient while debugging the workload itself.
if [ "${TRACE_STRICT:-0}" = 1 ] && [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
  exit 1
fi
