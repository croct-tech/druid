# SQL MODULE

SQL-to-native translation layer built on Apache Calcite. Parses SQL, plans with cost-based optimizer, converts to Druid native queries.

## STRUCTURE

```
sql/src/main/java/org/apache/druid/sql/
├── calcite/
│   ├── planner/        # DruidPlanner: parse → validate → plan → convert
│   ├── rel/            # DruidRel, DruidQuery, PartialDruidQuery
│   ├── rule/           # DruidRules: Calcite→Druid transformations
│   ├── expression/     # SQL→Druid expression conversion
│   │   └── builtin/    # SqlOperatorConversion implementations (74 files)
│   ├── schema/         # DruidSchema, SegmentMetadataCache
│   └── aggregation/    # SQL aggregation→AggregatorFactory mapping
├── http/               # SQL REST endpoint (/druid/v2/sql)
└── avatica/            # JDBC (Avatica) server
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add a SQL function | `calcite/expression/builtin/` | Implement `SqlOperatorConversion`, register in `DruidOperatorTable` |
| SQL planning lifecycle | `calcite/planner/DruidPlanner.java` | validate → authorize → plan |
| Calcite→Druid rules | `calcite/rule/DruidRules.java` | Transforms logical plan to `DruidRel` tree |
| Native query building | `calcite/rel/DruidQuery.java` | 1741 lines. Maps `PartialDruidQuery` → native query type |
| Expression conversion | `calcite/expression/Expressions.java` | `RexNode` → Druid expression translation |
| SQL tests (Quidem) | `src/test/quidem/` | `.iq` files: SQL + expected plan + results |

## QUERY LIFECYCLE

1. **Parse**: SQL → Calcite `SqlNode` (forked Calcite parser with Druid extensions: `INSERT`, `REPLACE`)
2. **Validate**: `DruidSqlValidator` — type checking + resource identification for authz
3. **Plan**: `SqlNode` → `RelRoot` via `DruidSqlToRelConverter`. `VolcanoPlanner` applies `DruidRules`
4. **Convert**: `DruidRel` tree → `PartialDruidQuery` (builder) → `DruidQuery` (native)
5. **Execute**: `QueryMaker` runs the native query via `QueryRunner` pipeline

## KEY ABSTRACTIONS

- **`DruidRel`** — Calcite `RelNode` subclass for Druid-executable operations
- **`PartialDruidQuery`** — state machine builder: accumulates Scan/Filter/Project/Aggregate/Sort
- **`DruidQuery`** — final native query representation with `DataSource`, `DimFilter`, `AggregatorFactory` list
- **`SqlOperatorConversion`** — maps a SQL operator to a Druid expression or aggregator

## ANTI-PATTERNS

- **Never use `OperandTypes.LITERAL`** from Calcite — throws on CAST literals. Use `DefaultOperandTypeChecker`
- **Never use other `OperandTypes.*_LITERAL`** variants — see `druid-forbidden-apis.txt` lines 66-72
- Calcite parser is **forked** — update via `dev/upgrade-calcite-parser` script, not direct dependency upgrade

## TESTING

- **Quidem tests** (`.iq` files): preferred for new SQL features. Test both plan and results
- **`CalciteQueryTest`**: legacy Java-based SQL tests. `DecoupledPlanningCalciteQueryTest` inherits from it
- **`SqlQuidemTest`** + `DruidQuidemCommandHandler`: Quidem runner for Druid
