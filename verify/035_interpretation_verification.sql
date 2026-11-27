BEGIN;
SELECT 1/CASE WHEN position('jsonb_array_elements(v.evidence) trigger_quote' IN pg_get_functiondef('preparation.validate_payload(uuid,jsonb)'::regprocedure))>0 THEN 1 ELSE 0 END;
ROLLBACK;
