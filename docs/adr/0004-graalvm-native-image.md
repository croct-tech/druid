---
Status: accepted
Upstream: fork-only
---

# The Docker image runs Druid as a GraalVM native image

Our Druid cluster runs many small services and peons, and the JVM's fixed per-process cost (JIT compiler, metaspace,
class loading, GC bookkeeping) dominated their memory footprint. `distribution/docker/Dockerfile.native` compiles
`org.apache.druid.cli.Main` with GraalVM native-image (GraalVM Community for JDK 25) into one executable,
`/opt/druid/bin/druid`, and ships it in the same layout as the JVM image: `druid.sh` and `peon.sh` are unchanged,
configuration lives in `/opt/druid/conf`, and `druid_*` environment variables work as before. Only `bin/run-java`
differs: it is a shim (`distribution/docker/native/run-java`) that accepts the JVM command line produced by
`druid.sh`, `peon.sh` and `ForkingTaskRunner` and translates it for the native binary, so middleManagers fork native
peons and the Kubernetes task runner launches native peon pods without configuration changes.

Extensions are compiled in at build time (`DRUID_NATIVE_EXTENSIONS`); nothing is loaded from the file system. The
default set is the one our cluster runs: `druid-basic-security`, `postgresql-metadata-storage`,
`druid-kafka-indexing-service`, `druid-google-extensions`, `druid-lookups-cached-global`, `druid-avro-extensions`,
`druid-datasketches`, `druid-moving-average-query`, `druid-time-min-max`, `druid-stats`,
`druid-kubernetes-overlord-extensions` and `prometheus-emitter`. All compiled-in extension modules are always
active, found through the class path like Druid's embedded tests do, and the image keeps an empty `extensions/<name>`
directory for each so that `druid.extensions.loadList` keeps validating. Reachability metadata comes from three
sources: the build scans every jar and registers all Druid classes, all service providers and the libraries known to
load classes by name (`NativeImageBuildTool`), it runs a small cluster on a JVM with the GraalVM tracing agent and
records what the services, peons, queries, lookups, supervisors and APIs touch (`trace.sh`), and a short hand-written
list covers JDK classes Jackson instantiates.

Two code changes make this possible, both neutral on a JVM:

- `PropertiesModule` also searches the directories on `java.class.path` for `common.runtime.properties` and
  `runtime.properties`. The JVM's system class loader already serves those directories, so this only matters in the
  native image, where the shim passes the `-cp` value as `java.class.path`.
- Calcite normally generates Java code with Janino while planning (metadata handlers) and while executing Bindable
  plans, which answer `sys` and `INFORMATION_SCHEMA` queries. A native image cannot define classes at run time, so
  when `RuntimeCodeGeneration.isAvailable()` is false (inside a native image, or with
  `druid.sql.calcite.runtimeCodeGeneration=false`) the planner answers metadata queries through Calcite's
  `ProxyingMetadataHandlerProvider`, and Bindable plans run on `DruidInterpreter`, a copy of Calcite's interpreter
  whose expressions are translated to Druid expressions instead of compiled with Janino.

Run-time class generation is otherwise disabled: the shim sets `fakeSpecialize=true` (no monomorphic query-processing
specialization) and `guice_bytecode_gen_option=DISABLED`.

The build is heavy. The class path of Druid plus these extensions reaches roughly 100,000 types and 600,000 methods,
and the image builder's default points-to analysis never finished on a 16 GB machine, however it was constrained. The
build therefore uses GraalVM's reachability analysis (`-H:+UseExperimentalReachabilityAnalysis`), which is faster and
needs less memory at the price of keeping more code, gives the builder a 64 GB heap by default (`NATIVE_IMAGE_XMX`),
and runs in CI on the `croct-custom-32` runner (32 cores, 128 GB). The `Native image` workflow builds the image on
pull requests that touch the native build, runs the benchmark workload (`distribution/docker/native/bench`) against it
and against the JVM image built from the same tarball, smoke-tests the Kubernetes task runner on a k3s cluster, and
publishes the reports in the job summary. The `Release` workflow (ADR-0003) builds both images on the same runner and
pushes `<version>` (JVM) and `<version>-native`. Its `deploy` input picks which of the two is reported to the
deployment service; the default is the native image.

## Consequences

- No extension can be added at run time; changing the set means rebuilding the image. `DRUID_ADDITIONAL_CLASSPATH`
  may only hold configuration directories.
- Every compiled-in extension module is active on every service, whatever `druid.extensions.loadList` says. Most
  modules only register types, but `druid-kubernetes-overlord-extensions` makes `k8s` the default
  `druid.indexer.runner.type`, so an overlord that should fork or use middleManagers must set
  `druid.indexer.runner.type=httpRemote` explicitly.
- JVM options have no effect beyond heap sizing: `-Xmx`, `-Xms`, `-XX:MaxDirectMemorySize`, `-XX:ActiveProcessorCount`
  and `-XX:+ExitOnOutOfMemoryError` are honoured, everything else is dropped with a warning. The garbage collector is
  GraalVM's serial collector, fixed at build time; `-XX:+UseG1GC` and friends are ignored. Without `-Xmx` the native
  runtime takes 80% of the container's memory for the heap, so always size the heap.
- JavaScript (`druid.javascript.enabled`) does not work: the GraalVM JavaScript engine jars clash with the native
  image builder and are left out. Monitors that depend on JNA (`OshiSysMonitor`) are untested.
- Expressions in `sys` and `INFORMATION_SCHEMA` queries are evaluated by Druid's expression engine in the native
  image, so an expression the planner cannot translate to a Druid expression fails there with an "unsupported" error,
  while a JVM would still evaluate it through Calcite.
- The image cannot be built on a developer machine with 16 GB of memory. The `Native image` workflow is filtered to
  the files of the native build, so it is not a required check; a change elsewhere that breaks the native image shows
  up in the next release build, or in a manual run of the workflow.
- Upstream syncs: keep the two code changes, re-check `distribution/docker/native/*` against changes to `druid.sh`,
  `peon.sh`, `ForkingTaskRunner` and `bin/run-java`, and rebuild the image; new reflection in upstream code is picked
  up automatically by the class path scan and the trace, but new libraries that load classes by name may need an entry
  in the `--reflect-package` list of the Dockerfile.
