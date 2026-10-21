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

import org.apache.calcite.DataContext;
import org.apache.calcite.interpreter.Context;
import org.apache.calcite.interpreter.DruidInterpreter;
import org.apache.calcite.interpreter.Scalar;
import org.apache.calcite.rel.type.RelDataType;
import org.apache.calcite.rex.RexNode;
import org.apache.druid.error.DruidException;
import org.apache.druid.java.util.common.DateTimes;
import org.apache.druid.math.expr.Expr;
import org.apache.druid.math.expr.ExprEval;
import org.apache.druid.math.expr.ExprType;
import org.apache.druid.math.expr.ExpressionType;
import org.apache.druid.segment.column.RowSignature;
import org.apache.druid.sql.calcite.expression.DruidExpression;
import org.apache.druid.sql.calcite.expression.Expressions;
import org.apache.druid.sql.calcite.table.RowSignatures;
import org.joda.time.DateTimeZone;

import javax.annotation.Nullable;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;

/**
 * Compiles Calcite expressions for {@link DruidInterpreter} by translating them to Druid expressions, the same
 * translation the planner applies when it builds native queries. Values cross the boundary in both directions: input
 * rows hold Calcite's run-time representation (for example local-time millis for {@code TIMESTAMP}), and results are
 * converted back to the Java type Calcite expects for the declared SQL type, so that the surrounding Calcite nodes
 * (sorts, aggregates, joins) see exactly what Janino-compiled code would have produced.
 */
public class DruidExpressionScalarCompiler implements DruidInterpreter.ScalarCompiler
{
  private final PlannerContext plannerContext;

  public DruidExpressionScalarCompiler(final PlannerContext plannerContext)
  {
    this.plannerContext = plannerContext;
  }

  @Override
  public Scalar compile(final List<RexNode> nodes, final RelDataType inputRowType, final DataContext dataContext)
  {
    final RowSignature signature = RowSignatures.fromRelDataTypeWithUniqueFields(inputRowType);
    final DateTimeZone timeZone = plannerContext.getTimeZone();

    final ExpressionType[] inputTypes = new ExpressionType[signature.size()];
    final ValueConverter[] inputConverters = new ValueConverter[signature.size()];
    for (int i = 0; i < signature.size(); i++) {
      inputTypes[i] = ExpressionType.fromColumnType(signature.getColumnType(i).orElse(null));
      inputConverters[i] = inputConverter(inputRowType.getFieldList().get(i).getType(), timeZone);
    }

    final Expr[] exprs = new Expr[nodes.size()];
    final ResultConverter[] resultConverters = new ResultConverter[nodes.size()];
    for (int i = 0; i < nodes.size(); i++) {
      final RexNode node = nodes.get(i);
      final DruidExpression expression = Expressions.toDruidExpression(plannerContext, signature, node);
      if (expression == null) {
        throw DruidException.forPersona(DruidException.Persona.USER)
                            .ofCategory(DruidException.Category.UNSUPPORTED)
                            .build("Cannot evaluate expression [%s] without run-time code generation", node);
      }
      exprs[i] = plannerContext.parseExpression(expression.getExpression());
      resultConverters[i] = resultConverter(node.getType(), timeZone);
    }

    return new DruidScalar(signature, inputTypes, inputConverters, exprs, resultConverters);
  }

  /**
   * Converts a value from Calcite's run-time representation into what a Druid expression expects as input.
   */
  private static ValueConverter inputConverter(final RelDataType type, final DateTimeZone timeZone)
  {
    switch (type.getSqlTypeName()) {
      case TIMESTAMP:
      case TIMESTAMP_WITH_LOCAL_TIME_ZONE:
        return value -> value == null ? null : Calcites.calciteTimestampToJoda((Long) value, timeZone).getMillis();
      case DATE:
        return value -> value == null ? null : Calcites.calciteDateToJoda((Integer) value, timeZone).getMillis();
      case ARRAY:
        return value -> value instanceof List ? ((List<?>) value).toArray() : value;
      default:
        return value -> value;
    }
  }

