-- EGI-114: run the same isolated job/ledger lifecycle with explicit v2 results.
-- The shared fixture also runs as v1 in contract20; do not duplicate the engine.
\set facts_protocol 2
\ir 20-preparation-jobs.sql
\unset facts_protocol

-- An older v1 job may update other untouched fields on a v2 card, but must not
-- erase its literal fact/manual value. Persistence/CAS is exercised in contracts20/28.
BEGIN;
DO $$ DECLARE before jsonb; candidate jsonb; merged jsonb; BEGIN
 before:='{"schema_version":2,"service":{},"location":{"kind":"none"},"target":{"kind":"new"},"field_origins":{},"evidence":[],"outcome":"review","source_facts":[{"fact_id":"10000000-0000-0000-0000-000000000099","subject":"service","kind":"category_label","source_value":"Source label","value":"Manual correction"}],"resolutions":[]}';
 candidate:='{"service":{"description":"new description"},"location":{"kind":"none"},"evidence":[]}';
 merged:=preparation.merge_candidate(before,candidate,gen_random_uuid(),gen_random_uuid())->'payload';
 PERFORM pg_temp.assert_true(merged->'source_facts'=before->'source_facts' AND merged->'schema_version'='2'::jsonb,'v1 update preserves v2 source claims');
END $$;
ROLLBACK;
