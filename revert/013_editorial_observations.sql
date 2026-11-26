-- Revert egi_database:013_editorial_observations
-- The source goes too when no observation was recorded; otherwise the revert refuses
-- (source records are immutable), and the observations stay.
BEGIN;
DROP FUNCTION editorial.record_observation(text,jsonb,text,text);
DELETE FROM sources.datasets WHERE external_key='observations'
 AND source_id=(SELECT source_id FROM sources.registry WHERE code='egi_editorial');
DELETE FROM sources.registry WHERE code='egi_editorial';
COMMIT;
