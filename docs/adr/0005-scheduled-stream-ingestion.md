---
Status: accepted
Upstream: fork-only
---

# Kafka supervisors can ingest in scheduled cycles instead of continuously

Many of our Kafka supervisors feed datasources nobody queries in real time, and their peons spend most of their life
waiting for records. We worked around it with an external script that resumes each supervisor, waits for lag to reach
zero and suspends it again every few hours. That works, but the schedule lives outside Druid, a suspended supervisor
reads as "turned off" to anyone looking at the console, and "lag is zero" never quite happens on a busy topic, so the
script stops tasks wherever they happen to be. We are building the same behaviour into the supervisor.

A Kafka supervisor spec gets an optional `ioConfig.scheduleConfig`:

```json
"scheduleConfig": { "period": "PT4H", "origin": "1970-01-01T00:15:00Z" }
```

With it, the supervisor ingests in **ingestion cycles**. A cycle starts at every `origin + k * period`. When it starts,
the supervisor records the stream's latest offset of every partition as the cycle's **target offsets**, then creates
tasks that read from the committed offsets up to the target offsets and stop there. Once every partition's committed
offset has reached its target and no task is reading or publishing, the cycle ends and the supervisor waits for the
next start, creating no tasks. A cycle with nothing to read (committed offsets already at the latest offsets) ends at
once without creating tasks.

- **Tasks are ordinary streaming tasks with concrete end offsets.** The task runner already stops at non-marker end
  offsets and `TaskGroup.endSequences` already carries them, so no task or runner code changes. `taskDuration` still
  applies: a cycle with a large backlog rolls over to new task groups as usual, and the new groups keep reading
  toward the same target offsets. Replicas and `taskCount` work as usual.
- **The datasource metadata is unchanged.** Unlike `boundedStreamConfig`, cycle tasks don't write their range to the
  datasource metadata, so each cycle's different end offsets don't trip the bounded-config mismatch check, and a
  supervisor can switch between scheduled and continuous ingestion without a reset.
- **Waiting is the `IDLE` state.** `runInternal` already creates no tasks while idle, the autoscaler notice already
  skips idle supervisors, and lag metrics are still emitted. Between cycles the supervisor is `IDLE`; during a cycle it
  goes through the usual states and is `RUNNING` when healthy.
- **The schedule is aligned to the clock, not to the previous cycle.** Start times depend only on `period` and
  `origin`, so they need no stored state and survive Overlord restarts and leader changes. `origin` defaults to the
  epoch; giving supervisors different origins staggers them so they don't all launch tasks at the same moment.
  `period` must be a fixed length (no months or years).
- **Overruns collapse.** If a cycle is still running when its next start time passes, no second cycle starts in
  parallel. When it ends, one new cycle starts immediately, however many start times it missed.
- **Restarts.** Target offsets live only in memory. After an Overlord restart the supervisor recovers them from the
  end offsets of the cycle tasks it discovers and finishes the cycle. If no cycle tasks are running, it waits for the
  next start time, and anything left over from an interrupted cycle is read then. Submitting a new spec restarts the
  supervisor the same way.
- **Partitions without committed offsets are pinned.** With `useEarliestOffset: false`, a partition with no committed
  offset starts at the stream's latest offset, which at the start of a cycle is also its target, so it would never be
  read. Between cycles, the supervisor therefore commits the latest offset of every such partition, the way the reset
  offsets API does, and the next cycle reads from there. Partitions discovered later are read from the earliest
  offset, as in continuous ingestion, and are not pinned.
- **Suspension wins.** A suspended scheduled supervisor behaves like any suspended supervisor. When resumed, it waits
  for the next start time.

The supervisor rejects `scheduleConfig` together with `boundedStreamConfig`, an enabled `idleConfig`, an enabled
`autoScalerConfig`, or `lateMessageRejectionPeriod`. Bounded and idle ingestion contradict it. The autoscaler would see
the backlog at the start of every cycle and restart all tasks to scale up. The late-message rejection period is
measured from task creation, so with a four-hour cycle it would silently drop most of the backlog. An absolute
`lateMessageRejectionStartDateTime` is still allowed.

The change lives in `SeekableStreamSupervisor`, but only `KafkaSupervisorIOConfig` accepts `scheduleConfig`. We don't
run Kinesis or RabbitMQ, and their sequence-number semantics (inclusive end offsets, shard expiry) would need their own
tests.

## Considered Options

- **Keep the external script.** No fork patch, but it keeps the problems above, and it can't stop at a precise offset:
  suspending stops tasks wherever they are.
- **Read until lag reaches zero, then stop gracefully.** This copies the script into the supervisor. Like the script,
  it ends cycles at an arbitrary offset, and on a busy topic it may never see zero lag. Target offsets give each cycle
  a defined end and let tasks stop by themselves, without the pause/set-end-offsets handshake.
- **Reuse `boundedStreamConfig` once per cycle.** Its range is stored in the datasource metadata and checked on every
  start, so every cycle would need a reset or a new supervisor ID, and `COMPLETED` is a terminal state.
- **Measure `period` from the end of the previous cycle.** This keeps the gap between cycles constant, but the
  supervisor would have to store the last end time somewhere that survives restarts. Clock alignment needs no state
  and makes start times predictable.
- **A new supervisor state for waiting.** A name like `SCHEDULED` would say more than `IDLE`, but the state enum is
  shared by every supervisor type, and the web console and anything polling `/status` would need to learn it. `IDLE`
  already means "healthy, nothing to do, no tasks".

## Consequences

- Data becomes queryable once per cycle, plus the time it takes to read the backlog. While a cycle runs, its tasks
  serve queries as usual.
- Kafka retention must exceed `period` plus the longest catch-up, or records expire before a cycle reads them, and
  the supervisor's automatic offset reset (if enabled) skips them.
- Lag grows during every wait by design. Alerts on `ingest/kafka/lag` for scheduled supervisors must allow for a
  full `period` of records.
- Every cycle pays task start-up and publishing costs, and segments are only as large as one cycle's data allows.
  Very short periods lose most of the savings.
- Cycle tasks start with a backlog, which exposes two upstream races that continuous tasks rarely hit, because both
  need a task to get far before the supervisor first discovers it (within `startDelay` of its creation). A task that
  reaches its end offsets first is filed as publishing, and the supervisor would create a second task for the same
  offsets; scheduled supervisors skip that top-up. A task that pauses for a checkpoint first (after
  `maxRowsPerSegment` rows) is not resumed and stays paused until `taskDuration` elapses; that one is not handled.
- Upstream syncs: `SeekableStreamSupervisor` changes often upstream. Keep the cycle checks in `runInternal`,
  `createNewTasks` and task creation, and re-check them against upstream changes to bounded and idle handling, which
  this feature sits beside.
