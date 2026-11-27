-- Verify egi_database:027_preparation_category_matches
BEGIN;
SELECT 1/(to_regprocedure('preparation.matching_resolutions(jsonb,jsonb,jsonb)') IS NOT NULL)::int;
SELECT 1/(NOT has_function_privilege('egi_preparation_worker','preparation.validate_matching_context(jsonb)','EXECUTE'))::int;
SELECT 1/(NOT has_function_privilege('egi_editorial','preparation.matching_resolutions(jsonb,jsonb,jsonb)','EXECUTE'))::int;
SELECT 1/(preparation.canonical_json('{"z":[true,null,"Caffè"],"a":1}')='{"a":1,"z":[true,null,"Caffè"]}')::int;
SELECT 1/(encode(sha256(convert_to(preparation.canonical_json('{"z":[true,null,"Caffè"],"a":1}'),'UTF8')),'hex')='9544cd924c9e1b36939b292dd3b977c282ae62a13d85e5f1d37d6429847fdae2')::int;
ROLLBACK;
