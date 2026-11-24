\set ON_ERROR_STOP on
CREATE FUNCTION pg_temp.assert_true(ok boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'assertion_failed: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.expect_error(statement text, wanted_state text, wanted_message text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE actual_state text; actual_message text;
BEGIN
 BEGIN EXECUTE statement;
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS actual_state=RETURNED_SQLSTATE,actual_message=MESSAGE_TEXT;
 END;
 IF actual_state IS DISTINCT FROM wanted_state OR (wanted_message IS NOT NULL AND position(wanted_message IN COALESCE(actual_message,''))=0) THEN
  RAISE EXCEPTION 'expected % (%), got % (%) for %',wanted_state,wanted_message,actual_state,actual_message,statement;
 END IF;
END $$;
