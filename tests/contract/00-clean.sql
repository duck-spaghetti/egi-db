-- Structural deployment must not populate domain data. Run before synthetic fixtures.
BEGIN;
SELECT 1 / (NOT EXISTS(SELECT FROM data.entities))::integer AS no_domain_seed;
SELECT 1 / (NOT EXISTS(SELECT FROM sources.registry))::integer AS no_source_seed;
SELECT 1 / (NOT EXISTS(SELECT FROM governance.actors))::integer AS no_actor_seed;
SELECT 1 / (NOT EXISTS(SELECT FROM taxonomy.releases))::integer AS no_real_taxonomy_seed;
SELECT current_database(),current_setting('server_version'),postgis_lib_version();
ROLLBACK;
