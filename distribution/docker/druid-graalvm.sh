#!/bin/sh

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

# Entrypoint for the GraalVM native-image build of Apache Druid.
#
# Usage:  /druid.sh <service> [extra-args...]
#
# This script mirrors the behaviour of the standard druid.sh entrypoint:
#   - copies config to /tmp/conf so root-fs can be read-only
#   - supports DRUID_SINGLE_NODE_CONF, DRUID_CONFIG_COMMON, DRUID_CONFIG_<svc>
#   - maps druid_* env vars to druid.* system properties
#   - maps s3service_* env vars to jets3t.properties (unused by native, but
#     kept for compatibility)
#   - honours ZOOKEEPER and DRUID_SET_HOST_IP env vars
#   - honours DRUID_LOG_LEVEL / DRUID_LOG4J / service-level log overrides
#   - creates standard work directories
#
# Unlike the JVM entrypoint the native binary receives properties as -D flags
# on the command line.  GraalVM native images process -Dkey=value arguments
# and set them as System properties before entering main().
#
# JVM-specific tunables (DRUID_XMX, DRUID_XMS, DRUID_MAXNEWSIZE, etc.) are
# intentionally ignored — they have no meaning for a native image.

set -e

SERVICE="$1"

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service> [args...]" >&2
  exit 1
fi

shift

echo "$(date -Is) startup service $SERVICE"

# ------------------------------------------------------------------
# 1.  Prepare configuration under /tmp/conf (writable overlay)
# ------------------------------------------------------------------
mkdir -p /tmp/conf/
test -d /tmp/conf/druid && rm -r /tmp/conf/druid
cp -r /opt/druid/conf/druid /tmp/conf/druid

getConfPath() {
    if [ -n "$DRUID_SINGLE_NODE_CONF" ]; then
      getSingleServerConfPath "$1"
    else
      getClusterConfPath "$1"
    fi
}
getSingleServerConfPath() {
    cluster_conf_base=/tmp/conf/druid/single-server
    case "$1" in
    _common) echo $cluster_conf_base/$DRUID_SINGLE_NODE_CONF/_common ;;
    historical) echo $cluster_conf_base/$DRUID_SINGLE_NODE_CONF/historical ;;
    middleManager) echo $cluster_conf_base/$DRUID_SINGLE_NODE_CONF/middleManager ;;
    coordinator|overlord) echo $cluster_conf_base/$DRUID_SINGLE_NODE_CONF/coordinator-overlord ;;
    broker) echo $cluster_conf_base/$DRUID_SINGLE_NODE_CONF/broker ;;
    router) echo $cluster_conf_base/$DRUID_SINGLE_NODE_CONF/router ;;
    *) echo $cluster_conf_base/misc/$1 ;;
    esac
}
getClusterConfPath() {
    cluster_conf_base=/tmp/conf/druid/cluster
    case "$1" in
    _common) echo $cluster_conf_base/_common ;;
    historical) echo $cluster_conf_base/data/historical ;;
    middleManager) echo $cluster_conf_base/data/middleManager ;;
    indexer) echo $cluster_conf_base/data/indexer ;;
    coordinator|overlord) echo $cluster_conf_base/master/coordinator-overlord ;;
    broker) echo $cluster_conf_base/query/broker ;;
    router) echo $cluster_conf_base/query/router ;;
    *) echo $cluster_conf_base/misc/$1 ;;
    esac
}

COMMON_CONF_DIR=$(getConfPath _common)
SERVICE_CONF_DIR=$(getConfPath ${SERVICE})

# ------------------------------------------------------------------
# 2.  Overlay user-supplied config files (ConfigMaps, bind-mounts, …)
# ------------------------------------------------------------------
setKey() {
    service="$1"
    key="$2"
    value="$3"
    service_conf=$(getConfPath $service)/runtime.properties
    # Remove existing key from both files
    sed -ri "/$key=/d" $COMMON_CONF_DIR/common.runtime.properties
    [ -f $service_conf ] && sed -ri "/$key=/d" $service_conf
    [ -f $service_conf ] && echo -e "\n$key=$value" >>$service_conf
    [ -f $service_conf ] || echo -e "\n$key=$value" >>$COMMON_CONF_DIR/common.runtime.properties

    echo "Setting $key=$value"
}

if [ -n "$DRUID_CONFIG_COMMON" ]; then
    cp -f "$DRUID_CONFIG_COMMON" $COMMON_CONF_DIR/common.runtime.properties
fi

SCONFIG=$(printf "%s_%s" DRUID_CONFIG ${SERVICE})
SCONFIG=$(eval echo \$$(echo $SCONFIG))

if [ -n "${SCONFIG}" ]; then
    if [ ! -d "$SERVICE_CONF_DIR" ]; then
      echo "Creating conf directory '$SERVICE_CONF_DIR'"
      mkdir -p $SERVICE_CONF_DIR
    fi
    cp -f "${SCONFIG}" $SERVICE_CONF_DIR/runtime.properties
fi

