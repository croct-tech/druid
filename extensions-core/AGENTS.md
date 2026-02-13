# EXTENSIONS-CORE

30 officially supported Druid extensions. Plugin architecture via Java SPI + Guice + Jackson polymorphism.

## EXTENSION ARCHITECTURE

1. **Discovery**: Java SPI — `META-INF/services/org.apache.druid.initialization.DruidModule`
2. **Wiring**: `DruidModule` extends `com.google.inject.Module`. Use `Multibinder`/`MapBinder`
3. **Serialization**: `@JsonTypeName("type-name")` + register subtypes in `getJacksonModules()`

## EXTENSION LIST

| Extension | Purpose |
|-----------|---------|
| `s3-extensions` | Amazon S3 deep storage, input source |
| `google-extensions` | GCS deep storage, input source |
| `azure-extensions` | Azure Blob deep storage, input source |
| `hdfs-storage` | HDFS deep storage |
| `kafka-indexing-service` | Real-time Kafka ingestion |
| `kinesis-indexing-service` | Real-time Kinesis ingestion |
| `datasketches` | Approximate algorithms (HLL, Theta, Quantiles, KLL) |
| `druid-basic-security` | Basic auth + RBAC via metadata store |
| `druid-bloom-filter` | Bloom filter query filters |
| `mysql-metadata-storage` | MySQL metadata store connector |
| `postgresql-metadata-storage` | PostgreSQL metadata store connector |
| `avro-extensions` | Avro input format |
| `parquet-extensions` | Parquet input format |
| `orc-extensions` | ORC input format |
| `protobuf-extensions` | Protobuf input format |
| `lookups-cached-global` | Distributed cached lookups (JDBC, URI) |
| `lookups-cached-single` | Single-node lookup caching |
| `druid-kerberos` | Kerberos authentication |
| `druid-pac4j` | OpenID Connect / OAuth2 authentication |
| `druid-catalog` | Table catalog metadata |
| `kubernetes-extensions` | K8s node discovery |
| `kubernetes-overlord-extensions` | K8s-based task execution (pods as workers) |
| `histogram` | Approximate histogram aggregation |
| `stats` | Variance/standard deviation aggregation |
| `kafka-extraction-namespace` | Kafka-backed lookup namespaces |
| `ec2-extensions` | EC2 auto-scaling |
| `druid-aws-rds-extensions` | AWS RDS token-based auth |
| `simple-client-sslcontext` | SSL/TLS client configuration |
| `testing-tools` | Test infrastructure (ClusterTestingModule) |
| `druid-testcontainers` | Testcontainers integration for ITs |

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| New extension | Copy structure from existing | `pom.xml` + `DruidModule` + SPI file |
| Storage extension | `s3-extensions/` as reference | Implement `DataSegmentPusher`, `DataSegmentKiller` |
| Ingestion extension | `kafka-indexing-service/` as reference | Extend `SeekableStreamSupervisor` |
| Auth extension | `druid-basic-security/` as reference | Implement `Authenticator`, `Authorizer` |
| Aggregation extension | `datasketches/` as reference | Implement `AggregatorFactory` |
| Input format | `avro-extensions/` as reference | Implement `InputFormat` |

## CONVENTIONS

- Each extension is a standalone Maven module with own `pom.xml`
- `extensions-contrib/` follows identical pattern for community extensions (35 modules)
- K8s extensions: **always cancel watchers explicitly** — `cancelJobWatcher()`/`cancelPodWatcher()`
- DataSketches: **never use `Memory.wrap(byte[],int,int,ByteOrder)`** — broken in v2.2.0
