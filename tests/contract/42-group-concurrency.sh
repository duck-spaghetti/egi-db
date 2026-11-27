#!/bin/sh
# Actual independent owner/editor sessions, inherited owned cluster only.
set -eu
case "${PGHOST:-}:${PGDATABASE:-}" in
 /private/tmp/egi-resource-*/pg-*:egi_workbench) ;;
 *) echo 'requires the owned workbench socket' >&2; exit 1 ;;
esac
EGI_RACE_LOGS=$(mktemp -d /private/tmp/egi-cw1-group-race.XXXXXX)
trap 'case "$EGI_RACE_LOGS" in /private/tmp/egi-cw1-group-race.*) rm -rf -- "$EGI_RACE_LOGS" ;; esac' EXIT HUP INT TERM
"${EGI_PSQL:?}" -X -q -v ON_ERROR_STOP=1 -f tests/contract/42-group-concurrency.sql > "$EGI_RACE_LOGS/setup.log"
for EGI_RACE_TOKEN in session30 group-race-editor; do
 "${EGI_PSQL}" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -v token="$EGI_RACE_TOKEN" > "$EGI_RACE_LOGS/$EGI_RACE_TOKEN.log" 2>&1 <<'SQL' &
BEGIN;
SET SESSION AUTHORIZATION egi_probe30;
SELECT access.verify_session(encode(sha256(convert_to(:'token','UTF8')),'hex'));
SELECT preparation.save_group(workspace_id,expected,jsonb_set(jsonb_set(body,'{version}',to_jsonb(gen_random_uuid())),'{parent_versions}',jsonb_build_array(expected)),gen_random_uuid()) FROM public.egi_workbench_group_race;
COMMIT;
SQL
 if [ "$EGI_RACE_TOKEN" = session30 ]; then EGI_RACE_A=$!; else EGI_RACE_B=$!; fi
done
EGI_RACE_A_STATUS=0
EGI_RACE_B_STATUS=0
wait "$EGI_RACE_A" || EGI_RACE_A_STATUS=$?
wait "$EGI_RACE_B" || EGI_RACE_B_STATUS=$?
if [ "$EGI_RACE_A_STATUS" = 0 ] && [ "$EGI_RACE_B_STATUS" != 0 ]; then
 EGI_RACE_LOSER="$EGI_RACE_LOGS/group-race-editor.log"
elif [ "$EGI_RACE_B_STATUS" = 0 ] && [ "$EGI_RACE_A_STATUS" != 0 ]; then
 EGI_RACE_LOSER="$EGI_RACE_LOGS/session30.log"
else
 cat "$EGI_RACE_LOGS/session30.log" "$EGI_RACE_LOGS/group-race-editor.log" >&2
 exit 1
fi
rg '40001.*group_head_conflict' "$EGI_RACE_LOSER" > /dev/null
"${EGI_PSQL}" -X -q -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF (SELECT count(*) FROM preparation.group_revisions r JOIN public.egi_workbench_group_race race ON r.group_id=(race.body->>'group_id')::uuid)<>2 THEN RAISE EXCEPTION 'group_race_created_two_successors'; END IF;
 IF EXISTS(SELECT FROM preparation.private_groups g JOIN public.egi_workbench_group_race race ON g.group_id=(race.body->>'group_id')::uuid WHERE g.current_version=race.expected) THEN RAISE EXCEPTION 'group_race_head_unchanged'; END IF;
END $$;
DROP TRIGGER egi_group_race_delay ON preparation.private_groups;
DROP FUNCTION public.egi_group_race_delay();
SQL
printf '%s\n' 'PASS: concurrent owner/editor edits produce one successor and one expected-head conflict; authorize(workspace,true) serializes the write.'
