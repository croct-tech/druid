# APACHE DRUID — PROJECT KNOWLEDGE BASE

**Generated:** 2025-02-13 | **Commit:** e3b8e7cb66 | **Branch:** fix-stream-disconnect

## OVERVIEW

Apache Druid — high-performance real-time analytics database. Java 17/21 Maven monorepo with ~9K Java files, ~340K source lines. Guice DI throughout. Extension-heavy plugin architecture.

## STRUCTURE

```
druid/
├── processing/         # Core engine: queries, segments, expressions, data input (2496 main files)
├── server/             # Cluster mgmt: coordination, discovery, HTTP, metadata (855 main)
├── sql/                # SQL layer: Calcite integration, planning, native conversion (376 main)
├── indexing-service/   # Ingestion: task mgmt, streaming/batch supervisors (406 main)
├── multi-stage-query/  # MSQ: distributed DAG execution engine (440 main)
├── services/           # CLI entry point: org.apache.druid.cli.Main (58 main)
├── web-console/        # React/TypeScript management UI (Blueprint.js, Zustand)
├── extensions-core/    # 30 official plugins: S3, Kafka, DataSketches, security, etc.
├── extensions-contrib/ # 35 community plugins: Prometheus, Redis, Delta Lake, etc.
├── embedded-tests/     # Cross-module integration tests
├── benchmarks/         # JMH performance benchmarks
├── indexing-hadoop/    # Legacy Hadoop ingestion (maintenance only)
├── docs/               # Docusaurus 3 documentation (published to druid.apache.org)
├── integration-tests/  # Docker-based TestNG integration tests
├── integration-tests-ex/ # Extended/revised integration test suite
├── codestyle/          # Checkstyle, PMD, forbidden-apis, SpotBugs configs
├── dev/                # Developer tools: style guide, IDE configs, scripts
└── distribution/       # Release packaging and assembly
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Entry point (all processes) | `services/.../cli/Main.java` | Airline CLI: `server coordinator`, `server broker`, etc. |
| Add a query type | `processing/.../query/` | Implement `Query<T>` + `QueryToolChest` + `QueryRunnerFactory` |
| Add an aggregation | `processing/.../query/aggregation/` | Implement `AggregatorFactory` + `BufferAggregator` |
| Add a SQL function | `sql/.../expression/builtin/` | Implement `SqlOperatorConversion` |
| Add an expression function | `processing/.../math/expr/Function.java` | Add inner class implementing `Function` |
| Add a new extension | `extensions-core/` or `extensions-contrib/` | Implement `DruidModule`, register via SPI in `META-INF/services/` |
| Add ingestion source | `processing/.../data/input/` | Implement `InputSource` + `InputFormat` |
| Segment internals | `processing/.../segment/` | `Segment`, `CursorFactory`, `QueryableIndex`, `Cursor` |
| MSQ execution | `multi-stage-query/.../msq/exec/` | `ControllerImpl`, `WorkerImpl` |
| SQL planning | `sql/.../calcite/planner/DruidPlanner.java` | Parse → validate → plan → convert |
| Web console | `web-console/src/views/` | Blueprint.js views, Zustand stores |
| Build configs | `codestyle/` | `checkstyle.xml`, `druid-forbidden-apis.txt`, `pmd-ruleset.xml` |
| CI workflows | `.github/workflows/` | `unit-and-integration-tests-unified.yml` is main entry |

## CONVENTIONS

### Java Style (Checkstyle-enforced)
- **Braces**: Classes/methods → opening brace on **new line**. Control flow (`if`/`for`/`try`) → **end of line**
- **Indent**: 2 spaces, no tabs
- **Imports**: No star imports, no static imports. Order: `*`, then `javax`, then `java` (separated)
- **No `@author` tags** in Javadoc — Checkstyle rejects them
- **Comments on classes/methods must be Javadoc** (`/** */`), not block comments (`/* */`)
- **Method names**: `camelCase` starting lowercase. Variables same
- **Constants**: `UPPER_SNAKE_CASE` (exception: `log`/`logger`)
- **Packages**: Must be under `org.apache.druid.*`

### Logging (see `dev/style-conventions.md`)
- Interpolated values MUST use `[value]` format: `"Filter [%s] on column [%s] cannot be applied to type [%s]"`
- Messages must read as sentences even with interpolations removed
- INFO+ and Exceptions must NEVER leak secrets or data content

### Forbidden APIs (`codestyle/druid-forbidden-apis.txt`)
- Use `java.util.HashMap` directly, NOT `Maps.newHashMap()` (but use `Maps.newHashMapWithExpectedSize(int)` for sized)
- Use `java.util.ArrayList` directly, NOT `Lists.newArrayList()`
- Use `StandardCharsets`, NOT `Charsets`
- Use `ThreadLocalRandom.current()`, NOT `new Random()` or `Math.random()`
- Use `FileUtils.mkdirp()`, NOT `File.mkdirs()`
- Use `Execs.multiThreaded()`, NOT `Executors.newFixedThreadPool()`
- Use `JacksonUtils.writeObjectUsingSerializerProvider()`, NOT `ObjectMapper.writeValue(JsonGenerator,...)`
- Use `primitive.class`, NOT `Wrapper.TYPE`
- Use `String.startsWith()/endsWith()/contains()` or cached Pattern, NOT `String.matches()/replaceAll()`
- No `LinkedList` — use `ArrayList` or `ArrayDeque`
- No `Throwables.propagate()` in new code
- No Powermock — use Mockito
- `"string".equals(var)`, NOT `var.equals("string")`
- `toArray(new Object[0])`, NOT `toArray(new Object[n])`

### Checkstyle-specific Traps
- Suppress inline: `// CHECKSTYLE.OFF: RuleName` / `// CHECKSTYLE.ON: RuleName`
- `Float.MAX_VALUE` → use `Float.POSITIVE_INFINITY`
- `Double.MAX_VALUE` → use `Double.POSITIVE_INFINITY`
- `Ordering.natural().nullsFirst()` → use `Comparators.naturalNullsFirst()`
- No IntelliJ-style `//  ` (double-space) commented code
- No `instanceof` on `ObjectColumnSelector`/`LongColumnSelector`/`FloatColumnSelector`/`DoubleColumnSelector`

