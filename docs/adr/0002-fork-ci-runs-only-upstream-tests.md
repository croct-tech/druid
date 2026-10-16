---
Status: accepted
Upstream: fork-only
---

# Fork CI runs only upstream's test workflows

Most of upstream's GitHub workflows serve the ASF project rather than this fork: backports, milestones, PR labeling, the stale bot, PR title checks, CodeQL, OWASP scans and the static checks. Some were already gated to `apache/druid`; the rest spent runner time on checks nobody here acts on. We deleted every workflow except the test pipeline: `unit-and-integration-tests-unified.yml` and the reusable `ci.yml`, `docker-tests.yml` and `worker.yml` it calls. The only other workflows are the fork's own, such as `release.yml` (ADR-0003).

The test pipeline's triggers changed too. It runs when a PR is opened or synchronized, whatever its base branch or the paths it touches, and on every push to `master`. Upstream's path filters are gone so that every PR reports the same checks, which can then be required for merging.

We kept the scripts and configs that only the deleted workflows used (most of `.github/scripts/`, `.github/labeler.yml`, `.github/config/codeql-config.yml`). They're inert, the static check scripts still run locally, and deleting them would only add more modify/delete conflicts to upstream syncs.

## Consequences

- Upstream edits its workflows often (action bumps touch every file), so upstream syncs hit modify/delete conflicts on the deleted workflows. Resolve them by keeping the file deleted.
- A workflow that upstream adds arrives without a conflict. Delete it in the sync merge unless the test pipeline calls it.
- On a conflict in the `on:` block of `unit-and-integration-tests-unified.yml`, keep the fork's triggers. Take upstream's changes to the rest of the file, such as new jobs.
