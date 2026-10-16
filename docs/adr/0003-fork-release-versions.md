---
Status: accepted
Upstream: fork-only
---

# Fork releases are versioned `<included release>-croct.<fork commits>`

A maintainer cuts fork releases by running the `Release` workflow (`.github/workflows/release.yml`) on `master`. It versions the release `<included release>-croct.<fork commits>`, for example `38.0.0-croct.6`, and creates a GitHub release and tag with that name. It then builds the distribution with that as the Maven project version, so `/status` reports it, and pushes `crocttech/druid:<version>` to Docker Hub. Finally it reports the image to the deployment service at `UPDATE_ENDPOINT`, the same way `croct-tech/sessionizer-stream` does.

**Included release.** Upstream tags each release on its release branch, never on `master`, so no `druid-X.Y.Z` tag is an ancestor of our `master`. A release counts as included once our `master` contains the upstream `master` commit its release branch forked from (`git merge-base <tag> upstream/master`). RC tags don't count. The fork's code is ahead of the included release, because it tracks upstream `master` rather than the release branch, and it lacks that branch's backports.

**Fork commits.** These are the commits on our `master` that aren't on upstream `master` (`git rev-list --count upstream/master..HEAD`), merge commits included. Counting the upstream sync merges gives every commit on `master` a distinct version, even when a sync brings in no new release. The count never resets when the included release changes, because `master` is never rewritten.

We rejected naming releases after the POM version (upstream `master` is `39.0.0-SNAPSHOT`, so `39.0.0-croct.N`), which is how the earlier hand-built images such as `37.0.0-kafka-fix` were named: it names an upstream release that doesn't exist yet.

## Consequences

- Only `master` can be released; the workflow skips other branches. The commit count identifies a commit only along `master`'s history.
- A given commit always gets the same version, so re-running a failed release reuses the GitHub release it already created.
- The workflow needs the `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `GCLOUD_WORKLOAD_IDENTITY`, `GCLOUD_SERVICE_ACCOUNT` and `UPDATE_ENDPOINT` secrets.
