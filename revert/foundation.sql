-- Revert egi_database:foundation from pg. Disposable target only.
BEGIN;
DROP SCHEMA api CASCADE;
DROP SCHEMA taxonomy CASCADE;
DROP SCHEMA geo CASCADE;
DROP SCHEMA sources CASCADE;
DROP SCHEMA audit CASCADE;
DROP SCHEMA i18n CASCADE;
DROP SCHEMA governance CASCADE;
DROP SCHEMA data CASCADE;
-- Retain the pre-existing PostGIS extension and public-schema ACL.
COMMIT;
