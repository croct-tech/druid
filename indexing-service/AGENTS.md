# INDEXING-SERVICE MODULE

Data ingestion: task management, streaming/batch supervisors, Overlord/MiddleManager coordination. Manages the lifecycle of data loading into Druid.

## STRUCTURE

```
indexing-service/src/main/java/org/apache/druid/indexing/
├── common/
│   ├── task/               # Task implementations: IndexTask, CompactionTask
│   │   └── batch/parallel/ # Parallel batch indexing (53 files)
│   └── actions/            # TaskAction: segment allocation, publishing
├── overlord/               # Overlord: task scheduling, assignment, locking
│   ├── hrtr/               # HttpRemoteTaskRunner (HTTP-based task management)
│   └── http/security/      # Task security filters
├── seekablestream/         # Streaming ingestion framework (Kafka/Kinesis)
│   └── supervisor/         # SeekableStreamSupervisor: offset tracking, task creation
└── worker/                 # MiddleManager/Indexer worker logic
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Streaming ingestion | `seekablestream/supervisor/SeekableStreamSupervisor.java` | 4847 lines. THE complexity hotspot |
| Streaming task runner | `seekablestream/SeekableStreamIndexTaskRunner.java` | 2177 lines. Actual data consumption |
| Batch indexing | `common/task/IndexTask.java` | 1709 lines. Standard batch ingestion |
| Parallel batch | `common/task/batch/parallel/ParallelIndexSupervisorTask.java` | 2006 lines |
| Task locking | `overlord/TaskLockbox.java` | 1864 lines. Concurrency control for segments |
| Task scheduling | `overlord/hrtr/HttpRemoteTaskRunner.java` | 1980 lines. HTTP-based task distribution |
| Compaction | `common/task/CompactionTask.java` | 1573 lines. Segment optimization |
| ZK task runner | `overlord/RemoteTaskRunner.java` | 1686 lines. Legacy ZK-based runner |

## KEY ABSTRACTIONS

- **`Task`** — unit of work. Has lifecycle: pending → running → success/failure
- **`TaskAction`** — operations tasks can perform: allocate segments, publish, lock
- **`TaskLockbox`** — concurrency control. Prevents conflicting writes to same intervals
- **`SeekableStreamSupervisor`** — manages lifecycle of streaming tasks: offset tracking, checkpointing, task groups
- **`TaskRunner`** — executes tasks on workers (`HttpRemoteTaskRunner` preferred over ZK-based `RemoteTaskRunner`)

## ANTI-PATTERNS

- **Never use `TaskResourceFilter` at MiddleManager** — `TaskStorageQueryAdapter` can't be injected there
- **Never use `EmbeddedMiddleManager`** in non-local tests — use `EmbeddedIndexer` instead
- `SeekableStreamSupervisor` is a state machine — understand state transitions before modifying

## CONVENTIONS

- Streaming extensions (Kafka, Kinesis) extend `SeekableStreamSupervisor` and `SeekableStreamIndexTask`
- Task types register via `@JsonTypeName` for Jackson polymorphism
- Parallel batch tasks use `SubTask` pattern: supervisor creates/monitors sub-tasks