### Multi-line Arguments
If a method call/declaration doesn't fit one line (<120 cols), each argument goes on its own line. Exception: map-like pairs.

## ANTI-PATTERNS (THIS PROJECT)

- **Never `equals()`/`hashCode()` on `SegmentCreateRequest`** — each instance must be identity-unique
- **Never use `TaskResourceFilter` at MiddleManager** — `TaskStorageQueryAdapter` can't be injected there
- **Always cancel K8s watchers explicitly** — `cancelJobWatcher()`/`cancelPodWatcher()` or resource leak
- **Never use Calcite `OperandTypes.LITERAL`** — throws on CAST literals. Use `DefaultOperandTypeChecker`
- **Never use `datasketches-memory` `Memory.wrap(byte[],int,int,ByteOrder)`** — broken in v2.2.0
- **Never use `EmbeddedMiddleManager`** in non-local tests — use `EmbeddedIndexer` instead

## COMMANDS

```bash
# Full build
mvn clean install -Pdist -DskipTests

# Fast build (skip all checks)
mvn clean install -Pdist -T1C -DskipTests -Dforbiddenapis.skip=true \
  -Dcheckstyle.skip=true -Dpmd.skip=true -Dmaven.javadoc.skip=true -Denforcer.skip=true

# Run unit tests
mvn test

# Run integration tests (Docker-based)
./it.sh

# Web console dev
cd web-console && npm install && npm start   # proxies to localhost:8888
cd web-console && npm run autofix            # lint + format

# Install git hooks (checkstyle pre-commit)
./hooks/install-hooks.sh

# Build docs site
cd website && npm install && npm start
```

## TESTING

- **Unit tests**: JUnit 4/5 (transitioning to 5), `*Test.java` suffix, `src/test/java/`
- **Integration tests**: TestNG, `IT*.java` prefix, `integration-tests/` module, Docker-based via `./it.sh`
- **SQL tests**: Quidem framework, `.iq` files in `sql/src/test/quidem/` and `quidem-ut/`
- **Frontend tests**: Jest + snapshot tests, `npm test` in `web-console/`
- **Mocking**: Mockito preferred (EasyMock legacy exists). No Powermock
- **Coverage**: JaCoCo enforced. Use IntelliJ JaCoCo runner for branch coverage

## NOTES

- JDK 17 or 21 required to build. IntelliJ SDK must be named `1.8` (alias only — see `dev/intellij-setup.md`)
- `-Pdist` is required for first build — populates `distribution/target/extensions/`
- `-Dweb.console.skip=true` saves significant build time for backend-only work
- Calcite SQL parser is **forked into the project** (`dev/upgrade-calcite-parser`) — not a stock dependency
- Dual integration test suites: `integration-tests/` (legacy) and `integration-tests-ex/` (newer)
- DI is Google Guice everywhere. Extensions register via `DruidModule` → Guice `Multibinder`/`MapBinder`
- Extension discovery uses Java SPI: `META-INF/services/org.apache.druid.initialization.DruidModule`
- Jackson polymorphism via `@JsonTypeName` — extensions register subtypes in `getJacksonModules()`
- `known-issues.md` files exist for MSQ, Window Functions, and Nested Columns — check before extending
