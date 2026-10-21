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

# Smoke-tests a Druid image with the Kubernetes task runner: a single-node k3s cluster (in Docker) runs ZooKeeper,
# PostgreSQL, a coordinator-overlord with druid.indexer.runner.type=k8s, a broker, a historical and a router from the
# image, then an ingestion task is submitted and must complete in a peon pod started by the overlord.
#
#   k8s-smoke.sh <image> [k3s-image]
#
# Needs only docker: kubectl runs inside the k3s container. Cleans up the k3s container on exit unless
# K8S_SMOKE_KEEP=1.

set -euo pipefail

IMAGE="$1"
K3S_IMAGE="${2:-rancher/k3s:v1.35.0-k3s1}"
NAME="druid-k3s-smoke"
WORK="$(mktemp -d)"
# k3s ships kubectl, already configured for its own API server.
KUBECTL_RAW=(docker exec -i "$NAME" kubectl)
KUBECTL=("${KUBECTL_RAW[@]}" -n druid)

log() {
  echo "$(date -u +%H:%M:%S) $*" >&2
}

cleanup() {
  if [ "${K8S_SMOKE_KEEP:-0}" != 1 ]; then
    docker rm -f "$NAME" > /dev/null 2>&1 || true
    rm -rf "$WORK"
  else
    log "keeping k3s container $NAME; use: docker exec -i $NAME kubectl -n druid ..."
  fi
}
trap cleanup EXIT

log "starting k3s"
docker rm -f "$NAME" > /dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged -p 30081:30081 -p 30082:30082 -p 30888:30888 \
  "$K3S_IMAGE" server --disable traefik --disable metrics-server > /dev/null
ready=0
for _ in $(seq 1 120); do
  if "${KUBECTL_RAW[@]}" get nodes 2>/dev/null | grep -q ' Ready'; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" != 1 ]; then
  log "k3s did not become ready"
  docker logs --tail 50 "$NAME" >&2 || true
  exit 1
fi
log "k3s is ready"

log "loading $IMAGE into k3s"
docker save "$IMAGE" | docker exec -i "$NAME" ctr -n k8s.io images import - > /dev/null