# ------------------------------------------------------------------
# 3.  Apply well-known environment variables
# ------------------------------------------------------------------
if [ -n "${ZOOKEEPER}" ]; then
    setKey _common druid.zk.service.host "${ZOOKEEPER}"
fi

if [ -z "${KUBERNETES_SERVICE_HOST}" ]; then
  DRUID_SET_HOST_IP=${DRUID_SET_HOST_IP:-1}
else
  DRUID_SET_HOST_IP=${DRUID_SET_HOST_IP:-0}
fi

if [ "${DRUID_SET_HOST_IP}" = "1" ]; then
    setKey $SERVICE druid.host $(ip r get 1 | awk '{print $7;exit}')
fi

# Map druid_* environment variables → property-file entries
env | grep ^druid_ | while read evar; do
    val=$(echo "$evar" | sed -e 's?[^=]*=??')
    var=$(echo "$evar" | sed -e 's?^\([^=]*\)=.*?\1?g' -e 's?__?%UNDERSCORE%?g' -e 's?_?.?g' -e 's?%UNDERSCORE%?_?g')
    setKey $SERVICE "$var" "$val"
done

# Map s3service_* → jets3t.properties (kept for compat; unused by native build)
env | grep ^s3service | while read evar; do
    val=$(echo "$evar" | sed -e 's?[^=]*=??')
    var=$(echo "$evar" | sed -e 's?^\([^=]*\)=.*?\1?g' -e 's?_?.?' -e 's?_?-?g')
    echo "$var=$val" >>$COMMON_CONF_DIR/jets3t.properties
done

# ------------------------------------------------------------------
# 4.  Log4j2 configuration overrides
# ------------------------------------------------------------------
if [ -n "$DRUID_LOG_LEVEL" ]; then
    sed -ri 's/"info"/"'$DRUID_LOG_LEVEL'"/g' $COMMON_CONF_DIR/log4j2.xml
fi

if [ -n "$DRUID_LOG4J" ]; then
    echo "$DRUID_LOG4J" >$COMMON_CONF_DIR/log4j2.xml
fi

if [ -n "$DRUID_SERVICE_LOG_LEVEL" ]; then
    sed -ri 's/"info"/"'$DRUID_SERVICE_LOG_LEVEL'"/g' $SERVICE_CONF_DIR/log4j2.xml
fi

if [ -n "$DRUID_SERVICE_LOG4J" ]; then
    echo "$DRUID_SERVICE_LOG4J" >$SERVICE_CONF_DIR/log4j2.xml
fi

# ------------------------------------------------------------------
# 5.  Create work directories
# ------------------------------------------------------------------
DRUID_DIRS_TO_CREATE=${DRUID_DIRS_TO_CREATE-'var/tmp var/druid/segments var/druid/indexing-logs var/druid/task var/druid/hadoop-tmp var/druid/segment-cache'}
if [ -n "${DRUID_DIRS_TO_CREATE}" ]; then
    mkdir -p ${DRUID_DIRS_TO_CREATE}
fi

# ------------------------------------------------------------------
# 6.  Build property files into a working directory the binary can
#     find via PropertiesModule's filesystem fall-back.
#
#     PropertiesModule tries ClassLoader.getSystemResourceAsStream()
#     first (baked-in at native-image build time) then falls back to:
#       new File(System.getProperty("druid.properties.file", <name>))
#     which for a relative <name> resolves against $PWD.
#
#     We symlink the two expected filenames into a tmp workdir so the
#     native binary can discover them.
# ------------------------------------------------------------------
RUN_DIR=/tmp/druid-run
mkdir -p "$RUN_DIR"
ln -sf "$COMMON_CONF_DIR/common.runtime.properties" "$RUN_DIR/common.runtime.properties"
if [ -f "$SERVICE_CONF_DIR/runtime.properties" ]; then
    ln -sf "$SERVICE_CONF_DIR/runtime.properties" "$RUN_DIR/runtime.properties"
else
    touch "$RUN_DIR/runtime.properties"
fi

# Also make log4j2.xml discoverable
if [ -f "$COMMON_CONF_DIR/log4j2.xml" ]; then
    ln -sf "$COMMON_CONF_DIR/log4j2.xml" "$RUN_DIR/log4j2.xml"
fi

cd "$RUN_DIR"

# ------------------------------------------------------------------
# 7.  Exec the native binary
# ------------------------------------------------------------------
# The native binary is a GraalVM-compiled image of org.apache.druid.cli.Main.
# -D flags are processed by the SubstrateVM runtime and set as System
# properties before entering main(); they do NOT appear in args[].
# Extensions are baked into the classpath (ServiceLoader discovery via
# searchCurrentClassloader=true).  Disable filesystem-based extension loading.
exec /opt/druid/bin/druid \
  -Ddruid.node.type=$SERVICE \
  '-Ddruid.extensions.loadList=[]' \
  -Ddruid.extensions.searchCurrentClassloader=true \
  -Ddruid.extensions.directory=/nonexistent \
  server $SERVICE $@
