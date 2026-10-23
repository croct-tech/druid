/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

package org.apache.druid.testing.embedded.indexing;

import org.apache.druid.common.utils.IdUtils;
import org.apache.druid.indexing.kafka.simulate.KafkaResource;
import org.apache.druid.indexing.kafka.supervisor.KafkaSupervisorSpec;
import org.apache.druid.indexing.kafka.supervisor.KafkaSupervisorSpecBuilder;
import org.apache.druid.indexing.overlord.supervisor.SupervisorStatus;
import org.apache.druid.indexing.seekablestream.supervisor.ScheduleConfig;
import org.apache.druid.query.DruidMetrics;
import org.apache.druid.testing.embedded.EmbeddedDruidCluster;
import org.apache.druid.testing.embedded.StreamIngestResource;
import org.joda.time.Period;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

/**
 * Tests for scheduled Kafka supervisors, which ingest in ingestion cycles instead of continuously.
 */
public class KafkaScheduledSupervisorTest extends StreamIndexTestBase
{
  private static final long CYCLE_INGESTION_TIMEOUT_MILLIS = 120_000L;

  /**
   * Cycles start every 5 seconds, so a test never waits long for the next one, while the supervisor, which runs
   * every 500 milliseconds in the shared fixture, still spends most of the time between cycles.
   */
  private static final Period CYCLE_PERIOD = Period.seconds(5);

  /**
   * Long enough that cycle tasks stop at their target offsets rather than being rolled over. See
   * {@code KafkaBoundedSupervisorTest} for why the fixture's 500ms duration doesn't work for tasks with end offsets.
   */
  private static final Period TASK_DURATION = Period.seconds(30);

  private final KafkaResource kafkaServer = new KafkaResource();

  @Override
  protected StreamIngestResource<?> getStreamIngestResource()
  {
    return kafkaServer;
  }

  /**
   * Larger than a cycle's records, so that tasks never checkpoint. The in-process tasks of this cluster start reading
   * within milliseconds, and a task that pauses for a checkpoint before the supervisor has discovered it stays paused
   * until {@link #TASK_DURATION} elapses.
   */
  private static final int MAX_ROWS_PER_SEGMENT = 5_000;

  @Override
  protected KafkaSupervisorSpecBuilder createKafkaSupervisor(KafkaResource kafkaServer)
  {
    return super.createKafkaSupervisor(kafkaServer)
        .withTuningConfig(tuningConfig -> tuningConfig.withMaxRowsPerSegment(MAX_ROWS_PER_SEGMENT));
  }

  @Override
  protected EmbeddedDruidCluster createCluster()
  {
    overlord.addProperty(
        "druid.monitoring.monitors",
        "[\"org.apache.druid.server.metrics.SupervisorStatsMonitor\"]"
    );
    overlord.addProperty("druid.monitoring.emissionPeriod", "PT1s");
    return super.createCluster();
  }

  @Test
  public void test_scheduledSupervisor_ingestsEachCycleAndIdlesBetweenCycles()
  {
    final String topic = IdUtils.getRandomId();
    kafkaServer.createTopicWithPartitions(topic, 2);

    final int firstBatch = publish1kRecords(topic, false);
    final KafkaSupervisorSpec supervisor = createScheduledKafkaSupervisor(topic, true);
    cluster.callApi().postSupervisor(supervisor);

    waitUntilPublishedRecordsAreIngested(firstBatch, CYCLE_INGESTION_TIMEOUT_MILLIS);
    waitForNextIdleState(supervisor.getId());
    verifyIdleWithoutRunningTasks(supervisor.getId());

    final int secondBatch = publish1kRecords(topic, false);
    waitUntilPublishedRecordsAreIngested(firstBatch + secondBatch, CYCLE_INGESTION_TIMEOUT_MILLIS);
    waitForNextIdleState(supervisor.getId());
    verifyIdleWithoutRunningTasks(supervisor.getId());

    verifyRowCount(firstBatch + secondBatch);
  }

  @Test
  public void test_scheduledSupervisor_fromLatestOffset_ingestsOnlyRecordsPublishedAfterItStarted()
  {
    final String topic = IdUtils.getRandomId();
    kafkaServer.createTopicWithPartitions(topic, 2);

    publish1kRecords(topic, false);
    final KafkaSupervisorSpec supervisor = createScheduledKafkaSupervisor(topic, false);
    cluster.callApi().postSupervisor(supervisor);

    // The supervisor commits the latest offsets before it first becomes idle, so later records belong to the
    // next cycle.
    waitForNextIdleState(supervisor.getId());

    final int recordsAfterStart = publish1kRecords(topic, false);
    waitUntilPublishedRecordsAreIngested(recordsAfterStart, CYCLE_INGESTION_TIMEOUT_MILLIS);
    waitForNextIdleState(supervisor.getId());

    verifyRowCount(recordsAfterStart);
  }

  private KafkaSupervisorSpec createScheduledKafkaSupervisor(String topic, boolean useEarliestOffset)
  {
    return createKafkaSupervisor(kafkaServer)
        .withIoConfig(io -> io
            .withTaskDuration(TASK_DURATION)
            .withUseEarliestSequenceNumber(useEarliestOffset)
            .withScheduleConfig(new ScheduleConfig(CYCLE_PERIOD, null))
        )
        .build(dataSource, topic);
  }

  private void waitForNextIdleState(String supervisorId)
  {
    overlord.latchableEmitter().waitForNextEvent(
        event -> event.hasMetricName("supervisor/count")
                      .hasDimension(DruidMetrics.SUPERVISOR_ID, supervisorId)
                      .hasDimension("state", "IDLE")
    );
  }

  private void verifyIdleWithoutRunningTasks(String supervisorId)
  {
    final SupervisorStatus status = cluster.callApi().getSupervisorStatus(supervisorId);
    Assertions.assertEquals("IDLE", status.getState());
    Assertions.assertTrue(status.isHealthy());
    Assertions.assertTrue(cluster.callApi().getTasks(dataSource, "running").isEmpty());
  }
}
