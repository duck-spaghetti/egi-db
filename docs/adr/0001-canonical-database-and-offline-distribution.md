# One authoritative dataset with derived offline distributions

Accepted user requirement, 2026-10-05. PostgreSQL/PostGIS is EGI's authoritative
database; a future SQLite file is a lightweight read-only distribution generated
from its canonical dataset. Two independently editable databases are excluded
because they would introduce competing identities, editorial decisions and
synchronization rules. The core relationships should remain portable, while
PostgreSQL/PostGIS-specific capabilities stay behind explicit projection/export
boundaries. Export contents, public redaction and update packaging remain design
decisions; this requirement does not approve an exporter implementation.
