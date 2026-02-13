# MULTI-STAGE QUERY (MSQ) MODULE

Distributed DAG execution engine for long-running SQL queries and SQL-based ingestion (`INSERT`/`REPLACE`). Runs as Druid indexing tasks.

## STRUCTURE

```
multi-stage-query/src/main/java/org/apache/druid/msq/
├── exec/               # ControllerImpl, WorkerImpl — execution core
├── kernel/             # QueryDefinition, StageDefinition, WorkOrder
│   ├── controller/     # ControllerQueryKernel (DAG state machine)
│   └── worker/         # WorkerStageKernel (per-stage state)
├── indexing/           # MSQControllerTask, MSQWorkerTask (Druid task wrappers)
│   └── error/          # MSQFault types: structured error reporting (45 files)
├── querykit/           # QueryKit: translates native queries → MSQ stages
├── shuffle/            # ShuffleSpec: Hash, GlobalSort, Mix
├── statistics/         # ClusterByStatisticsCollector (range partitioning)
├── input/              # InputSlice, InputSliceReader (stage inputs)
├── sql/                # MSQTaskSqlEngine: SQL→MSQ integration
└── counters/           # Execution metrics and progress tracking
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Controller logic | `exec/ControllerImpl.java` | 3001 lines. Planning, worker mgmt, fault recovery |
| Worker logic | `exec/WorkerImpl.java` | Processes WorkOrders, runs stage processors |
| DAG state machine | `kernel/controller/ControllerQueryKernel.java` | Stage lifecycle transitions |
| Error handling | `indexing/error/` | 45 fault types. All MSQ errors are structured |
| SQL integration | `sql/MSQTaskSqlEngine.java` | Entry via `/druid/v2/sql/task` |
| Query translation | `querykit/` | Converts native Query → MSQ StageDefinition |

## EXECUTION MODEL

1. **Planning**: SQL → native query → `QueryDefinition` (DAG of `StageDefinition`s) via `QueryKit`
2. **Assignment**: Controller splits input → `WorkOrder` per worker per stage
3. **Execution**: Workers process frames (binary row format), shuffle to downstream stages
4. **Shuffle types**: `HASH` (key partitioning), `GLOBAL_SORT` (range via stats collection), `MIX` (unsorted)
5. **Output**: Druid segments (`DataSourceMSQDestination`), external export, or direct results

## FAULT TOLERANCE

- **Durable shuffle storage**: Workers write shuffle data to S3/HDFS/GCS, enabling recovery after worker failure
- **Worker relaunch**: `RetryCapableWorkerManager` relaunches failed workers
- **Stage retries**: `ControllerQueryKernel` can rollback and retry specific DAG stages

## CONVENTIONS

- MSQ tasks run as `query_controller` / `query_worker` task types in the indexing service
- All data exchange uses binary **Frame** format — optimized for memory-mapping, zero-copy
- Errors are always structured `MSQFault` objects — never raw exceptions to users
- Check `docs/multi-stage-query/known-issues.md` before extending MSQ functionality
