-- Deploy egi_database:territorial_taxonomy [shared_calendar] to pg
BEGIN;
CREATE TABLE taxonomy.vocabularies (
 entity_id uuid PRIMARY KEY,entity_kind text NOT NULL DEFAULT 'taxonomy_vocabulary' CHECK(entity_kind='taxonomy_vocabulary'),code text NOT NULL UNIQUE,
 origin_vocabulary_id uuid REFERENCES taxonomy.vocabularies,origin_release_id uuid,
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind)
);
CREATE TABLE taxonomy.vocabulary_revisions (
 revision_id uuid PRIMARY KEY,entity_id uuid NOT NULL,entity_kind text NOT NULL DEFAULT 'taxonomy_vocabulary' CHECK(entity_kind='taxonomy_vocabulary'),
 FOREIGN KEY(revision_id,entity_id,entity_kind) REFERENCES governance.entity_revisions(revision_id,entity_id,entity_kind),
 FOREIGN KEY(entity_id) REFERENCES taxonomy.vocabularies,UNIQUE(revision_id,entity_id)
);
CREATE TABLE taxonomy.axes (
 axis_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),vocabulary_id uuid NOT NULL REFERENCES taxonomy.vocabularies,code text NOT NULL,
 UNIQUE(vocabulary_id,code),UNIQUE(axis_id,vocabulary_id)
);
CREATE TABLE taxonomy.terms (
 entity_id uuid PRIMARY KEY,entity_kind text NOT NULL DEFAULT 'taxonomy_term' CHECK(entity_kind='taxonomy_term'),
 vocabulary_id uuid NOT NULL,axis_id uuid NOT NULL,code text NOT NULL,external_uri text,
 FOREIGN KEY(entity_id,entity_kind) REFERENCES data.entities(entity_id,entity_kind),
 FOREIGN KEY(axis_id,vocabulary_id) REFERENCES taxonomy.axes(axis_id,vocabulary_id),
 UNIQUE(vocabulary_id,axis_id,code),UNIQUE(entity_id,vocabulary_id,axis_id)
);
CREATE TABLE taxonomy.term_revisions (
 revision_id uuid PRIMARY KEY,entity_id uuid NOT NULL,entity_kind text NOT NULL DEFAULT 'taxonomy_term' CHECK(entity_kind='taxonomy_term'),active boolean NOT NULL,
 presentation_metadata jsonb NOT NULL DEFAULT '{}',
 FOREIGN KEY(revision_id,entity_id,entity_kind) REFERENCES governance.entity_revisions(revision_id,entity_id,entity_kind),
 FOREIGN KEY(entity_id) REFERENCES taxonomy.terms,UNIQUE(revision_id,entity_id)
);
CREATE TABLE taxonomy.releases (
 release_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),vocabulary_id uuid NOT NULL REFERENCES taxonomy.vocabularies,vocabulary_revision_id uuid NOT NULL,
 sealed_at timestamptz,version text NOT NULL,actor_id uuid NOT NULL REFERENCES governance.actors,reason text NOT NULL,published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(vocabulary_revision_id,vocabulary_id) REFERENCES taxonomy.vocabulary_revisions(revision_id,entity_id),
 UNIQUE(vocabulary_id,version),UNIQUE(release_id,vocabulary_id)
);
ALTER TABLE taxonomy.vocabularies ADD FOREIGN KEY(origin_release_id,origin_vocabulary_id) REFERENCES taxonomy.releases(release_id,vocabulary_id);
ALTER TABLE taxonomy.vocabularies ADD CHECK((origin_vocabulary_id IS NULL)=(origin_release_id IS NULL));
CREATE TABLE taxonomy.release_axes (
 release_id uuid NOT NULL,vocabulary_id uuid NOT NULL,axis_id uuid NOT NULL,label text NOT NULL,sort_order integer NOT NULL DEFAULT 0,
 PRIMARY KEY(release_id,axis_id),
 FOREIGN KEY(release_id,vocabulary_id) REFERENCES taxonomy.releases(release_id,vocabulary_id),
 FOREIGN KEY(axis_id,vocabulary_id) REFERENCES taxonomy.axes(axis_id,vocabulary_id)
);
CREATE TABLE taxonomy.release_terms (
 release_id uuid NOT NULL,vocabulary_id uuid NOT NULL,axis_id uuid NOT NULL,term_id uuid NOT NULL,term_revision_id uuid NOT NULL,
 PRIMARY KEY(release_id,term_id),UNIQUE(release_id,term_id,axis_id),
 FOREIGN KEY(release_id,axis_id) REFERENCES taxonomy.release_axes,
 FOREIGN KEY(term_id,vocabulary_id,axis_id) REFERENCES taxonomy.terms(entity_id,vocabulary_id,axis_id),
 FOREIGN KEY(term_revision_id,term_id) REFERENCES taxonomy.term_revisions(revision_id,entity_id)
);
CREATE TABLE taxonomy.broader_links (
 release_id uuid NOT NULL,axis_id uuid NOT NULL,child_term_id uuid NOT NULL,parent_term_id uuid NOT NULL,
 PRIMARY KEY(release_id,child_term_id,parent_term_id),CHECK(child_term_id<>parent_term_id),
 FOREIGN KEY(release_id,child_term_id,axis_id) REFERENCES taxonomy.release_terms(release_id,term_id,axis_id),
 FOREIGN KEY(release_id,parent_term_id,axis_id) REFERENCES taxonomy.release_terms(release_id,term_id,axis_id)
);
CREATE TABLE taxonomy.territory_adoptions (
 adoption_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),territory_id uuid NOT NULL REFERENCES geo.territories,vocabulary_id uuid NOT NULL,release_id uuid NOT NULL,
 effective_from date NOT NULL,effective_until date,CHECK(effective_until IS NULL OR effective_until>=effective_from),
 actor_id uuid NOT NULL REFERENCES governance.actors,reason text NOT NULL,approved_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(release_id,vocabulary_id) REFERENCES taxonomy.releases(release_id,vocabulary_id),
 UNIQUE(adoption_id,release_id),UNIQUE(adoption_id,territory_id)
);
CREATE TABLE taxonomy.assignments (
 revision_id uuid NOT NULL REFERENCES data.service_revisions,entity_id uuid NOT NULL,territory_id uuid NOT NULL,adoption_id uuid NOT NULL,release_id uuid NOT NULL,term_id uuid NOT NULL,
 value_decision_id uuid NOT NULL,
 PRIMARY KEY(revision_id,adoption_id,term_id),
 FOREIGN KEY(revision_id,entity_id) REFERENCES governance.entity_revisions(revision_id,entity_id),
 FOREIGN KEY(adoption_id,release_id) REFERENCES taxonomy.territory_adoptions(adoption_id,release_id),
 FOREIGN KEY(adoption_id,territory_id) REFERENCES taxonomy.territory_adoptions(adoption_id,territory_id),
 FOREIGN KEY(release_id,term_id) REFERENCES taxonomy.release_terms,
 FOREIGN KEY(value_decision_id,revision_id,entity_id) REFERENCES governance.value_decisions(value_decision_id,revision_id,entity_id)
);
CREATE FUNCTION governance.check_taxonomy_edge() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(WITH RECURSIVE ancestors(t) AS(SELECT NEW.parent_term_id UNION SELECT b.parent_term_id FROM taxonomy.broader_links b JOIN ancestors a ON b.child_term_id=a.t WHERE b.release_id=NEW.release_id) SELECT FROM ancestors WHERE t=NEW.child_term_id) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='taxonomy_cycle'; END IF; RETURN NEW;
END $$;
CREATE TRIGGER acyclic BEFORE INSERT ON taxonomy.broader_links FOR EACH ROW EXECUTE FUNCTION governance.check_taxonomy_edge();
CREATE FUNCTION governance.check_taxonomy_adoption() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT FROM taxonomy.territory_adoptions a WHERE a.territory_id=NEW.territory_id AND daterange(a.effective_from,a.effective_until,'[]') && daterange(NEW.effective_from,NEW.effective_until,'[]') AND EXISTS(SELECT FROM taxonomy.release_axes olda JOIN taxonomy.axes ax ON ax.axis_id=olda.axis_id JOIN taxonomy.release_axes newa ON newa.release_id=NEW.release_id JOIN taxonomy.axes bx ON bx.axis_id=newa.axis_id WHERE olda.release_id=a.release_id AND ax.code=bx.code)) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='overlapping_taxonomy_adoption'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER no_overlap BEFORE INSERT ON taxonomy.territory_adoptions FOR EACH ROW EXECUTE FUNCTION governance.check_taxonomy_adoption();
CREATE FUNCTION governance.save_taxonomy_entity(rev uuid,owner uuid,kind text,body jsonb,evidence jsonb,note text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE field text;
BEGIN
 FOR field IN SELECT key FROM jsonb_each(body) WHERE key NOT IN ('name','original_language','territories','evidence') LOOP
 PERFORM governance.select_value(rev,owner,field,NULL,COALESCE(body->'evidence'->field,evidence),note); END LOOP;
 IF NOT EXISTS(SELECT FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=rev AND l.field_code='name' AND btrim(c.original_text)<>'') THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='taxonomy_name_required'; END IF;
 IF kind='taxonomy_vocabulary' THEN
 INSERT INTO taxonomy.vocabularies(entity_id,code,origin_vocabulary_id,origin_release_id) VALUES(owner,body->>'code',(body->>'origin_vocabulary_id')::uuid,(body->>'origin_release_id')::uuid) ON CONFLICT(entity_id) DO NOTHING;
 IF NOT EXISTS(SELECT FROM taxonomy.vocabularies WHERE entity_id=owner AND code=body->>'code' AND origin_vocabulary_id IS NOT DISTINCT FROM (body->>'origin_vocabulary_id')::uuid AND origin_release_id IS NOT DISTINCT FROM (body->>'origin_release_id')::uuid) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='immutable_vocabulary_identity'; END IF;
 INSERT INTO taxonomy.vocabulary_revisions(revision_id,entity_id) VALUES(rev,owner);
 ELSE
 INSERT INTO taxonomy.terms(entity_id,vocabulary_id,axis_id,code,external_uri) VALUES(owner,(body->>'vocabulary_id')::uuid,(body->>'axis_id')::uuid,body->>'code',body->>'external_uri') ON CONFLICT(entity_id) DO NOTHING;
 IF NOT EXISTS(SELECT FROM taxonomy.terms WHERE entity_id=owner AND vocabulary_id=(body->>'vocabulary_id')::uuid AND axis_id=(body->>'axis_id')::uuid AND code=body->>'code' AND external_uri IS NOT DISTINCT FROM body->>'external_uri') THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='immutable_term_identity'; END IF;
 INSERT INTO taxonomy.term_revisions(revision_id,entity_id,active,presentation_metadata) VALUES(rev,owner,COALESCE((body->>'active')::boolean,true),COALESCE(body->'presentation_metadata','{}'));
 END IF;
END $$;
CREATE FUNCTION governance.create_taxonomy_axis(vocabulary uuid,code text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; scopes uuid[]; rev uuid; BEGIN
 PERFORM governance.lock_operation();
 SELECT revision_id INTO STRICT rev FROM governance.published_heads WHERE entity_id=vocabulary;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(vocabulary,rev)t;
 PERFORM governance.require_capability('propose',scopes);
 INSERT INTO taxonomy.axes(vocabulary_id,code) VALUES(vocabulary,code) RETURNING axis_id INTO result; RETURN result;
END $$;
CREATE FUNCTION governance.freeze_taxonomy_release(vocabulary_revision uuid,version text,axes jsonb,terms jsonb,edges jsonb,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; vocabulary uuid; scopes uuid[]; item jsonb; child uuid; parent uuid; axis uuid; BEGIN
 PERFORM governance.lock_operation();
 SELECT v.entity_id INTO STRICT vocabulary FROM taxonomy.vocabulary_revisions v JOIN governance.published_heads h USING(revision_id) WHERE revision_id=vocabulary_revision;
 SELECT array_agg(t) INTO scopes FROM governance.affected_territories(vocabulary,vocabulary_revision)t;
 PERFORM governance.require_capability('propose',scopes); PERFORM governance.require_capability('approve',scopes); PERFORM governance.require_capability('publish',scopes);
 INSERT INTO taxonomy.releases(vocabulary_id,vocabulary_revision_id,version,actor_id,reason) VALUES(vocabulary,vocabulary_revision,version,governance.current_actor(),note) RETURNING release_id INTO result;
 FOR item IN SELECT value FROM jsonb_array_elements(axes) LOOP
 INSERT INTO taxonomy.release_axes VALUES(result,vocabulary,(item->>'axis_id')::uuid,item->>'label',COALESCE((item->>'sort_order')::integer,0)); END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(terms) LOOP
 IF NOT EXISTS(SELECT FROM taxonomy.term_revisions t JOIN governance.published_heads h USING(revision_id) WHERE t.revision_id=(item->>'revision_id')::uuid AND t.entity_id=(item->>'term_id')::uuid AND t.active) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='approved_active_term_required'; END IF;
 SELECT axis_id INTO STRICT axis FROM taxonomy.terms WHERE entity_id=(item->>'term_id')::uuid;
 INSERT INTO taxonomy.release_terms VALUES(result,vocabulary,axis,(item->>'term_id')::uuid,(item->>'revision_id')::uuid); END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(edges) LOOP
 child:=(item->>'child')::uuid;parent:=(item->>'parent')::uuid;
 SELECT axis_id INTO STRICT axis FROM taxonomy.terms WHERE entity_id=child;
 INSERT INTO taxonomy.broader_links VALUES(result,axis,child,parent); END LOOP;
 UPDATE taxonomy.releases SET sealed_at=clock_timestamp() WHERE release_id=result;
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details) VALUES(governance.current_actor(),'approve_and_freeze_taxonomy_release',vocabulary,vocabulary_revision,jsonb_build_object('release_id',result,'reason',note)); RETURN result;
END $$;
CREATE FUNCTION governance.adopt_taxonomy_release(territory uuid,release uuid,date_from date,date_until date,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; vocabulary uuid; BEGIN
 PERFORM governance.lock_operation();
 PERFORM governance.require_capability('propose',ARRAY[territory]);PERFORM governance.require_capability('approve',ARRAY[territory]);PERFORM governance.require_capability('publish',ARRAY[territory]);
 SELECT vocabulary_id INTO STRICT vocabulary FROM taxonomy.releases WHERE release_id=release AND sealed_at IS NOT NULL;
 IF EXISTS(SELECT FROM taxonomy.assignments a JOIN governance.published_heads h USING(revision_id) JOIN taxonomy.territory_adoptions old ON old.adoption_id=a.adoption_id WHERE a.territory_id=territory AND old.vocabulary_id=vocabulary AND NOT EXISTS(SELECT FROM taxonomy.release_terms t WHERE t.release_id=release AND t.term_id=a.term_id)) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='taxonomy_assignment_migration_required'; END IF;
 INSERT INTO taxonomy.territory_adoptions(territory_id,vocabulary_id,release_id,effective_from,effective_until,actor_id,reason) VALUES(territory,vocabulary,release,date_from,date_until,governance.current_actor(),note) RETURNING adoption_id INTO result;
 INSERT INTO audit.events(actor_id,action,entity_id,details) VALUES(governance.current_actor(),'approve_taxonomy_adoption',territory,jsonb_build_object('adoption_id',result,'release_id',release,'reason',note)); RETURN result;
END $$;
CREATE FUNCTION governance.fork_taxonomy_release(source_release uuid,target_territory uuid,new_code text,new_version text,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE source taxonomy.releases; target_revision uuid; target uuid; revision uuid; owner uuid; decision uuid; item record; axis uuid; axis_map jsonb:='{}'; term_map jsonb:='{}'; axes jsonb:='[]'; terms jsonb:='[]'; edges jsonb:='[]'; body jsonb; evidence jsonb; result uuid;
BEGIN
 PERFORM governance.lock_operation();
 PERFORM governance.require_capability('propose',ARRAY[target_territory]);PERFORM governance.require_capability('approve',ARRAY[target_territory]);PERFORM governance.require_capability('publish',ARRAY[target_territory]);
 SELECT * INTO STRICT source FROM taxonomy.releases WHERE release_id=source_release AND sealed_at IS NOT NULL;
 SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('assertion_id',e.assertion_id,'role',e.evidence_role)),'[]') INTO evidence FROM governance.value_decisions d JOIN governance.value_evidence e USING(value_decision_id) WHERE d.revision_id=source.vocabulary_revision_id;
 SELECT jsonb_build_object('code',new_code,'name',c.original_text,'original_language',c.original_language,'origin_vocabulary_id',source.vocabulary_id,'origin_release_id',source.release_id,'territories',jsonb_build_array(target_territory),'evidence',jsonb_build_object('record',evidence)) INTO body FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=source.vocabulary_revision_id AND l.field_code='name';
 SELECT body||jsonb_build_object('description',c.original_text) INTO body FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=source.vocabulary_revision_id AND l.field_code='description';
 -- SELECT INTO with no description would null the body; rebuild optional text safely.
 IF body IS NULL THEN
 SELECT jsonb_build_object('code',new_code,'name',c.original_text,'original_language',c.original_language,'origin_vocabulary_id',source.vocabulary_id,'origin_release_id',source.release_id,'territories',jsonb_build_array(target_territory),'evidence',jsonb_build_object('record',evidence)) INTO body FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=source.vocabulary_revision_id AND l.field_code='name'; END IF;
 target_revision:=governance.save_revision('taxonomy_vocabulary',NULL,NULL,NULL,body,note);SELECT entity_id INTO target FROM governance.entity_revisions WHERE revision_id=target_revision;
 decision:=governance.review_revision(target_revision,NULL,'approved',note);PERFORM governance.publish_revision(target_revision,decision,NULL);
 FOR item IN SELECT ra.*,ax.code FROM taxonomy.release_axes ra JOIN taxonomy.axes ax USING(axis_id) WHERE ra.release_id=source_release ORDER BY ra.axis_id LOOP
 axis:=governance.create_taxonomy_axis(target,item.code);axis_map:=axis_map||jsonb_build_object(item.axis_id::text,axis);
 axes:=axes||jsonb_build_array(jsonb_build_object('axis_id',axis,'label',item.label,'sort_order',item.sort_order));END LOOP;
 FOR item IN SELECT rt.*,t.code,t.external_uri,tr.presentation_metadata FROM taxonomy.release_terms rt JOIN taxonomy.terms t ON t.entity_id=rt.term_id JOIN taxonomy.term_revisions tr ON tr.revision_id=rt.term_revision_id WHERE rt.release_id=source_release ORDER BY rt.term_id LOOP
 SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('assertion_id',e.assertion_id,'role',e.evidence_role)),'[]') INTO evidence FROM governance.value_decisions d JOIN governance.value_evidence e USING(value_decision_id) WHERE d.revision_id=item.term_revision_id;
 SELECT jsonb_build_object('code',item.code,'name',c.original_text,'description',(SELECT d.original_text FROM i18n.revision_content_links dl JOIN i18n.content_units d USING(content_id) WHERE dl.revision_id=item.term_revision_id AND dl.field_code='description'),'original_language',c.original_language,'vocabulary_id',target,'axis_id',(axis_map->>item.axis_id::text)::uuid,'external_uri',item.external_uri,'active',true,'presentation_metadata',item.presentation_metadata,'territories',jsonb_build_array(target_territory),'evidence',jsonb_build_object('record',evidence)) INTO body FROM i18n.revision_content_links l JOIN i18n.content_units c USING(content_id) WHERE l.revision_id=item.term_revision_id AND l.field_code='name';
 revision:=governance.save_revision('taxonomy_term',NULL,NULL,NULL,body,note);SELECT entity_id INTO owner FROM governance.entity_revisions WHERE revision_id=revision;
 decision:=governance.review_revision(revision,NULL,'approved',note);PERFORM governance.publish_revision(revision,decision,NULL);
 term_map:=term_map||jsonb_build_object(item.term_id::text,owner);terms:=terms||jsonb_build_array(jsonb_build_object('term_id',owner,'revision_id',revision));
 END LOOP;
 FOR item IN SELECT * FROM taxonomy.broader_links WHERE release_id=source_release ORDER BY child_term_id,parent_term_id LOOP
 edges:=edges||jsonb_build_array(jsonb_build_object('child',(term_map->>item.child_term_id::text)::uuid,'parent',(term_map->>item.parent_term_id::text)::uuid));END LOOP;
 result:=governance.freeze_taxonomy_release(target_revision,new_version,axes,terms,edges,note);
 INSERT INTO audit.events(actor_id,action,entity_id,revision_id,details) VALUES(governance.current_actor(),'fork_taxonomy_release',target,target_revision,jsonb_build_object('source_release_id',source_release,'target_release_id',result,'term_identity_map',term_map,'reason',note));RETURN result;
