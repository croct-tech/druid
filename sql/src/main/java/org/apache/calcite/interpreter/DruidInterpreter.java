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

//CHECKSTYLE.OFF: PackageName - Must be in Calcite

package org.apache.calcite.interpreter;

import com.google.common.collect.ImmutableList;
import com.google.common.collect.ImmutableMap;
import com.google.common.collect.Iterables;
import com.google.common.collect.LinkedHashMultimap;
import com.google.common.collect.Lists;
import com.google.common.collect.Multimap;
import org.apache.calcite.DataContext;
import org.apache.calcite.DataContexts;
import org.apache.calcite.linq4j.AbstractEnumerable;
import org.apache.calcite.linq4j.Enumerable;
import org.apache.calcite.linq4j.Enumerator;
import org.apache.calcite.linq4j.Linq4j;
import org.apache.calcite.linq4j.Ord;
import org.apache.calcite.linq4j.TransformedEnumerator;
import org.apache.calcite.plan.hep.HepPlanner;
import org.apache.calcite.plan.hep.HepProgram;
import org.apache.calcite.plan.hep.HepProgramBuilder;
import org.apache.calcite.rel.RelNode;
import org.apache.calcite.rel.RelVisitor;
import org.apache.calcite.rel.core.Aggregate;
import org.apache.calcite.rel.core.Collect;
import org.apache.calcite.rel.core.Filter;
import org.apache.calcite.rel.core.Join;
import org.apache.calcite.rel.core.Match;
import org.apache.calcite.rel.core.Project;
import org.apache.calcite.rel.core.SetOp;
import org.apache.calcite.rel.core.Sort;
import org.apache.calcite.rel.core.TableFunctionScan;
import org.apache.calcite.rel.core.TableScan;
import org.apache.calcite.rel.core.Uncollect;
import org.apache.calcite.rel.core.Values;
import org.apache.calcite.rel.core.Window;
import org.apache.calcite.rel.rules.CoreRules;
import org.apache.calcite.rel.type.RelDataType;
import org.apache.calcite.rel.type.RelDataTypeFactory;
import org.apache.calcite.rex.RexNode;
import org.apache.calcite.util.Pair;
import org.apache.calcite.util.ReflectUtil;
import org.apache.calcite.util.ReflectiveVisitDispatcher;
import org.apache.calcite.util.ReflectiveVisitor;
import org.apache.calcite.util.Util;
import org.apache.druid.java.util.common.RE;

import javax.annotation.Nullable;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.Objects;

/**
 * Executes a Bindable plan like Calcite's {@link Interpreter}, but with a pluggable {@link ScalarCompiler} in place
 * of Calcite's {@link JaninoRexCompiler}. Druid uses it with its own expression engine where Janino cannot compile
 * classes at run time, such as in a GraalVM native image (see {@code RuntimeCodeGeneration}).
 * <p>
 * The data-flow machinery is copied from Calcite 1.42's {@link Interpreter} and {@link Nodes}, whose compiler is
 * fixed to Janino and whose internals are not extensible. The node implementations ({@link FilterNode},
 * {@link ProjectNode}, {@link AggregateNode}, ...) are Calcite's own: they only interact with the compiler through the
 * public {@link Compiler} interface. This class lives in Calcite's package because {@link Context} can only be
 * created from there.
 */
public class DruidInterpreter extends AbstractEnumerable<Object[]> implements AutoCloseable
{
  /**
   * Turns a list of expressions over an input row type into a {@link Scalar} that evaluates them.
   */
  public interface ScalarCompiler
  {
    Scalar compile(List<RexNode> nodes, RelDataType inputRowType, DataContext dataContext);
  }

  private final Map<RelNode, NodeInfo> nodes;
  private final DataContext dataContext;
  private final RelNode rootRel;

  public DruidInterpreter(DataContext dataContext, RelNode rootRel, ScalarCompiler scalarCompiler)
  {
    this.dataContext = Objects.requireNonNull(dataContext, "dataContext");
    final RelNode rel = optimize(rootRel);
    final CompilerImpl compiler = new CompilerImpl(this, scalarCompiler);
    final Pair<RelNode, Map<RelNode, NodeInfo>> pair = compiler.visitRoot(rel);
    this.rootRel = pair.left;
    this.nodes = ImmutableMap.copyOf(pair.right);
  }

