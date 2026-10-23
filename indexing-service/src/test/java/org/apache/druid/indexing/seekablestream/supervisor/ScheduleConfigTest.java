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

package org.apache.druid.indexing.seekablestream.supervisor;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.druid.error.DruidException;
import org.apache.druid.jackson.DefaultObjectMapper;
import org.apache.druid.java.util.common.DateTimes;
import org.joda.time.Period;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

public class ScheduleConfigTest
{
  private final ObjectMapper mapper = new DefaultObjectMapper();

  @Test
  public void testSerde() throws Exception
  {
    final ScheduleConfig config = mapper.readValue(
        "{\"period\": \"PT4H\", \"origin\": \"2026-01-01T00:15:00Z\"}",
        ScheduleConfig.class
    );
    Assertions.assertEquals(Period.hours(4), config.getPeriod());
    Assertions.assertEquals(DateTimes.of("2026-01-01T00:15:00Z"), config.getOrigin());
    Assertions.assertEquals(config, mapper.readValue(mapper.writeValueAsString(config), ScheduleConfig.class));
  }

  @Test
  public void testOriginDefaultsToEpoch() throws Exception
  {
    final ScheduleConfig config = mapper.readValue("{\"period\": \"PT4H\"}", ScheduleConfig.class);
    Assertions.assertEquals(DateTimes.EPOCH, config.getOrigin());
  }

  @Test
  public void testEqualsComparesInstants()
  {
    Assertions.assertEquals(
        new ScheduleConfig(Period.hours(24), null),
        new ScheduleConfig(Period.days(1), DateTimes.of("1970-01-01T01:00:00+01:00"))
    );
    Assertions.assertNotEquals(
        new ScheduleConfig(Period.hours(4), null),
        new ScheduleConfig(Period.hours(4), DateTimes.of("1970-01-01T00:15:00Z"))
    );
  }

  @Test
  public void testPeriodIsRequired()
  {
    final DruidException e = Assertions.assertThrows(DruidException.class, () -> new ScheduleConfig(null, null));
    Assertions.assertEquals("'period' must be specified in 'scheduleConfig'", e.getMessage());
  }

  @Test
  public void testPeriodMustHaveFixedLength()
  {
    final DruidException e = Assertions.assertThrows(
        DruidException.class,
        () -> new ScheduleConfig(Period.months(1), null)
    );
    Assertions.assertEquals(
        "'period'[P1M] in 'scheduleConfig' must have a fixed length, so it cannot contain months or years",
        e.getMessage()
    );
  }

  @Test
  public void testPeriodMustBePositive()
  {
    final DruidException e = Assertions.assertThrows(
        DruidException.class,
        () -> new ScheduleConfig(Period.ZERO, null)
    );
    Assertions.assertEquals("'period'[PT0S] in 'scheduleConfig' must be positive", e.getMessage());
  }

  @Test
  public void testStartsAreAlignedToOrigin()
  {
    final ScheduleConfig config = new ScheduleConfig(Period.hours(4), DateTimes.of("2026-01-01T00:15:00Z"));

    Assertions.assertEquals(
        DateTimes.of("2026-10-23T08:15:00Z"),
        config.getLatestStartAtOrBefore(DateTimes.of("2026-10-23T12:14:59.999Z"))
    );
    Assertions.assertEquals(
        DateTimes.of("2026-10-23T12:15:00Z"),
        config.getLatestStartAtOrBefore(DateTimes.of("2026-10-23T12:15:00Z"))
    );
    Assertions.assertEquals(
        DateTimes.of("2026-10-23T16:15:00Z"),
        config.getNextStartAfter(DateTimes.of("2026-10-23T12:15:00Z"))
    );
  }

  @Test
  public void testStartsBeforeOrigin()
  {
    final ScheduleConfig config = new ScheduleConfig(Period.hours(4), DateTimes.of("2026-01-01T00:15:00Z"));

    Assertions.assertEquals(
        DateTimes.of("2025-12-31T20:15:00Z"),
        config.getLatestStartAtOrBefore(DateTimes.of("2026-01-01T00:00:00Z"))
    );
    Assertions.assertEquals(
        DateTimes.of("2026-01-01T00:15:00Z"),
        config.getNextStartAfter(DateTimes.of("2026-01-01T00:00:00Z"))
    );
  }
}
