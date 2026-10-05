BEGIN;
SELECT adoption_id,release_id,territory_id FROM taxonomy.assignments WHERE false;
SELECT term_revision_id FROM taxonomy.release_terms WHERE false;
SELECT 1/count(*) FROM pg_trigger WHERE tgrelid='taxonomy.broader_links'::regclass AND tgname='acyclic';
ROLLBACK;
