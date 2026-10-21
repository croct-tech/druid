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
import org.apache.calcite.rel.metadata.MetadataHandler;
import org.apache.calcite.rel.metadata.MetadataHandlerProvider;
import org.apache.calcite.rel.metadata.ProxyingMetadataHandlerProvider;
import org.apache.calcite.rel.metadata.RelMetadataProvider;
import org.apache.calcite.rel.metadata.RelMetadataQuery;

import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Supplier;

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
      cluster.setMetadataQuerySupplier(new ProxyingMetadataQuerySupplier(cluster));
    }
  }

  /**
   * Creates metadata queries backed by {@link ProxyingMetadataHandlerProvider}. The planner discards the cluster's
   * {@link RelMetadataQuery} after every rule application, and each new one asks the provider for every built-in
   * handler, which the proxying provider builds reflectively on each call. The handlers hold no per-query state (the
   * query is an argument of every call), so they are cached for as long as the cluster keeps the same
   * {@link RelMetadataProvider}.
   */
  private static final class ProxyingMetadataQuerySupplier implements Supplier<RelMetadataQuery>
  {
    private final RelOptCluster cluster;
    private RelMetadataProvider provider;
    private MetadataHandlerProvider handlers;

    private ProxyingMetadataQuerySupplier(final RelOptCluster cluster)
    {
      this.cluster = cluster;
    }

    @Override
    public synchronized RelMetadataQuery get()
    {
      final RelMetadataProvider current = Objects.requireNonNull(cluster.getMetadataProvider(), "metadataProvider");
      if (current != provider) {
        provider = current;
        handlers = new CachingMetadataHandlerProvider(new ProxyingMetadataHandlerProvider(current));
      }
      return new RelMetadataQuery(handlers);
    }
  }

  private static final class CachingMetadataHandlerProvider implements MetadataHandlerProvider
  {
    private final MetadataHandlerProvider delegate;
    private final ConcurrentHashMap<Class<?>, MetadataHandler<?>> handlers = new ConcurrentHashMap<>();

    private CachingMetadataHandlerProvider(final MetadataHandlerProvider delegate)
    {
      this.delegate = delegate;
    }

    @Override
    public <MH extends MetadataHandler<?>> MH handler(final Class<MH> handlerClass)
    {
      return handlerClass.cast(handlers.computeIfAbsent(handlerClass, ignored -> delegate.handler(handlerClass)));
    }
  }
}
