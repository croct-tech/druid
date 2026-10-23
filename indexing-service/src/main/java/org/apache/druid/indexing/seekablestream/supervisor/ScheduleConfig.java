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

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonProperty;
import org.apache.druid.error.InvalidInput;
import org.apache.druid.java.util.common.DateTimes;
import org.joda.time.DateTime;
import org.joda.time.Duration;
import org.joda.time.Period;

import javax.annotation.Nullable;
import java.util.Objects;

/**
 * Configuration for scheduled stream ingestion. Instead of reading continuously, the supervisor ingests in ingestion
 * cycles that start at {@code origin + k * period}. Each cycle reads every partition from its committed offset up to
 * the latest offset the stream had when the cycle started, then the supervisor waits for the next start.
 */
public class ScheduleConfig
{
  private final Period period;
  private final DateTime origin;
  private final long periodMillis;

  @JsonCreator
  public ScheduleConfig(
      @JsonProperty("period") Period period,
      @Nullable @JsonProperty("origin") DateTime origin
  )
  {
    if (period == null) {
      throw InvalidInput.exception("'period' must be specified in 'scheduleConfig'");
    }
    final Duration duration;
    try {
      duration = period.toStandardDuration();
    }
    catch (UnsupportedOperationException e) {
      throw InvalidInput.exception(
          "'period'[%s] in 'scheduleConfig' must have a fixed length, so it cannot contain months or years",
          period
      );
    }
    if (duration.getMillis() <= 0) {
      throw InvalidInput.exception("'period'[%s] in 'scheduleConfig' must be positive", period);
    }
    this.period = period;
    this.origin = origin == null ? DateTimes.EPOCH : origin;
    this.periodMillis = duration.getMillis();
  }

  @JsonProperty
  public Period getPeriod()
  {
    return period;
  }

  @JsonProperty
  public DateTime getOrigin()
  {
    return origin;
  }

  /**
   * Returns the latest cycle start that is not after {@code time}.
   */
  public DateTime getLatestStartAtOrBefore(DateTime time)
  {
    final long cycles = Math.floorDiv(time.getMillis() - origin.getMillis(), periodMillis);
    return DateTimes.utc(origin.getMillis() + cycles * periodMillis);
  }

  /**
   * Returns the first cycle start that is after {@code time}.
   */
  public DateTime getNextStartAfter(DateTime time)
  {
    return getLatestStartAtOrBefore(time).plus(periodMillis);
  }

  @Override
  public boolean equals(Object o)
  {
    if (this == o) {
      return true;
    }
    if (o == null || getClass() != o.getClass()) {
      return false;
    }
    ScheduleConfig that = (ScheduleConfig) o;
    return periodMillis == that.periodMillis && origin.getMillis() == that.origin.getMillis();
  }

  @Override
  public int hashCode()
  {
    return Objects.hash(periodMillis, origin.getMillis());
  }

  @Override
  public String toString()
  {
    return "ScheduleConfig{" +
           "period=" + period +
           ", origin=" + origin +
           '}';
  }
}