"${KUBECTL_RAW[@]}" create namespace druid > /dev/null
"${KUBECTL[@]}" apply -f - <<MANIFESTS
apiVersion: v1
kind: ServiceAccount
metadata:
  name: druid
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: druid
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "configmaps", "events"]
    verbs: ["*"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: druid
subjects:
  - kind: ServiceAccount
    name: druid
roleRef:
  kind: Role
  name: druid
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zookeeper
spec:
  replicas: 1
  selector: {matchLabels: {app: zookeeper}}
  template:
    metadata: {labels: {app: zookeeper}}
    spec:
      containers:
        - name: zookeeper
          image: zookeeper:3.9.3
          env: [{name: ZOO_MY_ID, value: "1"}]
          ports: [{containerPort: 2181}]
---
apiVersion: v1
kind: Service
metadata:
  name: zookeeper
spec:
  selector: {app: zookeeper}
  ports: [{port: 2181}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  selector: {matchLabels: {app: postgres}}
  template:
    metadata: {labels: {app: postgres}}
    spec:
      containers:
        - name: postgres
          image: postgres:17.6
          env:
            - {name: POSTGRES_PASSWORD, value: FoolishPassword}
            - {name: POSTGRES_USER, value: druid}
            - {name: POSTGRES_DB, value: druid}
          ports: [{containerPort: 5432}]
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector: {app: postgres}
  ports: [{port: 5432}]
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: druid-env
data:
  druid_extensions_loadList: '["druid-datasketches", "postgresql-metadata-storage", "druid-kafka-indexing-service", "druid-kubernetes-overlord-extensions"]'
  druid_zk_service_host: zookeeper
  druid_metadata_storage_type: postgresql
  druid_metadata_storage_connector_connectURI: jdbc:postgresql://postgres:5432/druid
  druid_metadata_storage_connector_user: druid
  druid_metadata_storage_connector_password: FoolishPassword
  druid_storage_type: local
  druid_storage_storageDirectory: /opt/shared/segments
  druid_indexer_logs_type: file
  druid_indexer_logs_directory: /opt/shared/indexing-logs
  druid_emitter: noop
  druid_lookup_enableLookupSyncOnStartup: "false"
  druid_processing_buffer_sizeBytes: "25000000"
  druid_processing_numMergeBuffers: "2"
  druid_processing_numThreads: "1"
  druid_server_http_numThreads: "12"
  DRUID_LOG4J: '<?xml version="1.0" encoding="UTF-8" ?><Configuration status="WARN"><Appenders><Console name="Console" target="SYSTEM_OUT"><PatternLayout pattern="%d{ISO8601} %p [%t] %c - %m%n"/></Console></Appenders><Loggers><Root level="info"><AppenderRef ref="Console"/></Root></Loggers></Configuration>'
MANIFESTS

druid_service() {
  # druid_service <name> <command> <port> <nodePort> <xmx> <direct> [extra env yaml lines]
  local name="$1" command="$2" port="$3" node_port="$4" xmx="$5" direct="$6" extra="${7:-}"
  cat <<MANIFEST
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
spec:
  replicas: 1
  selector: {matchLabels: {app: $name}}
  template:
    metadata: {labels: {app: $name}}
    spec:
      serviceAccountName: druid
      volumes:
        - name: shared
          hostPath: {path: /druid-shared, type: DirectoryOrCreate}
      containers:
        - name: druid
          image: $IMAGE
          imagePullPolicy: Never
          args: [$command]
          ports: [{containerPort: $port}]
          volumeMounts:
            - {name: shared, mountPath: /opt/shared}
          envFrom:
            - configMapRef: {name: druid-env}
          env:
            - {name: DRUID_XMX, value: "$xmx"}
            - {name: DRUID_XMS, value: "$xmx"}
            - {name: DRUID_MAXDIRECTMEMORYSIZE, value: "$direct"}
            - name: druid_host
              valueFrom: {fieldRef: {fieldPath: status.podIP}}
$extra
---
apiVersion: v1
kind: Service
metadata:
  name: $name
spec:
  type: NodePort
  selector: {app: $name}
  ports: [{port: $port, nodePort: $node_port}]
MANIFEST
}

{
  druid_service coordinator coordinator 8081 30081 256m 128m "            - {name: druid_coordinator_asOverlord_enabled, value: \"true\"}
            - {name: druid_coordinator_asOverlord_overlordService, value: druid/overlord}
            - {name: druid_coordinator_startDelay, value: PT5S}
            - {name: druid_coordinator_period, value: PT5S}
            - {name: druid_indexer_queue_startDelay, value: PT5S}
            - {name: druid_indexer_storage_type, value: metadata}
            - {name: druid_indexer_runner_type, value: k8s}
            - {name: druid_indexer_runner_namespace, value: druid}
            - {name: druid_indexer_runner_capacity, value: \"2\"}
            - {name: druid_indexer_runner_maxTaskDuration, value: PT1H}
            - {name: druid_indexer_runner_taskCleanupDelay, value: PT1M}
            - {name: druid_indexer_runner_javaOptsArray, value: '[\"-Xmx512m\",\"-Xms512m\",\"-XX:MaxDirectMemorySize=512m\",\"-Duser.timezone=UTC\",\"-Dfile.encoding=UTF-8\",\"-Djava.util.logging.manager=org.apache.logging.log4j.jul.LogManager\"]'}
            - {name: druid_indexer_fork_property_druid_processing_buffer_sizeBytes, value: \"25000000\"}
            - {name: druid_indexer_fork_property_druid_processing_numMergeBuffers, value: \"2\"}
            - {name: druid_indexer_fork_property_druid_processing_numThreads, value: \"1\"}
            - {name: druid_indexer_task_encapsulatedTask, value: \"true\"}"
  druid_service broker broker 8082 30082 512m 512m "            - {name: druid_broker_http_numConnections, value: \"5\"}"
  druid_service historical historical 8083 30083 512m 512m "            - {name: druid_segmentCache_locations, value: '[{\"path\":\"/opt/druid/var/druid/segment-cache\",\"maxSize\":\"1g\"}]'}
            - {name: druid_server_maxSize, value: 1g}"
  druid_service router router 8888 30888 128m 64m "            - {name: druid_router_managementProxy_enabled, value: \"true\"}"
} | "${KUBECTL[@]}" apply -f - > /dev/null

log "waiting for Druid pods"
for app in coordinator broker historical router; do
  "${KUBECTL[@]}" rollout status deployment/"$app" --timeout=600s > /dev/null
done
healthy=0
for _ in $(seq 1 300); do
  if [ "$(curl -s --max-time 2 http://127.0.0.1:30081/status/health)" = "true" ] \
     && [ "$(curl -s --max-time 2 http://127.0.0.1:30082/status/health)" = "true" ]; then
    healthy=1
    break
  fi
  sleep 2
done
if [ "$healthy" != 1 ]; then
  log "the coordinator-overlord or the broker did not become healthy"
  "${KUBECTL[@]}" get pods -o wide >&2 || true
  "${KUBECTL[@]}" logs deployment/coordinator --tail=60 >&2 || true
  "${KUBECTL[@]}" logs deployment/broker --tail=60 >&2 || true
  exit 1
fi
log "coordinator-overlord and broker are healthy"
"${KUBECTL[@]}" get pods -o wide

log "submitting an ingestion task"
task_id="$(curl -sS -X POST -H 'Content-Type: application/json' --data-binary '{
  "type": "index_parallel",
  "spec": {
    "ioConfig": {"type": "index_parallel", "inputSource": {"type": "inline", "data": "{\"time\":\"2015-09-12T00:46:58.771Z\",\"page\":\"Druid\",\"added\":36}\n{\"time\":\"2015-09-12T01:46:58.771Z\",\"page\":\"GraalVM\",\"added\":17}\n{\"time\":\"2015-09-12T02:46:58.771Z\",\"page\":\"Kubernetes\",\"added\":5}"}, "inputFormat": {"type": "json"}},
    "tuningConfig": {"type": "index_parallel", "partitionsSpec": {"type": "dynamic"}, "maxNumConcurrentSubTasks": 1},
    "dataSchema": {"dataSource": "k8s_smoke", "timestampSpec": {"column": "time", "format": "iso"}, "dimensionsSpec": {"dimensions": ["page"]}, "metricsSpec": [{"type": "longSum", "name": "added", "fieldName": "added"}], "granularitySpec": {"queryGranularity": "none", "rollup": true, "segmentGranularity": "day"}}
  }
}' http://127.0.0.1:30081/druid/indexer/v1/task | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')"
log "task $task_id submitted"
status=""
for _ in $(seq 1 600); do
  status="$(curl -s "http://127.0.0.1:30081/druid/indexer/v1/task/$task_id/status" | sed -n 's/.*"statusCode":"\([A-Z]*\)".*/\1/p')"
  if [ "$status" = "SUCCESS" ] || [ "$status" = "FAILED" ]; then
    break
  fi
  if [ $(( RANDOM % 15 )) -eq 0 ]; then
    "${KUBECTL[@]}" get pods --no-headers 2>/dev/null | grep -v -E "coordinator|broker|historical|router|zookeeper|postgres" | sed 's/^/  peon pod: /' >&2 || true
  fi
  sleep 2
done
log "task $task_id finished with status [$status]"
echo
echo "Peon jobs created by the overlord:"
"${KUBECTL[@]}" get jobs,pods -l druid.k8s.peons=true -o wide 2>/dev/null || "${KUBECTL[@]}" get jobs,pods -o wide
echo
echo "Task log (tail):"
curl -s "http://127.0.0.1:30081/druid/indexer/v1/task/$task_id/log?offset=-3000" | tail -25
echo
if [ "$status" != "SUCCESS" ]; then
  echo "Overlord log (tail):"
  "${KUBECTL[@]}" logs deployment/coordinator --tail=60
  exit 1
fi

log "waiting for the segment to be queryable"
for _ in $(seq 1 150); do
  result="$(curl -s -X POST -H 'Content-Type: application/json' --data-binary '{"query":"SELECT page, SUM(added) AS added FROM k8s_smoke GROUP BY page ORDER BY page"}' http://127.0.0.1:30082/druid/v2/sql 2>/dev/null || true)"
  if echo "$result" | grep -q Kubernetes; then
    break
  fi
  sleep 2
done
echo "Query result: $result"
echo "$result" | grep -q '"page":"Kubernetes","added":5' && log "k8s smoke test passed" || { log "k8s smoke test FAILED: unexpected query result"; exit 1; }
