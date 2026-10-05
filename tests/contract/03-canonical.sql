BEGIN;
\ir helpers.sql
\ir fixtures.sql
DO $$ DECLARE org uuid; org_revision uuid; place uuid; place_revision uuid; other_place uuid; other_revision uuid; rev uuid; owner uuid; moved uuid; territory uuid; territory_revision uuid; area uuid; draft uuid; BEGIN
 org_revision:=pg_temp.save('organization','{"name":"Shared provider"}');SELECT entity_id INTO org FROM governance.entity_revisions WHERE revision_id=org_revision;
 place_revision:=pg_temp.save('location','{"name":"Castrense","location_kind":"facility","latitude":41.89,"longitude":12.51,"coordinate_state":"known"}');SELECT entity_id INTO place FROM governance.entity_revisions WHERE revision_id=place_revision;
 other_revision:=pg_temp.save('location','{"name":"Tuscolano","location_kind":"facility"}');SELECT entity_id INTO other_place FROM governance.entity_revisions WHERE revision_id=other_revision;
 rev:=pg_temp.save('service',jsonb_build_object('name','First offer','description','Usable physical service','delivery_mode','in_person','place',jsonb_build_object('location_id',place),'organizations',jsonb_build_array(jsonb_build_object('organization_id',org,'role_code','manager'))));SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=rev;
 moved:=pg_temp.save('service',jsonb_build_object('name','First offer','description','Moved physical service','delivery_mode','in_person','place',jsonb_build_object('location_id',other_place)),owner,rev);
 PERFORM pg_temp.assert_true((SELECT entity_id=owner FROM governance.entity_revisions WHERE revision_id=moved),'move keeps identity');
 PERFORM pg_temp.assert_true((SELECT location_id=place FROM data.service_places WHERE revision_id=rev),'old association retained');
 PERFORM pg_temp.assert_true((SELECT latitude=41.89 AND public.ST_X(point)=12.51 AND public.ST_Y(point)=41.89 FROM data.location_revisions WHERE revision_id=place_revision),'derived geometry follows scalar coordinates');
 PERFORM pg_temp.expect_error($q$SELECT pg_temp.save('location','{"location_kind":"facility","latitude":41.89,"coordinate_state":"known"}')$q$,'23514');
 PERFORM pg_temp.expect_error($q$SELECT pg_temp.save('service','{"delivery_mode":"telephone","silently_ignored":true}')$q$,'22023','unsupported_body_field');
 PERFORM pg_temp.expect_error($q$SELECT pg_temp.save('service','{"delivery_mode":"telephone","name":{"bad":true}}')$q$,'22023','text_field_requires_string');
 draft:=pg_temp.save('service','{"delivery_mode":"telephone"}');
 PERFORM pg_temp.assert_true((SELECT count(*)=3 FROM governance.publication_diagnostics(draft)),'incomplete draft gives name description channel diagnostics');
 PERFORM pg_temp.assert_true((SELECT cost_state='unknown' FROM data.service_revisions WHERE revision_id=draft),'missing cost remains unknown');
 territory_revision:=pg_temp.save('territory','{"code":"synthetic-rome","name":"Rome","timezone_name":"Europe/Rome"}');SELECT entity_id INTO territory FROM governance.entity_revisions WHERE revision_id=territory_revision;
 area:=pg_temp.save('service',jsonb_build_object('name','Itinerant area service','description','Known neighborhood, no exact stop','delivery_mode','itinerant','territories',jsonb_build_array(territory),'place',jsonb_build_object('territory_id',territory,'area_description','Known neighborhood'),'conditions',jsonb_build_array(jsonb_build_object('condition_kind','appointment','requirement_state','unknown','details','Call first'))));
 PERFORM pg_temp.assert_true((SELECT location_id IS NULL AND area_description_content_id IS NOT NULL FROM data.service_places WHERE revision_id=area),'area without fabricated point');
 PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM geo.service_memberships WHERE revision_id=area),'map membership independent');
 PERFORM pg_temp.expect_error(format('INSERT INTO data.service_places SELECT * FROM data.service_places WHERE revision_id=%L',area),'55000','sealed_revision');
 -- One building can hold independent offers and independent providers.
 PERFORM pg_temp.save('service',jsonb_build_object('name','Legal advice','description','Independent legal service','delivery_mode','in_person','place',jsonb_build_object('location_id',place)));
 PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM data.service_places WHERE location_id=place),'shared facility with multiple services');
 PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM data.location_organizations WHERE revision_id=place_revision),'provider never inferred as facility operator');
END $$;
ROLLBACK;
