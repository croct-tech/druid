<!--
  ~ Licensed to the Apache Software Foundation (ASF) under one
  ~ or more contributor license agreements.  See the NOTICE file
  ~ distributed with this work for additional information
  ~ regarding copyright ownership.  The ASF licenses this file
  ~ to you under the Apache License, Version 2.0 (the
  ~ "License"); you may not use this file except in compliance
  ~ with the License.  You may obtain a copy of the License at
  ~
  ~   http://www.apache.org/licenses/LICENSE-2.0
  ~
  ~ Unless required by applicable law or agreed to in writing,
  ~ software distributed under the License is distributed on an
  ~ "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
  ~ KIND, either express or implied.  See the License for the
  ~ specific language governing permissions and limitations
  ~ under the License.
  -->

## Build

From the root of the repo, run following command:

```bash
DOCKER_BUILDKIT=1 docker build -t apache/druid:tag -f distribution/docker/Dockerfile .
```

### Building images on Apple M1/M2
To build images on Apple M1/M2, you need to follow the instructions in this section.

1. build Druid distribution from the root of the repo
   ```bash
   mvn clean package -DskipTests -Pdist
   ```
2. build target image
   ```
   DOCKER_BUILDKIT=1 docker build -t apache/druid:tag -f distribution/docker/Dockerfile --build-arg BUILD_FROM_SOURCE=false .
   ```

## Run

1. Edit `distribution/docker/docker-compose.yml` file to change the tag of Druid's images to the tag that's used in the 'Build' phase above.
2. Edit `environment` file to suite if necessary.
3. Run:
    ```bash
    docker compose -f distribution/docker/docker-compose.yml up
    ```

## MySQL Database Connector

This image contains solely the postgres metadata storage connector. If you
need the mysql metadata storage connector, you can use Dockerfile.mysql to add
it to the base image above.

```bash
docker build -t apache/druid:tag-mysql --build-arg DRUID_RELEASE=apache/druid:tag -f distribution/docker/Dockerfile.mysql .
```

where `druid:tag` is the version of Druid image to use as the base.

## Native image (GraalVM)

`Dockerfile.native` compiles Druid and a fixed set of extensions into one GraalVM native binary and ships it in the
same layout as the JVM image, so `druid.sh`, `peon.sh`, the configuration directories and the `druid_*` environment
variables work unchanged. The design and its trade-offs are described in `docs/adr/0004-graalvm-native-image.md`.

```bash
# from source (slow: builds the distribution, records reachability metadata from a running cluster, compiles)
DOCKER_BUILDKIT=1 docker build -t druid:native -f distribution/docker/Dockerfile.native .

# from a distribution tarball already built with `mvn install -Pdist,bundle-contrib-exts`
DOCKER_BUILDKIT=1 docker build -t druid:native -f distribution/docker/Dockerfile.native --build-arg BUILD_FROM_SOURCE=false .
```

Build arguments:

- `DRUID_NATIVE_EXTENSIONS`: space-separated extension directory names to compile in. Everything else is unavailable
  at run time. When two extensions ship different versions of the same library, the one listed first wins.
- `NATIVE_IMAGE_XMX`: heap of the native-image builder (default `64g`). The analysis does not fit in 16 GB; CI builds
  the image on a 32-core, 128 GB runner (`.github/workflows/native-image.yml`).
- `NATIVE_IMAGE_OPTS`: extra `native-image` options, for example `-march=x86-64-v4`.
- `GRAALVM_IMAGE`: the builder image (default GraalVM Community for JDK 25).

The files under `native/` are the pieces of the build: `run-java` is the launcher shim installed as `bin/run-java`,
`NativeImageBuildTool.java` assembles the class path and the reflection metadata, `trace.sh` records metadata from a
running cluster with the GraalVM tracing agent, and `build-native-image.sh` runs the compiler. `native/bench/` holds
a compose file with every service type plus ZooKeeper, PostgreSQL and Kafka, a benchmark script that runs the same
ingestion and query workload against any image and reports memory, start-up time and query latency, and a smoke test
that runs an ingestion task through the Kubernetes task runner on a single-node k3s cluster. The `Native image`
workflow runs all three on pull requests that touch the native build and publishes the reports in the job summary.
