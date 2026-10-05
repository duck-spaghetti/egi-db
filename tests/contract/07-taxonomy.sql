BEGIN;
\ir helpers.sql
\ir fixtures.sql
DO $$ DECLARE before_sequence bigint; rome uuid; florence uuid; vr uuid; vocab uuid; axis uuid; axis2 uuid; t uuid; parent1 uuid; parent2 uuid; leaf uuid; other uuid; members jsonb:='[]'; edges jsonb; release uuid; adoption uuid; ar uuid; sr uuid; service uuid; fork_vr uuid; fork_v uuid; fork_axis uuid; fork_term uuid; fork_release uuid; BEGIN
 rome:=pg_temp.save('territory','{"code":"rome","name":"Rome","timezone_name":"Europe/Rome"}');PERFORM pg_temp.publish(rome); SELECT entity_id INTO rome FROM governance.entity_revisions WHERE revision_id=rome;
 florence:=pg_temp.save('territory','{"code":"florence","name":"Florence","timezone_name":"Europe/Rome"}');PERFORM pg_temp.publish(florence);SELECT entity_id INTO florence FROM governance.entity_revisions WHERE revision_id=florence;
 vr:=pg_temp.save('taxonomy_vocabulary','{"code":"shared","name":"Shared vocabulary"}');PERFORM pg_temp.publish(vr); SELECT entity_id INTO vocab FROM governance.entity_revisions WHERE revision_id=vr;
 axis:=governance.create_taxonomy_axis(vocab,'need');axis2:=governance.create_taxonomy_axis(vocab,'population');
 t:=pg_temp.save('taxonomy_term',jsonb_build_object('name','Support','vocabulary_id',vocab,'axis_id',axis,'code','support'));PERFORM pg_temp.publish(t);SELECT entity_id INTO parent1 FROM governance.entity_revisions WHERE revision_id=t;members:=members||jsonb_build_array(jsonb_build_object('term_id',parent1,'revision_id',t));
 t:=pg_temp.save('taxonomy_term',jsonb_build_object('name','Care','vocabulary_id',vocab,'axis_id',axis,'code','care'));PERFORM pg_temp.publish(t);SELECT entity_id INTO parent2 FROM governance.entity_revisions WHERE revision_id=t;members:=members||jsonb_build_array(jsonb_build_object('term_id',parent2,'revision_id',t));
 t:=pg_temp.save('taxonomy_term',jsonb_build_object('name','Medical advice','vocabulary_id',vocab,'axis_id',axis,'code','medical'));PERFORM pg_temp.publish(t);SELECT entity_id INTO leaf FROM governance.entity_revisions WHERE revision_id=t;members:=members||jsonb_build_array(jsonb_build_object('term_id',leaf,'revision_id',t));
 t:=pg_temp.save('taxonomy_term',jsonb_build_object('name','Adults','vocabulary_id',vocab,'axis_id',axis2,'code','adults'));PERFORM pg_temp.publish(t);SELECT entity_id INTO other FROM governance.entity_revisions WHERE revision_id=t;members:=members||jsonb_build_array(jsonb_build_object('term_id',other,'revision_id',t));
 edges:=jsonb_build_array(jsonb_build_object('child',leaf,'parent',parent1),jsonb_build_object('child',leaf,'parent',parent2));
 PERFORM pg_temp.expect_error(format('SELECT governance.freeze_taxonomy_release(%L,%L,%L,%L,%L,%L)',vr,'cycle',jsonb_build_array(jsonb_build_object('axis_id',axis,'label','Need'),jsonb_build_object('axis_id',axis2,'label','Population')),members,edges||jsonb_build_array(jsonb_build_object('child',parent1,'parent',leaf)),'Reject cycle'),'23514','taxonomy_cycle');
 PERFORM pg_temp.expect_error(format('SELECT governance.freeze_taxonomy_release(%L,%L,%L,%L,%L,%L)',vr,'cross-axis',jsonb_build_array(jsonb_build_object('axis_id',axis,'label','Need'),jsonb_build_object('axis_id',axis2,'label','Population')),members,jsonb_build_array(jsonb_build_object('child',leaf,'parent',other)),'Reject cross-axis hierarchy'),'23503');
 release:=governance.freeze_taxonomy_release(vr,'v1',jsonb_build_array(jsonb_build_object('axis_id',axis,'label','Need'),jsonb_build_object('axis_id',axis2,'label','Population')),members,edges,'Freeze reviewed exact heads');
 PERFORM pg_temp.expect_error(format('INSERT INTO taxonomy.broader_links VALUES(%L,%L,%L,%L)',release,axis,parent2,parent1),'55000','sealed_taxonomy_release');
 SELECT max(change_sequence) INTO before_sequence FROM audit.public_changes;
 adoption:=governance.adopt_taxonomy_release(rome,release,'2026-01-01',NULL,'Rome adopts v1');
 PERFORM pg_temp.assert_true((SELECT max(change_sequence)>before_sequence FROM audit.public_changes),'adoption advances public sequence in territory without services');
 PERFORM pg_temp.assert_true(EXISTS(SELECT FROM audit.public_changes WHERE entity_id=vocab AND reason='approved_taxonomy_adoption'),'adopted metadata change retains publication lineage');
 PERFORM pg_temp.expect_error(format('SELECT governance.adopt_taxonomy_release(%L,%L,%L,NULL,%L)',rome,release,'2026-02-01','overlap'),'23514','overlapping_taxonomy_adoption');
 sr:=pg_temp.save('service',jsonb_build_object('name','Classified service','description','Test classification','delivery_mode','telephone','contacts','[{"channel_type":"phone","value":"phone"}]'::jsonb,'territories',jsonb_build_array(rome),'classifications',jsonb_build_array(jsonb_build_object('adoption_id',adoption,'term_id',leaf),jsonb_build_object('adoption_id',adoption,'term_id',other))));PERFORM pg_temp.publish(sr);SELECT entity_id INTO service FROM governance.entity_revisions WHERE revision_id=sr;
 PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM api.taxonomy_search(rome,jsonb_build_object('need',jsonb_build_array(parent1,parent2)),'2026-03-01')),'multiple parents deduplicate service');
 PERFORM pg_temp.assert_true((SELECT count(*)=1 FROM api.taxonomy_search(rome,jsonb_build_object('need',jsonb_build_array(parent1),'population',jsonb_build_array(other)),'2026-03-01')),'AND across axes');
 PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM api.taxonomy_search(rome,jsonb_build_object('population',jsonb_build_array(parent1)),'2026-03-01')),'wrong axis never matches');
 fork_release:=governance.fork_taxonomy_release(release,florence,'full-independent-copy','v1','Copy exact frozen content');
 PERFORM pg_temp.assert_true((SELECT count(*)=4 FROM taxonomy.release_terms WHERE release_id=fork_release),'fork copies all frozen terms');
 PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM taxonomy.broader_links WHERE release_id=fork_release),'fork copies hierarchy');
 PERFORM pg_temp.assert_true(NOT EXISTS(SELECT FROM taxonomy.release_terms a JOIN taxonomy.release_terms b USING(term_id) WHERE a.release_id=release AND b.release_id=fork_release),'fork identities are distinct');
 fork_vr:=pg_temp.save('taxonomy_vocabulary',jsonb_build_object('code','local-copy','name','Florence vocabulary','origin_vocabulary_id',vocab,'origin_release_id',release));PERFORM pg_temp.publish(fork_vr);SELECT entity_id INTO fork_v FROM governance.entity_revisions WHERE revision_id=fork_vr;fork_axis:=governance.create_taxonomy_axis(fork_v,'need');
 t:=pg_temp.save('taxonomy_term',jsonb_build_object('name','Local support','vocabulary_id',fork_v,'axis_id',fork_axis,'code','support'));PERFORM pg_temp.publish(t);SELECT entity_id INTO fork_term FROM governance.entity_revisions WHERE revision_id=t;
 fork_release:=governance.freeze_taxonomy_release(fork_vr,'v1',jsonb_build_array(jsonb_build_object('axis_id',fork_axis,'label','Local need')),jsonb_build_array(jsonb_build_object('term_id',fork_term,'revision_id',t)),'[]','Independent local snapshot');
 ar:=governance.adopt_taxonomy_release(florence,fork_release,'2026-01-01',NULL,'Independent adoption');
 PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM taxonomy.broader_links WHERE release_id=release),'local copy does not alter source hierarchy');
 PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM api.taxonomy_search(florence,jsonb_build_object('need',jsonb_build_array(parent1)),'2026-03-01')),'territory cannot use source terms from another adoption');
 sr:=governance.restore_revision(sr,sr,sr,'Restore classifications');PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM taxonomy.assignments WHERE revision_id=sr),'restore pinned classifications');
END $$;
ROLLBACK;
