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

package org.apache.druid.sql.calcite;

import com.google.common.collect.ImmutableList;
import org.apache.druid.error.DruidException;
import org.apache.druid.error.DruidExceptionMatcher;
import org.apache.druid.sql.calcite.planner.RuntimeCodeGeneration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

/**
 * Runs Bindable (system table) queries without run-time code generation, the way a GraalVM native image does: Calcite
 * metadata through reflective proxies and expressions through {@code DruidInterpreter} with Druid's expression engine.
 */
public class CalciteInterpreterQueryTest extends BaseCalciteQueryTest
{
  private static String previousProperty;

  @BeforeAll
  public static void disableRuntimeCodeGeneration()
  {
    previousProperty = System.setProperty(RuntimeCodeGeneration.PROPERTY, "false");
    Assertions.assertFalse(RuntimeCodeGeneration.isAvailable());
  }

  @AfterAll
  public static void restoreRuntimeCodeGeneration()
  {
    if (previousProperty == null) {
      System.clearProperty(RuntimeCodeGeneration.PROPERTY);
    } else {
      System.setProperty(RuntimeCodeGeneration.PROPERTY, previousProperty);
    }
  }

  @Test
  public void testInformationSchemaColumnsOnTable()
  {
    msqIncompatible();
    testQuery(
        """
            SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = 'druid' AND TABLE_NAME = 'foo'""",
        ImmutableList.of(),
        ImmutableList.of(
            new Object[]{"__time", "TIMESTAMP", "NO"},
            new Object[]{"dim1", "VARCHAR", "YES"},
            new Object[]{"dim2", "VARCHAR", "YES"},
            new Object[]{"dim3", "VARCHAR", "YES"},
            new Object[]{"cnt", "BIGINT", "YES"},
            new Object[]{"m1", "FLOAT", "YES"},
            new Object[]{"m2", "DOUBLE", "YES"},
            new Object[]{"unique_dim1", "COMPLEX<hyperUnique>", "YES"}
        )
    );
  }

  @Test
  public void testAggregatorsOnInformationSchemaColumns()
  {
    msqIncompatible();
    testQuery(
        """
            SELECT COUNT(JDBC_TYPE), SUM(JDBC_TYPE), AVG(JDBC_TYPE), MIN(JDBC_TYPE), MAX(JDBC_TYPE)
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = 'druid' AND TABLE_NAME = 'foo'""",
        ImmutableList.of(),
        ImmutableList.of(
            new Object[]{8L, 1249L, 156.125, -5L, 1111L}
        )
    );
  }

  @Test
  public void testFloatingPointTypesOnInformationSchemaColumns()
  {
    msqIncompatible();
    // Calcite represents FLOAT and DOUBLE as Double and only REAL as Float; the interpreter must do the same.
    testQuery(
        """
            SELECT CAST(JDBC_TYPE AS FLOAT), CAST(JDBC_TYPE AS REAL), CAST(JDBC_TYPE AS DOUBLE)
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = 'druid' AND TABLE_NAME = 'foo' AND COLUMN_NAME = '__time'""",
        ImmutableList.of(),
        ImmutableList.of(
            new Object[]{93.0, 93.0f, 93.0}
        )
    );
  }

  @Test
  public void testAggregateFunctionThatNeedsCodeGenerationIsRejected()
  {
    msqIncompatible();
    // The scalar subquery becomes a SINGLE_VALUE aggregate, which Calcite's interpreter can only run through Janino.
    testQueryThrows(
        """
            SELECT COLUMN_NAME
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_NAME = (SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'foo')""",
        new DruidExceptionMatcher(DruidException.Persona.USER, DruidException.Category.UNSUPPORTED, "general")
            .expectMessageContains("Aggregate function [SINGLE_VALUE] requires run-time code generation")
    );
  }

  @Test
  public void testScalarFunctionsSortAndLimitOnInformationSchemaColumns()
  {
    msqIncompatible();
    testQuery(
        """
            SELECT UPPER(COLUMN_NAME), CHAR_LENGTH(COLUMN_NAME) + 1, CAST(JDBC_TYPE AS VARCHAR), JDBC_TYPE * 2,
                   DATA_TYPE = 'VARCHAR', COALESCE(CHARACTER_MAXIMUM_LENGTH, -1)
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = 'druid' AND TABLE_NAME = 'foo' AND COLUMN_NAME LIKE 'dim%'
            ORDER BY COLUMN_NAME DESC
            LIMIT 2""",
        ImmutableList.of(),
        ImmutableList.of(
            new Object[]{"DIM3", 5, "12", 24L, true, "-1"},
            new Object[]{"DIM2", 5, "12", 24L, true, "-1"}
        )
    );
  }

  @Test
  public void testGroupByAndHavingOnInformationSchemaColumns()
  {
    msqIncompatible();
    testQuery(
        """
            SELECT DATA_TYPE, COUNT(*), MAX(ORDINAL_POSITION)
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = 'druid' AND TABLE_NAME = 'foo'
            GROUP BY DATA_TYPE
            HAVING COUNT(*) >= 1
            ORDER BY DATA_TYPE""",
        ImmutableList.of(),
        ImmutableList.of(
            new Object[]{"BIGINT", 1L, 5L},
            new Object[]{"COMPLEX<hyperUnique>", 1L, 8L},
            new Object[]{"DOUBLE", 1L, 7L},
            new Object[]{"FLOAT", 1L, 6L},
            new Object[]{"TIMESTAMP", 1L, 1L},
            new Object[]{"VARCHAR", 3L, 4L}
        )
    );
  }

  @Test
  public void testFilterScalarFunctionsOnInformationSchemaRoutines()
  {
    msqIncompatible();
    testQuery(
        """
            SELECT COUNT(*)
            FROM INFORMATION_SCHEMA.ROUTINES
            WHERE IS_AGGREGATOR = 'NO' AND ROUTINE_NAME = 'CEIL'""",
        ImmutableList.of(),
        ImmutableList.of(
            new Object[]{1L}
        )
    );
  }

  @Test
  public void testNonExistentSchemaOnInformationSchemaRoutines()
  {
    msqIncompatible();
    testQuery(
        "SELECT * FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_SCHEMA = 'boo'",
        ImmutableList.of(),
        ImmutableList.of()
    );
  }
}