  private static RelNode optimize(RelNode rootRel)
  {
    final HepProgram hepProgram = new HepProgramBuilder()
        .addRuleInstance(CoreRules.CALC_SPLIT)
        .addRuleInstance(CoreRules.FILTER_SCAN)
        .addRuleInstance(CoreRules.FILTER_INTERPRETER_SCAN)
        .addRuleInstance(CoreRules.PROJECT_TABLE_SCAN)
        .addRuleInstance(CoreRules.PROJECT_INTERPRETER_TABLE_SCAN)
        .addRuleInstance(CoreRules.AGGREGATE_REDUCE_FUNCTIONS)
        .build();
    final HepPlanner planner = new HepPlanner(hepProgram);
    planner.setRoot(rootRel);
    return planner.findBestExp();
  }

  @Override
  public Enumerator<Object[]> enumerator()
  {
    start();
    final NodeInfo nodeInfo = Objects.requireNonNull(nodes.get(rootRel), () -> "nodeInfo for " + rootRel);
    final Enumerator<Row> rows;
    if (nodeInfo.rowEnumerable != null) {
      rows = nodeInfo.rowEnumerable.enumerator();
    } else {
      final ArrayDeque<Row> queue = Iterables.getOnlyElement(nodeInfo.sinks.values()).list;
      rows = Linq4j.iterableEnumerator(queue);
    }

    return new TransformedEnumerator<>(rows)
    {
      @Override
      protected Object[] transform(Row row)
      {
        return row.getValues();
      }
    };
  }

