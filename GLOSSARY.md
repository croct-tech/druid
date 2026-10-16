# Croct Druid fork

`croct-tech/druid` is Croct's fork of Apache Druid. It tracks upstream `master` and carries a small set of fork patches, each recorded in `docs/adr/`.

## Language

**Upstream**:
The Apache Druid project, `apache/druid`.
_Avoid_: Apache, origin

**Upstream sync**:
A merge of upstream `master` into the fork's `master`.
_Avoid_: Rebase, update

**Fork commit**:
A commit on the fork's `master` that isn't on upstream `master`, including upstream sync merges.
_Avoid_: Patch, extra commit

**Included release**:
The latest upstream release whose release branch forked from an upstream `master` commit that the fork already contains.
_Avoid_: Base version, current version

**Fork release**:
A release of the fork, named after its included release and its number of fork commits, such as `38.0.0-croct.6`.
_Avoid_: Build, tag
