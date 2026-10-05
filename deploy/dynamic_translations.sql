-- Deploy egi_database:dynamic_translations [territorial_taxonomy] to pg
BEGIN;
CREATE TABLE i18n.languages (
 language_code text PRIMARY KEY CHECK(language_code ~ '^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$'),native_name text NOT NULL,english_name text NOT NULL,direction text NOT NULL CHECK(direction IN('ltr','rtl'))
);
CREATE TABLE i18n.translations (
 translation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),content_id uuid NOT NULL REFERENCES i18n.content_units,language_code text NOT NULL REFERENCES i18n.languages,
 translated_text text NOT NULL CHECK(btrim(translated_text)<>''),translation_class text NOT NULL CHECK(translation_class IN('human','ai','ai_verified')),
 actor_id uuid NOT NULL REFERENCES governance.actors,model_version text,supersedes_id uuid REFERENCES i18n.translations,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK((translation_class='human' AND model_version IS NULL) OR (translation_class IN('ai','ai_verified') AND model_version IS NOT NULL)),
 UNIQUE(translation_id,content_id,language_code)
);
CREATE TABLE i18n.translation_reviews (
 review_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),translation_id uuid NOT NULL REFERENCES i18n.translations,outcome text NOT NULL CHECK(outcome IN('approved','needs_changes')),
 review_sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,actor_id uuid NOT NULL REFERENCES governance.actors,reason text NOT NULL,reviewed_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(review_id,translation_id,outcome)
);
CREATE TABLE i18n.translation_publications (
 publication_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),content_id uuid NOT NULL,language_code text NOT NULL,translation_id uuid NOT NULL,
 review_id uuid NOT NULL,outcome text NOT NULL DEFAULT 'approved' CHECK(outcome='approved'),actor_id uuid NOT NULL REFERENCES governance.actors,published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(translation_id,content_id,language_code) REFERENCES i18n.translations(translation_id,content_id,language_code),
 FOREIGN KEY(review_id,translation_id,outcome) REFERENCES i18n.translation_reviews(review_id,translation_id,outcome),
 UNIQUE(publication_id,content_id,language_code)
);
CREATE TABLE i18n.translation_heads (
 content_id uuid NOT NULL,language_code text NOT NULL,publication_id uuid NOT NULL,
 PRIMARY KEY(content_id,language_code),FOREIGN KEY(publication_id,content_id,language_code) REFERENCES i18n.translation_publications(publication_id,content_id,language_code)
);
CREATE TABLE i18n.territory_language_priorities (
 territory_id uuid NOT NULL REFERENCES geo.territories,language_code text NOT NULL REFERENCES i18n.languages,priority integer NOT NULL,enabled_for_translation_work boolean NOT NULL DEFAULT true,
 PRIMARY KEY(territory_id,language_code)
);
CREATE TABLE i18n.translation_update_requests (
 request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),entity_id uuid NOT NULL,field_code text NOT NULL,component_scope uuid NOT NULL,language_code text NOT NULL REFERENCES i18n.languages,
 required_content_id uuid NOT NULL,previous_translation_id uuid REFERENCES i18n.translations,reason text NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(required_content_id,entity_id) REFERENCES i18n.content_units(content_id,owner_entity_id),UNIQUE(entity_id,field_code,component_scope,language_code,required_content_id)
);
CREATE FUNCTION governance.public_content(content uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT FROM i18n.content_units c JOIN i18n.revision_content_links l USING(content_id) JOIN governance.published_heads h USING(revision_id) WHERE c.content_id=content AND NOT EXISTS(SELECT FROM data.contact_entries p WHERE p.revision_id=h.revision_id AND p.component_id=c.component_id AND NOT p.is_public))
 OR EXISTS(SELECT FROM taxonomy.release_terms rt JOIN i18n.revision_content_links l ON l.revision_id=rt.term_revision_id JOIN taxonomy.territory_adoptions a USING(release_id) WHERE l.content_id=content)