  /**
   * Converts an evaluated Druid expression into the Java type Calcite uses for the given SQL type.
   */
  private static ResultConverter resultConverter(final RelDataType type, final DateTimeZone timeZone)
  {
    switch (type.getSqlTypeName()) {
      case BOOLEAN:
        return eval -> eval.value() == null ? null : eval.asBoolean();
      case TINYINT:
        return eval -> eval.isNumericNull() ? null : (byte) eval.asLong();
      case SMALLINT:
        return eval -> eval.isNumericNull() ? null : (short) eval.asLong();
      case INTEGER:
        return eval -> eval.isNumericNull() ? null : (int) eval.asLong();
      case BIGINT:
        return eval -> eval.isNumericNull() ? null : eval.asLong();
      case FLOAT:
      case REAL:
        return eval -> eval.isNumericNull() ? null : (float) eval.asDouble();
      case DOUBLE:
        return eval -> eval.isNumericNull() ? null : eval.asDouble();
      case DECIMAL:
        return eval -> {
          if (eval.isNumericNull()) {
            return null;
          }
          return eval.type().is(ExprType.LONG) ? BigDecimal.valueOf(eval.asLong()) : BigDecimal.valueOf(eval.asDouble());
        };
      case CHAR:
      case VARCHAR:
        return ExprEval::asString;
      case TIMESTAMP:
      case TIMESTAMP_WITH_LOCAL_TIME_ZONE:
        return eval -> eval.isNumericNull()
                       ? null
                       : Calcites.jodaToCalciteTimestamp(DateTimes.utc(eval.asLong()), timeZone);
      case DATE:
        return eval -> eval.isNumericNull() ? null : Calcites.jodaToCalciteDate(DateTimes.utc(eval.asLong()), timeZone);
      case ARRAY:
        return eval -> {
          final Object[] array = eval.asArray();
          return array == null ? null : Arrays.asList(array);
        };
      default:
        return ExprEval::value;
    }
  }

  private interface ValueConverter
  {
    @Nullable
    Object convert(@Nullable Object value);
  }

  private interface ResultConverter
  {
    @Nullable
    Object convert(ExprEval<?> eval);
  }

  private static class DruidScalar implements Scalar
  {
    private final RowSignature signature;
    private final ExpressionType[] inputTypes;
    private final ValueConverter[] inputConverters;
    private final Expr[] exprs;
    private final ResultConverter[] resultConverters;

    DruidScalar(
        final RowSignature signature,
        final ExpressionType[] inputTypes,
        final ValueConverter[] inputConverters,
        final Expr[] exprs,
        final ResultConverter[] resultConverters
    )
    {
      this.signature = signature;
      this.inputTypes = inputTypes;
      this.inputConverters = inputConverters;
      this.exprs = exprs;
      this.resultConverters = resultConverters;
    }

    @Override
    @Nullable
    public Object execute(final Context context)
    {
      final Object[] results = new Object[1];
      execute(context, results);
      return results[0];
    }

    @Override
    public void execute(final Context context, final Object[] results)
    {
      final Expr.ObjectBinding binding = new RowBinding(context.values);
      for (int i = 0; i < exprs.length; i++) {
        results[i] = resultConverters[i].convert(exprs[i].eval(binding));
      }
    }

    /**
     * Exposes one row of {@link Context#values} to the expressions, by the column names of the row signature.
     */
    private class RowBinding implements Expr.ObjectBinding
    {
      @Nullable
      private final Object[] values;

      RowBinding(@Nullable final Object[] values)
      {
        this.values = values;
      }

      @Override
      @Nullable
      public ExpressionType getType(final String name)
      {
        final int index = signature.indexOf(name);
        return index < 0 ? null : inputTypes[index];
      }

      @Override
      @Nullable
      public Object get(final String name)
      {
        final int index = signature.indexOf(name);
        if (index < 0 || values == null) {
          return null;
        }
        return inputConverters[index].convert(values[index]);
      }
    }
  }
}
