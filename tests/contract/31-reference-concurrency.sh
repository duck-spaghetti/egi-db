#!/bin/sh
# Disposable egi_contract only: two verified sessions accept one proposal at once.
set -eu
case "${PGHOST:-}:${PGDATABASE:-}" in /private/tmp/egi-*:egi_contract|/private/tmp/egi.*:egi_contract) ;; *) echo 'requires disposable egi_contract socket' >&2; exit 1;; esac
EGI_PSQL=${EGI_PSQL:-psql}
EGI_REFERENCE_TMP=$(mktemp -d)
trap 'rm -rf "$EGI_REFERENCE_TMP"' EXIT HUP INT TERM
"$EGI_PSQL" -X -q -v ON_ERROR_STOP=1 -v prepare_reference_race=1 -f tests/contract/30-reference-catalog.sql > "$EGI_REFERENCE_TMP/setup.log"
for EGI_REFERENCE_TOKEN in session30-a session30-b; do
 "$EGI_PSQL" -X -q -v ON_ERROR_STOP=1 -v token="$EGI_REFERENCE_TOKEN" > "$EGI_REFERENCE_TMP/$EGI_REFERENCE_TOKEN.log" 2>&1 <<'SQL' &
BEGIN;
SET SESSION AUTHORIZATION egi_probe30;
SELECT access.verify_session(encode(sha256(convert_to(:'token','UTF8')),'hex'));
SELECT editorial.accept_community_item(contribution,decision,gen_random_uuid()) FROM public.egi_reference_race;
COMMIT;
SQL
 if [ "$EGI_REFERENCE_TOKEN" = session30-a ]; then EGI_REFERENCE_A=$!; else EGI_REFERENCE_B=$!; fi
done
wait "$EGI_REFERENCE_A" || { cat "$EGI_REFERENCE_TMP/session30-a.log" >&2; exit 1; }
wait "$EGI_REFERENCE_B" || { cat "$EGI_REFERENCE_TMP/session30-b.log" >&2; exit 1; }
"$EGI_PSQL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF (SELECT count(*) FROM editorial.community_fact_resolutions)<>1 OR
  (SELECT count(*) FROM data.organizations)<>1 OR (SELECT count(*) FROM editorial.community_resolutions)<>1 THEN
  RAISE EXCEPTION 'reference_acceptance_race_created_duplicates'; END IF;
END $$;
SQL
printf '%s\n' 'PASS: concurrent explicit acceptance creates one organization/service/resolution'
