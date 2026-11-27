-- Persist synthetic setup only inside the owned native fixture.
\set keep_reference_transaction 1
\ir 30-reference-catalog.sql
\unset keep_reference_transaction
INSERT INTO governance.actors(database_role,display_name) VALUES(NULL,'Group concurrency editor') RETURNING actor_id AS editor \gset
INSERT INTO access.accounts(actor_id,login_name,role,state) VALUES(:'editor','group-race-editor','moderator','active') RETURNING account_id AS editor_account \gset
INSERT INTO access.sessions(account_id,token_hash,method,second_factor,expires_at) VALUES(:'editor_account',encode(sha256(convert_to('group-race-editor','UTF8')),'hex'),'oidc',true,clock_timestamp()+interval '1 day');
SET SESSION AUTHORIZATION egi_probe30;
SELECT preparation.set_grant(:'ws',:'editor','edit',(preparation.read_workspace(:'ws')->>'metadata_revision')::bigint,gen_random_uuid());
SELECT preparation.read_item(:'ws',:'item',NULL)->'version' AS current \gset
SELECT gen_random_uuid() AS gid,gen_random_uuid() AS version \gset
SELECT jsonb_build_object('group_id',:'gid','version',:'version','parent_versions','[]'::jsonb,'preparation_id',:'ws','context','{}'::jsonb,'mapping',NULL,'state','proposed','method','manual','proposal_id',NULL,
 'members',jsonb_build_array(jsonb_build_object('item_id',:'item','expected_version',:'current'::jsonb->>'id','basis_kind','source_fact','basis_id',:'catfid'))) AS group_body \gset
SELECT preparation.save_group(:'ws',NULL,:'group_body',gen_random_uuid())->'group'->>'version';
RESET SESSION AUTHORIZATION;
CREATE TABLE public.egi_workbench_group_race(workspace_id uuid,expected uuid,body jsonb);
INSERT INTO public.egi_workbench_group_race VALUES(:'ws',:'version',:'group_body');
GRANT SELECT ON public.egi_workbench_group_race TO egi_probe30;
-- Widen the read/write overlap so a missing serialization seam would be visible.
CREATE FUNCTION public.egi_group_race_delay() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(0.5); RETURN NEW; END $$;
CREATE TRIGGER egi_group_race_delay BEFORE UPDATE ON preparation.private_groups FOR EACH ROW EXECUTE FUNCTION public.egi_group_race_delay();
COMMIT;
