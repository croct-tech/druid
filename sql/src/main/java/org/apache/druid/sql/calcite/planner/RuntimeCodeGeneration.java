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

/**
 * Whether Calcite may generate and compile Java code at run time while planning and executing SQL.
 * <p>
 * Calcite relies on Janino in two places: its default metadata provider compiles a handler class per combination of
 * relational operator and metadata type, and the Bindable interpreter that executes queries on system tables compiles
 * filter and projection expressions. A GraalVM native image cannot define classes at run time, so there Druid routes
 * both through code-generation-free alternatives: {@link CalciteMetadataQueries} switches the metadata provider to
 * reflective proxies, and {@link QueryHandler} executes Bindable plans with Druid's own expression engine.
 * <p>
 * The decision is read from the {@value #PROPERTY} system property when set, otherwise code generation is available
 * unless running inside a native image. The property exists so that the native image build can record what a JVM
 * does on the code-generation-free paths, and so that tests can exercise them.
 */
public final class RuntimeCodeGeneration
{
  public static final String PROPERTY = "druid.sql.calcite.runtimeCodeGeneration";

  /**
   * Set by GraalVM to {@code buildtime} while a native image is built and to {@code runtime} inside the image.
   */
  private static final String NATIVE_IMAGE_CODE_PROPERTY = "org.graalvm.nativeimage.imagecode";

  private RuntimeCodeGeneration()
  {
  }

  public static boolean isAvailable()
  {
    final String property = System.getProperty(PROPERTY);
    if (property != null) {
      return Boolean.parseBoolean(property);
    }
    return System.getProperty(NATIVE_IMAGE_CODE_PROPERTY) == null;
  }
}
