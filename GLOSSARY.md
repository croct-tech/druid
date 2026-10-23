# Croct Druid fork

`croct-tech/druid` is Croct's fork of Apache Druid. It tracks upstream `master` and carries a small set of fork patches, each recorded in `docs/adr/`.

## Language

### Fork

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

### Ingestion

**Scheduled supervisor**:
A streaming supervisor that ingests in ingestion cycles at fixed times instead of continuously.
_Avoid_: Batch supervisor, periodic supervisor

**Ingestion cycle**:
One pass of a scheduled supervisor that reads every partition from its committed offset up to its target offset.
_Avoid_: Run, batch, round

**Target offset**:
The latest offset of a partition when an ingestion cycle starts; the cycle reads up to it and no further.
_Avoid_: End offset, cutoff