END $$;
CREATE FUNCTION governance.save_classifications(rev uuid,owner uuid,kind text,body jsonb,evidence jsonb,note text) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE item jsonb; adoption taxonomy.territory_adoptions; decision uuid; BEGIN
 FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(body->'classifications','[]')) LOOP
 SELECT * INTO STRICT adoption FROM taxonomy.territory_adoptions WHERE adoption_id=(item->>'adoption_id')::uuid;
 IF NOT EXISTS(SELECT FROM geo.service_memberships WHERE revision_id=rev AND territory_id=adoption.territory_id) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='classification_requires_map_membership'; END IF;
 decision:=governance.select_value(rev,owner,'classification',NULL,COALESCE(item->'evidence',evidence),note);
 INSERT INTO taxonomy.assignments VALUES(rev,owner,adoption.territory_id,adoption.adoption_id,adoption.release_id,(item->>'term_id')::uuid,decision);
 END LOOP;
END $$;
INSERT INTO governance.revision_extensions VALUES
 ('30_vocabulary',ARRAY['taxonomy_vocabulary'],ARRAY['code','origin_vocabulary_id','origin_release_id','description'],'governance.save_taxonomy_entity(uuid,uuid,text,jsonb,jsonb,text)'::regprocedure,ARRAY['taxonomy.vocabulary_revisions']),
 ('31_term',ARRAY['taxonomy_term'],ARRAY['vocabulary_id','axis_id','code','external_uri','active','presentation_metadata','description'],'governance.save_taxonomy_entity(uuid,uuid,text,jsonb,jsonb,text)'::regprocedure,ARRAY['taxonomy.term_revisions']),
 ('32_classification',ARRAY['service'],ARRAY['classifications'],'governance.save_classifications(uuid,uuid,text,jsonb,jsonb,text)'::regprocedure,ARRAY['taxonomy.assignments']);
