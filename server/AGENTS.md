# SERVER MODULE

Cluster management, coordination, discovery, HTTP endpoints, metadata storage. Orchestration layer between processing engine and network.

## STRUCTURE

```
server/src/main/java/org/apache/druid/
├── client/             # CachingClusteredClient, DirectDruidClient (inter-node RPC)
├── metadata/           # SQL metadata storage: segments, tasks, supervisors
├── server/             # Jetty HTTP, Router, security filters
│   └── http/           # REST endpoints, HttpMediaType
├── segment/            # Segment loading, caching, announcements
│   └── realtime/       # Real-time ingestion: appenderators
├── discovery/          # Node discovery, NodeRole, DruidNodeDiscovery
├── curator/            # ZooKeeper integration via Apache Curator
├── initialization/     # Extension loading, Guice module setup
├── guice/              # Server-specific Guice modules
└── indexing/overlord/  # Segment allocation, SegmentCreateRequest
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Segment metadata CRUD | `metadata/IndexerSQLMetadataStorageCoordinator.java` | 2822 lines. Allocation, publishing |
| Segment metadata queries | `metadata/SqlSegmentsMetadataQuery.java` | 2046 lines. JDBI-based queries |
| Inter-node communication | `client/CachingClusteredClient.java` | Query fanout to historicals |
| Real-time data buffering | `segment/realtime/appenderator/StreamAppenderator.java` | 1834 lines. Persistence, handoff |
| REST endpoints | `server/http/` | Resource classes, media types |
| Node discovery | `discovery/DruidNodeDiscovery.java` | How nodes find each other |
| Extension loading | `initialization/ExtensionsLoader.java` | SPI + classloader isolation |

## ANTI-PATTERNS

- **Never `equals()`/`hashCode()` on `SegmentCreateRequest`** — identity-unique by design
- **`StreamAppenderator` WARN_DELAY** — 1000ms threshold for persist operations. Hardcoded perf indicator
- **Deprecated endpoints** in `DataSourcesResource`, `QueryResource` — use newer API versions
- **`@Produces("text/plain")`** forbidden — use `HttpMediaType.TEXT_PLAIN_UTF8`

## CONVENTIONS

- HTTP resources use Jersey annotations. Security via `ResourceFilter` + `AuthorizationUtils`
- Metadata operations use JDBI for SQL, wrapped in Druid's `MetadataStorageConnector`
- Node roles defined as static constants in `NodeRole` — always use built-in roles for known components