$$;
CREATE VIEW governance.translation_work AS
SELECT q.*,CASE WHEN NOT governance.public_content(q.required_content_id) THEN 'superseded' WHEN EXISTS(SELECT FROM i18n.translation_heads WHERE content_id=q.required_content_id AND language_code=q.language_code) THEN 'resolved' ELSE 'open' END AS status
FROM i18n.translation_update_requests q;
CREATE FUNCTION governance.translation_scope(content uuid) RETURNS uuid[] LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT array_agg(t) FROM i18n.content_units c LEFT JOIN governance.published_heads h ON h.entity_id=c.owner_entity_id CROSS JOIN LATERAL governance.affected_territories(c.owner_entity_id,COALESCE(h.revision_id,c.introduced_revision_id))t WHERE c.content_id=content
$$;
CREATE FUNCTION governance.propose_translation(content uuid,language text,text_value text,class text,model text,previous uuid,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; BEGIN
 PERFORM governance.lock_operation();PERFORM governance.require_capability('propose',governance.translation_scope(content));
 IF previous IS NOT NULL AND NOT EXISTS(SELECT FROM i18n.translations WHERE translation_id=previous AND content_id=content AND language_code=language) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='translation_origin_mismatch'; END IF;
 IF class='ai_verified' THEN
 IF previous IS NULL OR NOT EXISTS(SELECT FROM i18n.translations WHERE translation_id=previous AND translation_class IN('ai','ai_verified') AND model_version=model) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='verified_ai_requires_origin'; END IF;
 PERFORM governance.require_capability('verify',governance.translation_scope(content)); END IF;
 INSERT INTO i18n.translations(content_id,language_code,translated_text,translation_class,actor_id,model_version,supersedes_id) VALUES(content,language,text_value,class,governance.current_actor(),model,previous) RETURNING translation_id INTO result;
 INSERT INTO audit.events(actor_id,action,details) VALUES(governance.current_actor(),'propose_translation',jsonb_build_object('translation_id',result,'reason',note));RETURN result;
END $$;
CREATE FUNCTION governance.review_translation(translation uuid,outcome text,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE candidate i18n.translations; result uuid; BEGIN
 PERFORM governance.lock_operation();SELECT * INTO STRICT candidate FROM i18n.translations WHERE translation_id=translation;
 PERFORM governance.require_capability('approve',governance.translation_scope(candidate.content_id));
 IF candidate.actor_id=governance.current_actor() THEN PERFORM governance.require_capability('propose',governance.translation_scope(candidate.content_id)); END IF;
 INSERT INTO i18n.translation_reviews(translation_id,outcome,actor_id,reason) VALUES(translation,outcome,governance.current_actor(),note) RETURNING review_id INTO result;RETURN result;
END $$;
CREATE FUNCTION governance.publish_translation(translation uuid,review uuid,expected_publication uuid,note text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE candidate i18n.translations; head uuid; result uuid; owner uuid; affected record; BEGIN
 PERFORM governance.lock_operation();SELECT * INTO STRICT candidate FROM i18n.translations WHERE translation_id=translation;
 PERFORM governance.require_capability('publish',governance.translation_scope(candidate.content_id));
 SELECT publication_id INTO head FROM i18n.translation_heads WHERE content_id=candidate.content_id AND language_code=candidate.language_code;
 IF head IS DISTINCT FROM expected_publication THEN RAISE EXCEPTION USING ERRCODE='40001',MESSAGE='stale_translation_base'; END IF;
 IF NOT EXISTS(SELECT FROM i18n.translation_reviews WHERE review_id=review AND translation_id=translation AND outcome='approved' AND review_sequence=(SELECT max(review_sequence) FROM i18n.translation_reviews WHERE translation_id=translation)) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='exact_translation_approval_required'; END IF;
 IF NOT governance.public_content(candidate.content_id) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='original_not_current'; END IF;
 INSERT INTO i18n.translation_publications(content_id,language_code,translation_id,review_id,actor_id) VALUES(candidate.content_id,candidate.language_code,translation,review,governance.current_actor()) RETURNING publication_id INTO result;
 INSERT INTO i18n.translation_heads VALUES(candidate.content_id,candidate.language_code,result) ON CONFLICT(content_id,language_code) DO UPDATE SET publication_id=EXCLUDED.publication_id;
 SELECT owner_entity_id INTO owner FROM i18n.content_units WHERE content_id=candidate.content_id;
 FOR affected IN SELECT h.entity_id,h.publication_id FROM governance.published_heads h WHERE h.entity_id=owner OR EXISTS(SELECT FROM data.service_places p WHERE p.revision_id=h.revision_id AND p.location_id=owner) OR EXISTS(SELECT FROM data.service_organizations o WHERE o.revision_id=h.revision_id AND o.organization_id=owner) OR EXISTS(SELECT FROM data.service_contact_links l WHERE l.revision_id=h.revision_id AND l.target_entity_id=owner) LOOP
 INSERT INTO audit.public_changes(entity_id,publication_id,resource_kind,reason) VALUES(affected.entity_id,affected.publication_id,'translated_content','approved_translation_change'); END LOOP;
 INSERT INTO audit.events(actor_id,action,entity_id,details) VALUES(governance.current_actor(),'publish_translation',owner,jsonb_build_object('translation_id',translation,'reason',note));RETURN result;
END $$;
CREATE FUNCTION governance.queue_translation_updates() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 INSERT INTO i18n.translation_update_requests(entity_id,field_code,component_scope,language_code,required_content_id,previous_translation_id,reason)
 SELECT NEW.entity_id,l.field_code,l.component_scope,target.language_code,l.content_id,previous.translation_id,'published_original_changed'
 FROM i18n.revision_content_links l CROSS JOIN LATERAL (
 SELECT p.language_code FROM governance.affected_territories(NEW.entity_id,NEW.revision_id)t JOIN i18n.territory_language_priorities p ON p.territory_id=t WHERE p.enabled_for_translation_work
 UNION SELECT h.language_code FROM i18n.content_units c JOIN i18n.translation_heads h USING(content_id) WHERE c.owner_entity_id=NEW.entity_id AND c.field_code=l.field_code AND COALESCE(c.component_id,'00000000-0000-0000-0000-000000000000'::uuid)=l.component_scope
 )target
 LEFT JOIN LATERAL (SELECT pub.translation_id FROM i18n.content_units c JOIN i18n.translation_heads h USING(content_id) JOIN i18n.translation_publications pub USING(publication_id) WHERE c.owner_entity_id=NEW.entity_id AND c.field_code=l.field_code AND COALESCE(c.component_id,'00000000-0000-0000-0000-000000000000'::uuid)=l.component_scope AND h.language_code=target.language_code ORDER BY pub.published_at DESC LIMIT 1)previous ON true
 WHERE l.revision_id=NEW.revision_id AND NOT EXISTS(SELECT FROM i18n.translation_heads h WHERE h.content_id=l.content_id AND h.language_code=target.language_code)
 ON CONFLICT DO NOTHING;
 RETURN NEW;
END $$;
CREATE TRIGGER translation_updates AFTER INSERT OR UPDATE ON governance.published_heads FOR EACH ROW EXECUTE FUNCTION governance.queue_translation_updates();
CREATE FUNCTION api.resolve_text(content uuid,preferred text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('text',COALESCE(t.translated_text,c.original_text),'language',CASE WHEN t.translation_id IS NULL THEN c.original_language ELSE t.language_code END,'direction',COALESCE(lang.direction,orig.direction),'is_translation',t.translation_id IS NOT NULL,'translation_class',t.translation_class,'content_id',c.content_id)
 FROM i18n.content_units c LEFT JOIN i18n.translation_heads h ON h.content_id=c.content_id AND h.language_code=preferred LEFT JOIN i18n.translation_publications p USING(publication_id) LEFT JOIN i18n.translations t ON t.translation_id=p.translation_id LEFT JOIN i18n.languages lang ON lang.language_code=t.language_code LEFT JOIN i18n.languages orig ON orig.language_code=c.original_language
 WHERE c.content_id=content AND governance.public_content(content)
$$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['translations','translation_reviews','translation_publications','translation_update_requests'] LOOP
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON i18n.%I FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation()',t);END LOOP;
END $$;
CREATE FUNCTION governance.register_language(code text,native_name text,english_name text,direction text,note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM governance.lock_operation();PERFORM governance.require_capability('propose',ARRAY[]::uuid[]);PERFORM governance.require_capability('approve',ARRAY[]::uuid[]);
 INSERT INTO i18n.languages VALUES(code,native_name,english_name,direction);
 INSERT INTO audit.events(actor_id,action,details) VALUES(governance.current_actor(),'register_content_language',jsonb_build_object('language',code,'reason',note));
END $$;
CREATE FUNCTION governance.prioritize_language(territory uuid,language text,priority integer,enabled boolean,note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM governance.lock_operation();PERFORM governance.require_capability('propose',ARRAY[territory]);PERFORM governance.require_capability('approve',ARRAY[territory]);
 INSERT INTO i18n.territory_language_priorities VALUES(territory,language,priority,enabled) ON CONFLICT(territory_id,language_code) DO UPDATE SET priority=EXCLUDED.priority,enabled_for_translation_work=EXCLUDED.enabled_for_translation_work;
 IF enabled THEN
 INSERT INTO i18n.translation_update_requests(entity_id,field_code,component_scope,language_code,required_content_id,reason)
 SELECT h.entity_id,l.field_code,l.component_scope,language,l.content_id,'territory_language_prioritized' FROM governance.published_heads h JOIN i18n.revision_content_links l USING(revision_id)
 WHERE territory=ANY(governance.translation_scope(l.content_id)) AND governance.public_content(l.content_id) AND NOT EXISTS(SELECT FROM i18n.translation_heads th WHERE th.content_id=l.content_id AND th.language_code=language)
 ON CONFLICT DO NOTHING;
 END IF;
 INSERT INTO audit.events(actor_id,action,entity_id,details) VALUES(governance.current_actor(),'prioritize_content_language',territory,jsonb_build_object('language',language,'priority',priority,'enabled',enabled,'reason',note));
END $$;
CREATE FUNCTION governance.translation_worklist(territory uuid DEFAULT NULL) RETURNS SETOF governance.translation_work
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM governance.require_capability('propose',CASE WHEN territory IS NULL THEN ARRAY[]::uuid[] ELSE ARRAY[territory] END);
 RETURN QUERY SELECT w.* FROM governance.translation_work w WHERE territory IS NULL OR territory=ANY(governance.translation_scope(w.required_content_id));
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA governance FROM PUBLIC;
REVOKE ALL ON FUNCTION api.resolve_text(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION governance.translation_worklist(uuid) TO egi_writer;
GRANT EXECUTE ON FUNCTION governance.register_language(text,text,text,text,text),governance.prioritize_language(uuid,text,integer,boolean,text) TO egi_writer;
GRANT EXECUTE ON FUNCTION governance.propose_translation(uuid,text,text,text,text,uuid,text),governance.review_translation(uuid,text,text),governance.publish_translation(uuid,uuid,uuid,text) TO egi_writer;
GRANT EXECUTE ON FUNCTION api.resolve_text(uuid,text) TO egi_reader;
COMMIT;
