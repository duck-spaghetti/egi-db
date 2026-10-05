# Database design and future implementation standards

Read the [shared standards](../../../docs/agents/standards.md) for general
documentation and Python rules. The following specialize this database component.

## Current design work

Keep approved requirements, observed draft behavior and proposed architecture
visibly distinct. Cite pinned HSDS references in the design. Maintain a mapping of
adopted concepts, adaptations, EGI extensions and explicitly deferred concepts.
An internal model compatible with HSDS concepts does not establish export validity
or conformance to HSDS API protocols.

Preserve the authoritative English vocabulary in [GLOSSARY.md](../../GLOSSARY.md).
Record domain terms as they are settled. Use ADRs for consequential trade-offs;
proposed choices remain labelled in the design until selected.

## Selected tools, not configured checks

Sqitch is selected to manage future structural changes. Deployment, revert and
verification scripts, project configuration, targets and runtime versions have
not been created. A data bootstrap is separate from schema deployment; live source
content and detailed taxonomy are not automatically embedded in migrations.

Future SQL will use explicit schema qualification and approved integrity contracts.
New indexes, PostgreSQL-only features and portability transformations must be
supported by the agreed query/export requirements. Raw source data remains evidence;
canonical changes must have traceable decisions and supporting assertions.

## Verification planning

The design contains acceptance scenarios rather than executable tests. Future
Sqitch verify scripts should establish deployed structure and constraints without
depending on mutable production service data. Separate fixtures should exercise
provenance conflicts, repeated imports, cardinalities, geometry, hours and export
selection. A successful schema deploy alone does not verify those behaviors.

HSDS serialization must eventually be checked against the selected pinned JSON
schemas. SQLite exports need referential integrity, consistent identifiers,
publication filtering, coordinate consistency and consumer-version checks.
Spatial query tests require PostgreSQL/PostGIS when those operations are in scope.
No test runner, CI, linter or typing checker is selected by this documentation task.
