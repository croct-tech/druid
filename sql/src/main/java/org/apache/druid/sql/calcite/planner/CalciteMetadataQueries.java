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

package org.apache.druid.sql.calcite.planner;

import org.apache.calcite.plan.RelOptCluster;
import org.apache.calcite.rel.metadata.JaninoRelMetadataProvider;
import org.apache.calcite.rel.metadata.ProxyingMetadataHandlerProvider;
import org.apache.calcite.rel.metadata.RelMetadataQuery;

import java.util.Objects;

/**
 * Chooses how Calcite answers metadata queries (row counts, costs, collations, ...) during planning.
 * <p>
 * Calcite's default, {@link JaninoRelMetadataProvider}, generates a Java class for every combination of relational
 * operator and metadata type and compiles it at run time with Janino. When {@link RuntimeCodeGeneration} is not
 * available, every {@link RelOptCluster} is told to answer metadata queries through Calcite's
 * {@link ProxyingMetadataHandlerProvider} instead, which dispatches through {@link java.lang.reflect.Proxy}.
 */
public final class CalciteMetadataQueries
{
  private CalciteMetadataQueries()
  {
  }

  /**
   * Configures a freshly created cluster. Call before the cluster answers its first metadata query.
   */
  public static void configure(final RelOptCluster cluster)
  {
    if (!RuntimeCodeGeneration.isAvailable()) {
      cluster.setMetadataQuerySupplier(
          () -> new RelMetadataQuery(
              new ProxyingMetadataHandlerProvider(
                  Objects.requireNonNull(cluster.getMetadataProvider(), "metadataProvider")
              )
          )
      );
    }
  }
}
