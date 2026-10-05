BEGIN;
SELECT snapshot_sequence FROM api.public_sequence;
SELECT source_id,name,homepage,license FROM api.source_attributions WHERE false;
SELECT 1/(has_function_privilege('egi_reader','api.directory_snapshot(uuid,text,jsonb,timestamptz,boolean)','EXECUTE')::integer);
ROLLBACK;
