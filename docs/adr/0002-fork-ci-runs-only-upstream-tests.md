---
Status: accepted
Upstream: fork-only
---

# Fork CI runs only upstream's test workflows

Most of upstream's GitHub workflows serve the ASF project rather than this fork: backports, milestones, PR labeling, the stale bot, PR title checks, CodeQL, OWASP scans and the static checks. Some were already gated to `apache/druid`; the rest spent runner time on checks nobody here acts on. We deleted every workflow except the test pipeline: `ci.yml` and the reusable `ci-jobs.yml`, `docker-tests.yml` and `worker.yml` it calls. The only other workflows are the fork's own, such as `release.yml` (ADR-0003).

The test pipeline's triggers changed too. It runs when a PR is opened or synchronized, whatever its base branch, and on every push to `master`.

We used to remove upstream's path filters as well, so that every PR reported the same checks and they could be required for merging. Upstream has since solved that itself (apache/druid#20878, apache/druid#20902): `ci.yml` starts for every PR and ends in a `quality-gate` job that always reports, and a `changes` job in `ci-jobs.yml` skips the Java jobs when a PR touches only docs, the web console or other files the tests don't use. The fork keeps upstream's implementation. `quality-gate` is the check to require for merging.

We kept the scripts and configs that only the deleted workflows used (most of `.github/scripts/`, `.github/labeler.yml`, `.github/config/codeql-config.yml`). They're inert, the static check scripts still run locally, and deleting them would only add more modify/delete conflicts to upstream syncs.

## Consequences

- Upstream edits its workflows often (action bumps touch every file), so upstream syncs hit modify/delete conflicts on the deleted workflows. Resolve them by keeping the file deleted.
- A workflow that upstream adds arrives without a conflict. Delete it in the sync merge unless the test pipeline calls it.
- Upstream runs its static checks from `ci-jobs.yml`: `static-checks-maven`, `strict-compilation`, `packaging-check` and `web-checks`. Keep them out of the fork's `ci-jobs.yml`, like any other static check upstream adds there.
- Upstream renamed the workflows in apache/druid#20902: `unit-and-integration-tests-unified.yml` became `ci.yml`, and the reusable `ci.yml` became `ci-jobs.yml`.
- On a conflict in the `on:` block of `ci.yml`, keep the fork's triggers. Take upstream's changes to the rest of the file, such as new jobs.
