# Retry partition discovery and batch latest-offset lookups in the Kafka supervisor

Status: ready-for-agent
Category: bug

Two Kafka metadata calls the supervisor makes still call the consumer once with no retry, so a Kafka leader election can still push a supervisor into `LOST_CONTACT_WITH_STREAM`. This is a gap in the rule recorded in `docs/adr/0001-kafka-offset-lookups-retry-everything.md`.

## Agent Brief

**Category:** bug
**Summary:** `KafkaRecordSupplier.getPartitionIds()` and `KafkaRecordSupplier.getLatestSequenceNumbers()` must retry on every exception, like the single-partition offset lookups.

**Current behavior:**
`getEarliestSequenceNumber()` and `getLatestSequenceNumber()` already wrap their consumer call in `RetryUtils.retry` with a retry-everything predicate and `RetryUtils.DEFAULT_MAX_TRIES`. Two sibling methods do not:

- `getPartitionIds(String stream)` (partition discovery via `consumer.partitionsFor()` or, for multi-topic patterns, `consumer.listTopics()`) makes a single attempt. The supervisor records its failure as a stream exception, so repeated failures during a leader election turn the supervisor `LOST_CONTACT_WITH_STREAM` (or `UNABLE_TO_CONNECT_TO_STREAM` before its first successful run).
- `getLatestSequenceNumbers(Set<StreamPartition>)` (one batch `consumer.endOffsets()` call) makes a single attempt. `KafkaSupervisor` uses it for record-lag and time-lag reporting.

**Desired behavior:**
Both methods retry with the same policy as `getLatestSequenceNumber()`: `RetryUtils.retry`, predicate `e -> true`, `RetryUtils.DEFAULT_MAX_TRIES`. Every exception is retried, including the `DruidException`s that `getPartitionIds()` itself throws when a topic is not found or a multi-topic pattern matches nothing (Kafka metadata can be transiently incomplete during an election). Once retries are exhausted, the last failure surfaces as a `StreamException`, exactly as today.

**Key interfaces:**
- `KafkaRecordSupplier.getPartitionIds(String)`: same signature and return value; adds retry.
- `KafkaRecordSupplier.getLatestSequenceNumbers(Set<StreamPartition<KafkaTopicPartition>>)`: same signature and return value; adds retry.
- `KafkaRecordSupplierTest`: this module mocks with EasyMock, not Mockito. Follow the existing `testGetEarliestSequenceNumberRetriesOnTransientFailure` pattern.

**Acceptance criteria:**
- [ ] `getPartitionIds()` returns the partitions when `partitionsFor()` first throws a Kafka exception that Kafka does not classify as retriable (e.g. `KafkaException`) and then succeeds.
- [ ] `getPartitionIds()` returns the partitions when `partitionsFor()` first returns `null` and then returns the topic's partitions.
- [ ] Multi-topic `getPartitionIds()` returns the partitions when `listTopics()` first throws and then succeeds.
- [ ] `getLatestSequenceNumbers()` returns the offsets when `endOffsets()` first throws a non-retriable Kafka exception and then succeeds.
- [ ] When every attempt fails, both methods throw `StreamException`.
- [ ] `KafkaRecordSupplierTest` and `KafkaSupervisorTest` pass, and checkstyle, PMD and forbidden-apis are clean for the module.

**Out of scope:**
- Changing the retry count, backoff, or predicate.
- Treating an empty partition list from `partitionsFor()` as a failure to retry.
- Kinesis, and Kafka calls made by ingestion tasks (e.g. `poll()`).
- `getPosition()`, `seekToEarliest()` and `seekToLatest()`.
