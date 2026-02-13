# WEB CONSOLE

React/TypeScript management UI for Apache Druid. Data loading wizard, query workbench, cluster monitoring.

## STRUCTURE

```
web-console/src/
├── views/              # Page-level components (workbench, datasources, segments, etc.)
├── components/         # Reusable UI components (header-bar, table-cell, show-log)
├── dialogs/            # Modal interactions (compaction-config, doctor-dialog)
├── druid-models/       # TypeScript interfaces for Druid entities (ingestion-spec, etc.)
├── singletons/         # Global instances (api.ts for Axios, toaster.ts)
├── utils/              # Shared utilities (49 files)
├── contexts/           # React contexts (SqlFunctionsProvider)
└── console-application.tsx  # Main entry + HashRouter routing
```

## TECH STACK

- **React** 18 + **TypeScript** 5.5
- **Blueprint.js** 5 — UI component library (all controls)
- **Zustand** 4 — state management (e.g., `work-state-store.ts`)
- **React Router** 5 — `HashRouter` (`#/workbench`, `#/datasources`)
- **Webpack** 5 — bundler with `ts-loader` and `sass-loader`
- **Ace Editor** — SQL query editor via `react-ace`
- **D3 / ECharts** — data visualizations
- **druid-query-toolkit** — SQL parsing and manipulation

## COMMANDS

```bash
npm install            # Install dependencies
npm start              # Dev server (proxies to localhost:8888)
npm run compile        # Production build
npm test               # Jest tests
npm run autofix        # ESLint + Prettier + Stylelint auto-fix (MUST run before PRs)
```

## CONVENTIONS

- **Linting**: ESLint (`@awesome-code-style`), Prettier, Stylelint. `npm run autofix` before submit
- **Testing**: Jest snapshot tests for components, unit tests for models
- **Styles**: SCSS files colocated with components. Blueprint.js theme variables
- **State**: Zustand stores for complex state (workbench). Class component state for simpler views
- **API calls**: Through `singletons/api.ts` (Axios instance). Never raw `fetch`
- **Apache license header** required on all source files
- Build integrated into Maven — skip with `-Dweb.console.skip=true` for backend-only work