  private void start()
  {
    // Nodes are ordered leaves first.
    for (Map.Entry<RelNode, NodeInfo> entry : nodes.entrySet()) {
      final NodeInfo nodeInfo = entry.getValue();
      if (nodeInfo.node == null) {
        throw new IllegalStateException("Node must not be null for rel[" + nodeInfo.rel + "]");
      }
      try {
        nodeInfo.node.run();
      }
      catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new RE(e, "Interrupted while running rel[%s]", nodeInfo.rel);
      }
    }
  }

  @Override
  public void close()
  {
    nodes.values().forEach(NodeInfo::close);
  }

  /**
   * Information about a node registered in the data flow graph.
   */
  private static class NodeInfo
  {
    private final RelNode rel;
    private final Map<Edge, ListSink> sinks = new LinkedHashMap<>();
    @Nullable
    private final Enumerable<Row> rowEnumerable;
    @Nullable
    private Node node;

    NodeInfo(RelNode rel, @Nullable Enumerable<Row> rowEnumerable)
    {
      this.rel = rel;
      this.rowEnumerable = rowEnumerable;
    }

    void close()
    {
      if (node != null) {
        final Node n = node;
        node = null;
        n.close();
      }
    }
  }

  /**
   * A {@link Source} backed by an {@link Enumerator}, which is closed once it is exhausted or on {@link #close()}.
   */
  private static class EnumeratorSource implements Source
  {
    private final Enumerator<Row> enumerator;

    EnumeratorSource(final Enumerator<Row> enumerator)
    {
      this.enumerator = Objects.requireNonNull(enumerator, "enumerator");
    }

    @Override
    @Nullable
    public Row receive()
    {
      if (enumerator.moveNext()) {
        return enumerator.current();
      }
      enumerator.close();
      return null;
    }

    @Override
    public void close()
    {
      enumerator.close();
    }
  }

  /**
   * A {@link Sink} backed by an {@link ArrayDeque}.
   */
  private static class ListSink implements Sink
  {
    private final ArrayDeque<Row> list;

    private ListSink(ArrayDeque<Row> list)
    {
      this.list = list;
    }

    @Override
    public void send(Row row)
    {
      list.add(row);
    }

    @Override
    public void end()
    {
    }

    @SuppressWarnings("deprecation")
    @Override
    public void setSourceEnumerable(Enumerable<Row> enumerable)
    {
      final Enumerator<Row> enumerator = enumerable.enumerator();
      while (enumerator.moveNext()) {
        this.send(enumerator.current());
      }
      enumerator.close();
    }
  }

  /**
   * A {@link Source} backed by an {@link ArrayDeque}.
   */
  private static class ListSource implements Source
  {
    private final ArrayDeque<Row> list;
    @Nullable
    private Iterator<Row> iterator;

    ListSource(ArrayDeque<Row> list)
    {
      this.list = list;
    }

    @Override
    @Nullable
    public Row receive()
    {
      try {
        if (iterator == null) {
          iterator = list.iterator();
        }
        return iterator.next();
      }
      catch (NoSuchElementException e) {
        iterator = null;
        return null;
      }
    }

    @Override
    public void close()
    {
    }
  }

  /**
   * A {@link Sink} that feeds several queues.
   */
  private static class DuplicatingSink implements Sink
  {
    private final List<ArrayDeque<Row>> queues;

    private DuplicatingSink(List<ArrayDeque<Row>> queues)
    {
      this.queues = ImmutableList.copyOf(queues);
    }

    @Override
    public void send(Row row)
    {
      for (ArrayDeque<Row> queue : queues) {
        queue.add(row);
      }
    }

    @Override
    public void end()
    {
    }

    @SuppressWarnings("deprecation")
    @Override
    public void setSourceEnumerable(Enumerable<Row> enumerable)
    {
      final Enumerator<Row> enumerator = enumerable.enumerator();
      while (enumerator.moveNext()) {
        this.send(enumerator.current());
      }
      enumerator.close();
    }
  }

  /**
   * Walks a tree of {@link RelNode}s and creates a {@link Node} for each one, looking for methods of the form
   * {@code visit(XxxRel)} (and {@code rewrite(XxxRel)}) through reflection, like Calcite's own compiler.
   */
  public static class CompilerImpl extends RelVisitor implements Compiler, ReflectiveVisitor
  {
    private static final String REWRITE_METHOD_NAME = "rewrite";
    private static final String VISIT_METHOD_NAME = "visit";

    private final ScalarCompiler scalarCompiler;
    private final ReflectiveVisitDispatcher<CompilerImpl, RelNode> dispatcher =
        ReflectUtil.createDispatcher(CompilerImpl.class, RelNode.class);
    private final DruidInterpreter interpreter;
    private final Map<RelNode, NodeInfo> nodes = new LinkedHashMap<>();
    private final Map<RelNode, List<RelNode>> relInputs = new HashMap<>();
    private final Multimap<RelNode, Edge> outEdges = LinkedHashMultimap.create();
    @Nullable
    private RelNode rootRel;
    @Nullable
    private RelNode rel;
    @Nullable
    private Node node;

    CompilerImpl(DruidInterpreter interpreter, ScalarCompiler scalarCompiler)
    {
      this.interpreter = interpreter;
      this.scalarCompiler = scalarCompiler;
    }

    Pair<RelNode, Map<RelNode, NodeInfo>> visitRoot(RelNode p)
    {
      rootRel = p;
      visit(p, 0, null);
      return Pair.of(Objects.requireNonNull(rootRel, "rootRel"), nodes);
    }

    @Override
    public void visit(RelNode p, int ordinal, @Nullable RelNode parent)
    {
      for (;;) {
        rel = null;
        final boolean found = dispatcher.invokeVisitor(this, p, REWRITE_METHOD_NAME);
        if (!found) {
          throw new IllegalStateException("No implementation for rewrite");
        }
        if (rel == null) {
          break;
        }
        p = Objects.requireNonNull(rel, "rel");
        if (parent != null) {
          List<RelNode> inputs = relInputs.get(parent);
          if (inputs == null) {
            inputs = Lists.newArrayList(parent.getInputs());
            relInputs.put(parent, inputs);
          }
          inputs.set(ordinal, p);
        } else {
          rootRel = p;
        }
      }

      // Rewrite children first, from left to right.
      final List<RelNode> inputs = relInputs.get(p);
      final RelNode finalP = p;
      Ord.forEach(Util.first(inputs, p.getInputs()), (r, i) -> outEdges.put(r, new Edge(finalP, i)));
      if (inputs != null) {
        for (int i = 0; i < inputs.size(); i++) {
          visit(inputs.get(i), i, p);
        }
      } else {
        p.childrenAccept(this);
      }

      node = null;
      final boolean found = dispatcher.invokeVisitor(this, p, VISIT_METHOD_NAME);
      if (!found) {
        if (p instanceof InterpretableRel) {
          node = ((InterpretableRel) p).implement(
              new InterpretableRel.InterpreterImplementor(this, null, DataContexts.EMPTY)
          );
        } else {
          throw new IllegalStateException("No interpreter implementation for rel class[" + p.getClass() + "]");
        }
      }
      final NodeInfo nodeInfo = Objects.requireNonNull(nodes.get(p), "nodeInfo");
      nodeInfo.node = node;
      if (inputs != null) {
        for (int i = 0; i < inputs.size(); i++) {
          visit(inputs.get(i), i, p);
        }
      }
    }

    /**
     * Fallback rewrite method. Overloads with a more specific {@link RelNode} parameter set {@link #rel} to rewrite.
     */
    public void rewrite(RelNode r)
    {
    }

    public void visit(Aggregate agg)
    {
      node = new AggregateNode(this, agg);
    }

    public void visit(Filter filter)
    {
      node = new FilterNode(this, filter);
    }

    public void visit(Project project)
    {
      node = new ProjectNode(this, project);
    }

    public void visit(Values value)
    {
      node = new ValuesNode(this, value);
    }

    public void visit(TableScan scan)
    {
      node = TableScanNode.create(this, scan, ImmutableList.of(), null);
    }

    public void visit(Bindables.BindableTableScan scan)
    {
      node = TableScanNode.create(this, scan, scan.filters, scan.projects);
    }

    public void visit(TableFunctionScan functionScan)
    {
      node = TableFunctionScanNode.create(this, functionScan);
    }

    public void visit(Sort sort)
    {
      node = new SortNode(this, sort);
    }

    public void visit(SetOp setOp)
    {
      node = new SetOpNode(this, setOp);
    }

    public void visit(Join join)
    {
      node = new JoinNode(this, join);
    }

    public void visit(Window window)
    {
      node = new WindowNode(this, window);
    }

    public void visit(Match match)
    {
      node = new MatchNode(this, match);
    }

    public void visit(Collect collect)
    {
      node = new CollectNode(this, collect);
    }

    public void visit(Uncollect uncollect)
    {
      node = new UncollectNode(this, uncollect);
    }

    @Override
    public Scalar compile(List<RexNode> nodes, @Nullable RelDataType inputRowType)
    {
      final RelDataType rowType = inputRowType != null ? inputRowType : getTypeFactory().builder().build();
      return scalarCompiler.compile(nodes, rowType, interpreter.dataContext);
    }

    private RelDataTypeFactory getTypeFactory()
    {
      return interpreter.dataContext.getTypeFactory();
    }

    @Override
    public RelDataType combinedRowType(List<RelNode> inputs)
    {
      final RelDataTypeFactory.Builder builder = getTypeFactory().builder();
      for (RelNode input : inputs) {
        builder.addAll(input.getRowType().getFieldList());
      }
      return builder.build();
    }

    @Override
    public Source source(RelNode rel, int ordinal)
    {
      final RelNode input = getInput(rel, ordinal);
      final Edge edge = new Edge(rel, ordinal);
      final Collection<Edge> edges = outEdges.get(input);
      final NodeInfo nodeInfo = nodes.get(input);
      if (nodeInfo == null) {
        throw new IllegalStateException("Rel[" + rel + "] should be registered");
      }
      if (nodeInfo.rowEnumerable != null) {
        return new EnumeratorSource(nodeInfo.rowEnumerable.enumerator());
      }
      if (nodeInfo.sinks.size() != edges.size()) {
        throw new IllegalStateException("Rel[" + rel + "] has mismatched sinks and edges");
      }
      final ListSink sink = nodeInfo.sinks.get(edge);
      if (sink != null) {
        return new ListSource(sink.list);
      }
      throw new IllegalStateException("No source for edge[" + edge + "] of rel[" + rel + "]");
    }

    private RelNode getInput(RelNode rel, int ordinal)
    {
      final List<RelNode> inputs = relInputs.get(rel);
      if (inputs != null) {
        return inputs.get(ordinal);
      }
      return rel.getInput(ordinal);
    }

    @Override
    public Sink sink(RelNode rel)
    {
      final Collection<Edge> edges = outEdges.get(rel);
      final Collection<Edge> edges2 = edges.isEmpty() ? ImmutableList.of(new Edge(null, 0)) : edges;
      NodeInfo nodeInfo = nodes.get(rel);
      if (nodeInfo == null) {
        nodeInfo = new NodeInfo(rel, null);
        nodes.put(rel, nodeInfo);
        for (Edge edge : edges2) {
          nodeInfo.sinks.put(edge, new ListSink(new ArrayDeque<>()));
        }
      } else {
        for (Edge edge : edges2) {
          if (!nodeInfo.sinks.containsKey(edge)) {
            nodeInfo.sinks.put(edge, new ListSink(new ArrayDeque<>()));
          }
        }
      }
      if (edges.size() == 1) {
        return Iterables.getOnlyElement(nodeInfo.sinks.values());
      }
      final List<ArrayDeque<Row>> queues = new ArrayList<>();
      for (ListSink sink : nodeInfo.sinks.values()) {
        queues.add(sink.list);
      }
      return new DuplicatingSink(queues);
    }

    @Override
    public void enumerable(RelNode rel, Enumerable<Row> rowEnumerable)
    {
      nodes.put(rel, new NodeInfo(rel, rowEnumerable));
    }

    @Override
    public Context createContext()
    {
      return new Context(getDataContext());
    }

    @Override
    public DataContext getDataContext()
    {
      return interpreter.dataContext;
    }
  }

  /**
   * Edge between a {@link RelNode} and one of its inputs.
   */
  private static class Edge extends Pair<RelNode, Integer>
  {
    Edge(@Nullable RelNode parent, int ordinal)
    {
      super(parent, ordinal);
    }
  }
}
