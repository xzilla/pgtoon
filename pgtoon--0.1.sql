-- pgtoon: TOON (Token-Oriented Object Notation) functions for PostgreSQL
--
-- Implements encoding functions conforming to the TOON Specification v3.3
-- https://github.com/toon-format/spec/blob/main/SPEC.md
--
-- TOON is a line-oriented, indentation-based format that encodes the JSON data
-- model with explicit structure and minimal quoting. This extension provides:
--
--   to_toon(anyelement)         → any value to TOON (scalar/array/record)
--   row_to_toon(record)         → TOON object (key: value lines)
--   toon_agg(anyelement)        → TOON tabular array with header + rows
--
-- Encoder options: delimiter (comma default), indentSize (2 default)
--
-- Security: every function pins search_path to pg_catalog, pg_temp and
-- qualifies internal calls with @extschema@ (the extension's own schema).
-- This is substituted at CREATE EXTENSION time (filesystem or pg_tle). For a
-- standalone psql install, generate a concrete-schema build via `make local`.

-- =============================================================================
-- toon_escape(text) — Apply §7.1 escape rules inside quoted strings
-- =============================================================================
CREATE FUNCTION toon_escape(val text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT replace(replace(replace(replace(replace(
        val,
        E'\\', E'\\\\'),   -- backslash first
        '"', E'\\"'),
        E'\n', E'\\n'),
        E'\r', E'\\r'),
        E'\t', E'\\t')
    -- Note: U+0000-U+001F other than \n\r\t need \uXXXX but PG text rarely contains these
$$;

-- =============================================================================
-- toon_quote_key(text) — Quote a key per §7.3
-- Keys MAY be unquoted only if they match ^[A-Za-z_][A-Za-z0-9_.]*$
-- =============================================================================
CREATE FUNCTION toon_quote_key(k text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE
        WHEN k ~ '^[A-Za-z_][A-Za-z0-9_.]*$' THEN k
        ELSE '"' || @extschema@.toon_escape(k) || '"'
    END
$$;

-- =============================================================================
-- toon_quote_value(text, text) — Quote a string value per §7.2
-- delim is the active/document delimiter to check against
-- =============================================================================
CREATE FUNCTION toon_quote_value(val text, delim text DEFAULT ',')
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE
        WHEN val = ''                                              THEN '""'
        WHEN val ~ '^\s' OR val ~ '\s$'                           THEN '"' || @extschema@.toon_escape(val) || '"'
        WHEN val IN ('true', 'false', 'null')                     THEN '"' || val || '"'
        WHEN val ~ '^-?\d+(\.\d+)?([eE][+-]?\d+)?$'              THEN '"' || val || '"'
        WHEN val ~ '[:"\\{}\[\]]'                                  THEN '"' || @extschema@.toon_escape(val) || '"'
        WHEN val ~ '[\x00-\x1f]'                                  THEN '"' || @extschema@.toon_escape(val) || '"'
        WHEN position(delim in val) > 0                           THEN '"' || @extschema@.toon_escape(val) || '"'
        WHEN left(val, 1) = '-'                                   THEN '"' || @extschema@.toon_escape(val) || '"'
        ELSE val
    END
$$;

-- =============================================================================
-- toon_encode_field(raw_json text, text_val text, delim text)
-- Encode a single field value for TOON output.
-- raw_json: the value::text from json_each (preserves JSON type markers)
-- text_val: the value from json_each_text (already unescaped text, NULL for json null)
-- delim: active delimiter for quoting decisions
-- =============================================================================
CREATE FUNCTION toon_encode_field(raw_json text, text_val text, delim text DEFAULT ',')
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE
        -- JSON null (text_val is SQL NULL from json_each_text)
        WHEN text_val IS NULL THEN 'null'
        -- §3: NaN, Infinity, -Infinity → null
        -- PG wraps these as JSON strings ("NaN"), so check both forms
        WHEN raw_json IN ('NaN', 'Infinity', '-Infinity',
                          '"NaN"', '"Infinity"', '"-Infinity"') THEN 'null'
        -- JSON booleans
        WHEN raw_json IN ('true', 'false') THEN raw_json
        -- JSON numbers (not quoted in JSON representation)
        WHEN raw_json ~ '^-?[0-9]' THEN
            CASE WHEN raw_json = '-0' THEN '0' ELSE raw_json END
        -- JSON strings — text_val is already the raw unescaped content
        ELSE @extschema@.toon_quote_value(text_val, delim)
    END
$$;

-- =============================================================================
-- row_to_toon(record, delimiter) — Convert a record to a TOON object
--
-- Output format (§8):
--   key1: value1
--   key2: value2
--
-- This is the direct analog of row_to_json(record).
-- =============================================================================
CREATE FUNCTION row_to_toon(rec anyelement, delim text DEFAULT ',')
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    rec_json json;
    lines text[];
BEGIN
    -- §11: only comma, pipe, and tab are legal delimiters. Fail loudly
    -- rather than emit a document that misdescribes its own structure.
    IF delim IS NULL OR delim NOT IN (',', '|', E'\t') THEN
        RAISE EXCEPTION 'pgtoon: delimiter must be comma, pipe, or tab (spec §11)';
    END IF;

    rec_json := row_to_json(rec);

    SELECT array_agg(
        @extschema@.toon_quote_key(e.key) || ': ' ||
        @extschema@.toon_encode_field(e.value::text, t.value, delim)
        ORDER BY e.ordinality
    )
    INTO lines
    FROM json_each(rec_json) WITH ORDINALITY AS e
    JOIN json_each_text(rec_json) WITH ORDINALITY AS t
        ON e.ordinality = t.ordinality;

    -- §12: no trailing newline
    RETURN array_to_string(lines, E'\n');
END;
$$;

-- =============================================================================
-- to_toon(anyelement, delimiter) — Convert any value to TOON
--
-- Handles scalars, arrays, and records (analog of to_json(anyelement)):
--   scalar        → primitive token
--   array         → [N]: v1,v2,... (§9.1 inline primitive array)
--   record/row    → key: value object (§8, delegates to row_to_toon)
--   NULL          → null
-- =============================================================================
CREATE FUNCTION to_toon(val anyelement, delim text DEFAULT ',')
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    j json;
    jtype text;
    n int;
    elems text[];
    delim_sym text;
    valtype text;
BEGIN
    -- §11: only comma, pipe, and tab are legal delimiters. Fail loudly
    -- rather than emit a document that misdescribes its own structure.
    IF delim IS NULL OR delim NOT IN (',', '|', E'\t') THEN
        RAISE EXCEPTION 'pgtoon: delimiter must be comma, pipe, or tab (spec §11)';
    END IF;

    IF val IS NULL THEN
        RETURN 'null';
    END IF;

    -- §3: NaN/Infinity normalization for float types only
    valtype := pg_typeof(val)::text;
    IF valtype IN ('double precision', 'real') THEN
        IF val::text IN ('NaN', 'Infinity', '-Infinity') THEN
            RETURN 'null';
        END IF;
        IF val::text = '-0' THEN
            RETURN '0';
        END IF;
    END IF;

    j := to_json(val);
    jtype := json_typeof(j);

    -- Scalar types: number, boolean, string, null
    IF jtype = 'number' THEN
        DECLARE raw text := j::text;
        BEGIN
            IF raw = '-0' THEN RETURN '0'; END IF;
            RETURN raw;
        END;
    ELSIF jtype = 'boolean' THEN
        RETURN j::text;
    ELSIF jtype = 'null' THEN
        RETURN 'null';
    ELSIF jtype = 'string' THEN
        RETURN @extschema@.toon_quote_value(j#>>'{}', delim);

    -- Array: emit as inline primitive array [N]: v1,v2,...
    ELSIF jtype = 'array' THEN
        n := json_array_length(j);
        IF n = 0 THEN
            RETURN '[]';
        END IF;

        SELECT array_agg(
            @extschema@.toon_encode_field(e.value::text, t.value, delim)
            ORDER BY e.ordinality
        )
        INTO elems
        FROM json_array_elements(j) WITH ORDINALITY AS e
        JOIN json_array_elements_text(j) WITH ORDINALITY AS t
            ON e.ordinality = t.ordinality;

        delim_sym := CASE
            WHEN delim = ',' THEN ''
            WHEN delim = '|' THEN '|'
            WHEN delim = E'\t' THEN E'\t'
            ELSE ''
        END;

        RETURN '[' || n || delim_sym || ']: ' || array_to_string(elems, delim);

    -- Object (record/composite): delegate to row_to_toon
    ELSIF jtype = 'object' THEN
        RETURN @extschema@.row_to_toon(val, delim);
    END IF;

    -- Fallback (shouldn't reach here)
    RETURN @extschema@.toon_quote_value(val::text, delim);
END;
$$;

-- =============================================================================
-- toon_agg — Aggregate records into a TOON tabular array (§9.3)
--
-- Output format:
--   [N<delim>]{field1<delim>field2<delim>...}:
--     val1<delim>val2<delim>...
--     val1<delim>val2<delim>...
--
-- Tabular form requires: all objects have same keys, all values are primitives.
-- This aggregate assumes uniform input (as row sources from SQL naturally are).
-- =============================================================================

-- State type to accumulate header + rows
CREATE TYPE toon_agg_state AS (
    fields text,
    rows text[],
    delim text
);

CREATE FUNCTION toon_agg_sfunc(state @extschema@.toon_agg_state, rec anyelement, delim text DEFAULT ',')
RETURNS @extschema@.toon_agg_state
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    rec_json json;
    row_line text;
BEGIN
    -- §11: only comma, pipe, and tab are legal delimiters. Fail loudly
    -- rather than emit a document that misdescribes its own structure.
    IF delim IS NULL OR delim NOT IN (',', '|', E'\t') THEN
        RAISE EXCEPTION 'pgtoon: delimiter must be comma, pipe, or tab (spec §11)';
    END IF;

    rec_json := row_to_json(rec);

    -- First invocation: capture field names
    IF state.fields IS NULL THEN
        SELECT string_agg(@extschema@.toon_quote_key(key), delim ORDER BY ordinality)
        INTO state.fields
        FROM json_each(rec_json) WITH ORDINALITY;
        state.delim := delim;
        state.rows := ARRAY[]::text[];
    END IF;

    -- Build row: encode each value with delimiter-aware quoting
    SELECT string_agg(
        @extschema@.toon_encode_field(e.value::text, t.value, delim),
        delim ORDER BY e.ordinality
    )
    INTO row_line
    FROM json_each(rec_json) WITH ORDINALITY AS e
    JOIN json_each_text(rec_json) WITH ORDINALITY AS t
        ON e.ordinality = t.ordinality;

    state.rows := state.rows || row_line;
    RETURN state;
END;
$$;

CREATE FUNCTION toon_agg_ffunc(state @extschema@.toon_agg_state)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    n int;
    header text;
    indent text := '  ';  -- §12: default indentSize = 2
    result text;
    delim_sym text;
BEGIN
    IF state.fields IS NULL THEN
        RETURN NULL;
    END IF;

    n := array_length(state.rows, 1);

    -- §6: delimiter symbol in bracket segment
    -- comma = no symbol, pipe = |, tab = literal tab
    delim_sym := CASE
        WHEN state.delim = ',' THEN ''
        WHEN state.delim = '|' THEN '|'
        WHEN state.delim = E'\t' THEN E'\t'
        ELSE ''
    END;

    -- §6/§9.3: [N<delim?>]{fields}:
    header := '[' || n || delim_sym || ']{' || state.fields || '}:';

    -- §9.3: rows at depth +1 (indented)
    result := header;
    FOR i IN 1..n LOOP
        result := result || E'\n' || indent || state.rows[i];
    END LOOP;

    -- §12: no trailing newline
    RETURN result;
END;
$$;

CREATE AGGREGATE toon_agg(anyelement, text) (
    SFUNC = @extschema@.toon_agg_sfunc,
    STYPE = @extschema@.toon_agg_state,
    FINALFUNC = @extschema@.toon_agg_ffunc,
    INITCOND = '(,,)'
);

-- Convenience overload with default comma delimiter
CREATE FUNCTION toon_agg_sfunc_default(state @extschema@.toon_agg_state, rec anyelement)
RETURNS @extschema@.toon_agg_state
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT @extschema@.toon_agg_sfunc(state, rec, ',')
$$;

CREATE AGGREGATE toon_agg(anyelement) (
    SFUNC = @extschema@.toon_agg_sfunc_default,
    STYPE = @extschema@.toon_agg_state,
    FINALFUNC = @extschema@.toon_agg_ffunc,
    INITCOND = '(,,)'
);
