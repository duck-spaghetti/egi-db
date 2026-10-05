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

## Selected tools and checks

Sqitch manages structural changes through numbered atomic deploy/revert/verify
triplets. The selected native runtime and executable contract runner are documented
in docs/implementation/setup.md. A data bootstrap is separate from schema deployment; live source
content and detailed taxonomy are not automatically embedded in migrations.

Future SQL will use explicit schema qualification and approved integrity contracts.
New indexes, PostgreSQL-only features and portability transformations must be
supported by the agreed query/export requirements. Raw source data remains evidence;
canonical changes must have traceable decisions and supporting assertions.

## Verification planning

The design scenarios are mapped to executable contracts in the acceptance matrix.
Sqitch verify scripts establish deployed structure and constraints without
depending on mutable production service data. Separate fixtures should exercise
provenance conflicts, repeated imports, cardinalities, geometry, hours and export
selection. A successful schema deploy alone does not verify those behaviors.

HSDS serialization must eventually be checked against the selected pinned JSON
schemas. SQLite exports need referential integrity, consistent identifiers,
publication filtering, coordinate consistency and consumer-version checks.
Spatial query tests require PostgreSQL/PostGIS when those operations are in scope.
The selected runner uses native psql/Sqitch and synthetic SQL fixtures. No CI,
Python test runner, linter or typing checker is introduced.

## First implementation checkpoint

The #1–#4 group now supplies Sqitch deploy/revert/verify changes and native SQL
contract fixtures. Read the setup/operations guides under docs/implementation for
the actual commands and controlled-write contract. Synthetic fixtures remain
separate from real-data bootstrap. Future migrations extend owned-aggregate restore
and its checks when they add versioned child tables. Preserve immutable released
migrations after the explicitly authorized four-change initial rebaseline.

If the shared parent guides are absent in a standalone clone/worktree, use the
[worktree baseline](worktree-baseline.md) and the database-specific execution record.