CREATE FUNCTION api.taxonomy_search(territory uuid,selections jsonb,at_date date DEFAULT current_date) RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 WITH RECURSIVE requested AS(SELECT key AS axis_code,value FROM jsonb_each(selections)),
 expanded(axis_code,release_id,term_id) AS (
 SELECT r.axis_code,a.release_id,t.entity_id FROM requested r CROSS JOIN LATERAL jsonb_array_elements_text(r.value)x JOIN taxonomy.terms t ON t.entity_id=x::uuid JOIN taxonomy.axes ax ON ax.axis_id=t.axis_id AND ax.code=r.axis_code JOIN taxonomy.territory_adoptions a ON a.territory_id=territory AND a.release_id IN(SELECT release_id FROM taxonomy.release_terms WHERE term_id=t.entity_id) AND at_date>=a.effective_from AND (a.effective_until IS NULL OR at_date<=a.effective_until)
 UNION SELECT e.axis_code,e.release_id,b.child_term_id FROM expanded e JOIN taxonomy.broader_links b ON b.release_id=e.release_id AND b.parent_term_id=e.term_id
 ), matched AS(SELECT DISTINCT a.entity_id,e.axis_code FROM expanded e JOIN taxonomy.assignments a ON a.release_id=e.release_id AND a.term_id=e.term_id AND a.territory_id=territory JOIN api.discoverable_services s ON s.revision_id=a.revision_id)
 SELECT s.service_id FROM api.discoverable_services s JOIN geo.service_memberships m ON m.revision_id=s.revision_id AND m.territory_id=territory
 WHERE NOT EXISTS(SELECT FROM requested r WHERE NOT EXISTS(SELECT FROM matched q WHERE q.entity_id=s.service_id AND q.axis_code=r.axis_code))
