BEGIN;
SELECT 'preparation.interpretation_identities'::regclass;
SELECT 'preparation.interpretation_basis(uuid,jsonb)'::regprocedure;
SELECT 'preparation.guard_interpretation_version()'::regprocedure;
SELECT 1/CASE WHEN NOT has_table_privilege('egi_editorial','preparation.interpretation_identities','SELECT') THEN 1 ELSE 0 END;
ROLLBACK;
