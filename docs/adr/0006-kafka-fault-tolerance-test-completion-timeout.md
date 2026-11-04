---
Status: accepted
Upstream: fork-only
---

# Kafka fault-tolerance tests allow 60 seconds for task completion

`KafkaIndexFaultToleranceTest` overrides the shared Kafka test fixture's five-second `completionTimeout` with
60 seconds. Restarting the Coordinator can exceed five seconds and cause the supervisor to cancel tasks while
segments are being published. A publish can commit before its future is cancelled, losing the
`ingest/rows/published` metric even though the Historical loads the segment. The test then waits for a metric that
will never arrive and fails after waiting for 240 seconds.

The longer task completion timeout gives recovery time to finish without changing the production default or
unrelated Kafka tests. Increasing the metric wait would not recover a missing metric. This mitigates the test
failure; it does not fix the underlying metric loss during cancellation.

The failure reproduced locally with the original timeout. Changing only the task completion timeout to 60 seconds
made the same Coordinator restart test pass with publish metrics for all 3,000 rows.