$$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['vocabularies','vocabulary_revisions','axes','terms','term_revisions','release_axes','release_terms','broader_links','territory_adoptions','assignments'] LOOP
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON taxonomy.%I FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);
 END LOOP;
 FOREACH t IN ARRAY ARRAY['vocabulary_revisions','term_revisions','assignments'] LOOP
 EXECUTE format('CREATE TRIGGER open_revision BEFORE INSERT ON taxonomy.%I FOR EACH ROW EXECUTE FUNCTION governance.check_open_revision()',t); END LOOP;
END $$;
CREATE FUNCTION governance.protect_taxonomy_release() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.sealed_at IS NULL AND NEW.sealed_at IS NOT NULL AND to_jsonb(NEW)-'sealed_at'=to_jsonb(OLD)-'sealed_at' THEN RETURN NEW; END IF;
 RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='immutable_taxonomy_release';
END $$;
CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON taxonomy.releases FOR EACH ROW EXECUTE FUNCTION governance.protect_taxonomy_release();
CREATE FUNCTION governance.check_open_taxonomy_release() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT FROM taxonomy.releases WHERE release_id=NEW.release_id AND sealed_at IS NOT NULL) THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='sealed_taxonomy_release'; END IF;RETURN NEW;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['release_axes','release_terms','broader_links'] LOOP
 EXECUTE format('CREATE TRIGGER open_release BEFORE INSERT ON taxonomy.%I FOR EACH ROW EXECUTE FUNCTION governance.check_open_taxonomy_release()',t);END LOOP;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
REVOKE ALL ON FUNCTION api.taxonomy_search(uuid,jsonb,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION governance.fork_taxonomy_release(uuid,uuid,text,text,text) TO egi_writer;
GRANT EXECUTE ON FUNCTION governance.create_taxonomy_axis(uuid,text),governance.freeze_taxonomy_release(uuid,text,jsonb,jsonb,jsonb,text),governance.adopt_taxonomy_release(uuid,uuid,date,date,text) TO egi_writer;
GRANT EXECUTE ON FUNCTION api.taxonomy_search(uuid,jsonb,date) TO egi_reader;
COMMIT;
