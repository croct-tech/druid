---
Status: accepted
Upstream: fork-only
---

# Kafka offset lookups use stateless metadata APIs and retry on every exception

Our Kafka brokers are self-managed on GCP spot VMs, so leader elections are routine. Upstream's `KafkaRecordSupplier` finds the earliest/latest offset of a partition by seeking the consumer and reading `consumer.position()`, which throws during an election (we hit both `NoOffsetForPartitionException` and `LeaderNotAvailableException`). Repeated failures push the supervisor into `LOST_CONTACT_WITH_STREAM`, which needs a manual restart, so with 20 supervisors every broker replacement became a production halt. We replaced seek + `position()` with `beginningOffsets()` / `endOffsets()`, which don't depend on consumer state, wrapped in `RetryUtils.retry` (`DEFAULT_MAX_TRIES`) retrying on **every** exception. `KafkaSupervisor`'s lag reporting uses the same batch `endOffsets()` lookup instead of seek + `position()`.

Retrying everything is deliberate. The Kafka client has repeatedly misclassified which errors are retriable, so we don't trust its `RetriableException` hierarchy: a real fatal error (bad credentials, deleted topic) surfacing minutes late is far cheaper than thousands of spurious production halts. The rule covers every Kafka metadata call the supervisor makes, not only the two lookups fixed first. The fix was raised upstream across several issues over the years and never picked up, so this is a permanent fork patch.

## Consequences

- In the worst case one lookup blocks the supervisor's run loop for minutes: about 4 minutes of backoff across 10 tries, plus up to `default.api.timeout.ms` per attempt.
- Don't narrow the retry predicate to Kafka's "retriable" exceptions; that is exactly the trap this ADR exists to prevent.
- Upstream keeps changing `KafkaRecordSupplier` and `KafkaSupervisor`. Sync merges must re-apply this intent, not take upstream's version.
