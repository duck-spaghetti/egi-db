-- EGI-106: prevent cross-component scalar proof from implying a false combination.
BEGIN;
\ir helpers.sql
DO $$ DECLARE original jsonb; proposed jsonb; citation jsonb; BEGIN
 original:='{"service":{"contacts":[{"channel_type":"phone","value":"111","label":"Info"},{"channel_type":"phone","value":"222","label":"Urgent"}]}}';
 proposed:='{"service":{"contacts":[{"channel_type":"phone","value":"111","label":"Urgent"}]}}';
 citation:='{"path":"/service/contacts/1","kind":"stated"}';
 PERFORM pg_temp.assert_true(NOT editorial.community_locator_supports(original,proposed,ARRAY['service','contacts','1','label'],ARRAY['service','contacts','0','label'],citation),'another contact label cannot support a new number/label association');
 proposed:='{"service":{"contacts":[{"channel_type":"phone","value":"222","label":"Urgent"}]}}';
 PERFORM pg_temp.assert_true(editorial.community_locator_supports(original,proposed,ARRAY['service','contacts','1','label'],ARRAY['service','contacts','0','label'],citation),'moving the same submitted contact remains supported');
 original:='{"service":{"schedules":[{"scope":"service","days":[{"weekday":1,"intervals":[{"opens":"09:00","closes":"12:00"},{"opens":"10:00","closes":"18:00"}]}]}]}}';
 proposed:='{"service":{"schedules":[{"scope":"service","days":[{"weekday":1,"intervals":[{"opens":"09:00","closes":"18:00"}]}]}]}}';
 citation:='{"path":"/service/schedules/0/days/0/intervals/1","kind":"interpreted"}';
 PERFORM pg_temp.assert_true(NOT editorial.community_locator_supports(original,proposed,
  ARRAY['service','schedules','0','days','0','intervals','1','closes'],ARRAY['service','schedules','0','days','0','intervals','0','closes'],citation),'two intervals cannot silently become a longer opening');
END $$;
ROLLBACK;
