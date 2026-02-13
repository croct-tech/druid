# PROCESSING MODULE

Core data engine — queries, segments, expressions, data input. Largest module (2496 main files). Headless: no server/HTTP dependencies.

## STRUCTURE

```
processing/src/main/java/org/apache/druid/
├── query/              # Query types, runners, toolchests, aggregations, filters
│   ├── aggregation/    # AggregatorFactory, BufferAggregator implementations
│   ├── groupby/        # GroupBy engine (epinephelinae)
│   ├── topn/           # TopN engine
│   ├── scan/           # Scan query (raw row retrieval)
│   ├── timeseries/     # Timeseries engine
│   └── filter/         # DimFilter implementations
├── segment/            # Segment format, cursors, column selectors, indexes
│   ├── data/           # Column data readers/writers
│   ├── nested/         # Nested JSON column support
│   ├── column/         # ColumnHolder, ColumnCapabilities
│   └── virtual/        # VirtualColumn (computed at query time)
├── data/input/         # InputSource, InputFormat, InputRow (ingestion API)
│   └── impl/           # Built-in implementations (JSON, CSV, TSV, etc.)
├── math/expr/          # Expression language: Expr, ExprEval, Function
│   └── vector/         # Vectorized expression processors
├── java/util/          # Druid utility classes (Closer, FileUtils, Execs, etc.)
├── timeline/           # VersionedIntervalTimeline, segment lookup
└── guice/              # Core Guice modules and bindings
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| New query type | `query/` | Implement `Query<T>`, `QueryToolChest`, `QueryRunnerFactory` |
| New aggregation | `query/aggregation/` | Implement `AggregatorFactory` + `BufferAggregator` + `VectorAggregator` |
| New filter | `query/filter/` | Implement `DimFilter` (JSON) + `Filter` (execution) |
| New expression func | `math/expr/Function.java` | Inner class implementing `Function`. 4780-line file |
| New input source | `data/input/` | Implement `InputSource` + `InputFormat` |
| Segment read path | `segment/CursorFactory.java` | Creates `Cursor` from `CursorBuildSpec` |
| Column selectors | `segment/ColumnSelectorFactory.java` | `ColumnValueSelector`, `DimensionSelector` |
| Nested columns | `segment/nested/` | `NestedFieldVirtualColumn`, `NestedFieldColumnIndexSupplier` |

## KEY ABSTRACTIONS

- **`Query<T>`** → root interface for native queries. Each type has `QueryRunner` + `QueryToolChest`
- **`Segment`** → queryable data unit. `segment.as(CursorFactory.class)` to read
- **`CursorFactory`** → builds `Cursor` instances from `CursorBuildSpec`
- **`Cursor`** → row iterator. Provides `ColumnSelectorFactory` for column access
- **`QueryableIndex`** → immutable memory-mapped segment. Direct column/index access
- **`IncrementalIndex`** → mutable in-memory segment for real-time ingestion
- **`AggregatorFactory`** → defines aggregation computation and serialization
- **`Expr`** → expression AST node. `eval(ObjectBinding)` for scalar, `ExprVectorProcessor` for batch
- **`InputSource`** → storage abstraction (S3, local, HDFS). `InputFormat` → parser (JSON, CSV)

## CONVENTIONS

- Aggregations must implement both buffer-based (`BufferAggregator`) and vector-based (`VectorAggregator`) paths
- Expression functions: scalar in `Function.java`, macros in `ExprMacroTable`
- `Sequence<T>` is the streaming result type — NOT Java streams. Yielders for lazy consumption

## COMPLEXITY HOTSPOTS

| File | Lines | Why |
|------|-------|-----|
| `math/expr/Function.java` | 4780 | All built-in expression functions as inner classes |
| `groupby/epinephelinae/RowBasedGrouperHelper.java` | 2229 | GroupBy result row assembly |
| `extendedset/intset/ConciseSet.java` | 2179 | Compressed bitmap implementation |
| `segment/nested/NestedFieldColumnIndexSupplier.java` | 1704 | Bitmap indexes for nested JSON |
| `segment/virtual/NestedFieldVirtualColumn.java` | 1631 | Virtual column for nested field extraction |
| `guava/ParallelMergeCombiningSequence.java` | 1563 | Parallel result merging |
| `math/expr/ExprEval.java` | 1546 | Expression evaluation and type coercion |
