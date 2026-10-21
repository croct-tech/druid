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

# Compiles the Druid native binary.
#
#   build-native-image.sh <lib-dir> <config-dirs> <output-binary> [native-image options...]
#
# <lib-dir> holds the flat class path assembled by NativeImageBuildTool collect, <config-dirs> is a comma-separated
# list of directories with reachability metadata (reflect-config.json and friends). Extra options are appended to
# the native-image command line, e.g. -J-Xmx12g to size the builder heap.

set -euo pipefail

LIB_DIR="$1"
CONFIG_DIRS="$2"
OUTPUT="$3"
shift 3

ARGS_FILE="$(mktemp)"
trap 'rm -f "$ARGS_FILE"' EXIT

{
  echo "-cp"
  # A fixed, sorted order keeps the build reproducible when jars contain the same class.
  find "$LIB_DIR" -name '*.jar' | sort | paste -sd ':' -
  echo "-o"
  echo "$OUTPUT"
  echo "--no-fallback"
  echo "--enable-url-protocols=http,https"
  echo "--install-exit-handlers"
  echo "--enable-monitoring=heapdump"
  echo "--add-modules=jdk.incubator.vector"
  # Same strong encapsulation exceptions as bin/run-java and ForkingTaskRunner.
  echo "--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED"
  echo "--add-exports=java.base/jdk.internal.ref=ALL-UNNAMED"
  echo "--add-opens=java.base/java.nio=ALL-UNNAMED"
  echo "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED"
  echo "--add-opens=java.base/jdk.internal.ref=ALL-UNNAMED"
  echo "--add-opens=java.base/java.io=ALL-UNNAMED"
  echo "--add-opens=java.base/java.lang=ALL-UNNAMED"
  echo "--add-opens=jdk.management/com.sun.management.internal=ALL-UNNAMED"
  echo "-H:+UnlockExperimentalVMOptions"
  echo "-H:+ReportExceptionStackTraces"
  echo "-H:+AddAllCharsets"
  echo "-H:ConfigurationFileDirectories=$CONFIG_DIRS"
} > "$ARGS_FILE"

echo "native-image arguments:"
sed 's/^/  /' "$ARGS_FILE" | cut -c1-200
echo "  $*"

exec native-image "@$ARGS_FILE" "$@" org.apache.druid.cli.Main
