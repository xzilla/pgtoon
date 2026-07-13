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
-- rows_to_toon(anyarray, delimiter) — Encode an array of records as a TOON
-- tabular array (§9.3) in a single set-based pass.
--
-- This is the linear-time workhorse behind toon_agg(anyelement), and the
-- recommended path for large row counts with a non-default delimiter:
--
--     SELECT rows_to_toon(array_agg(q), '|') FROM (...) q;
--
-- array_agg uses a C-language transition function with internal state, so
-- collection is O(n); this function then encodes all rows in one pass.
-- =============================================================================
-- Scalar validation helpers (plpgsql cannot accept record[], so rows_to_toon
-- itself must be LANGUAGE sql; these carry the RAISE logic on scalars).
CREATE FUNCTION toon_delim_ok(delim text)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF delim IS NULL OR delim NOT IN (',', '|', E'\t') THEN
        RAISE EXCEPTION 'pgtoon: delimiter must be comma, pipe, or tab (spec §11)';
    END IF;
    RETURN true;
END;
$$;

CREATE FUNCTION toon_rows_ok(ndims int, bad int)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF ndims <> 1 THEN
        RAISE EXCEPTION 'pgtoon: rows_to_toon requires a one-dimensional array';
    END IF;
    IF bad > 0 THEN
        RAISE EXCEPTION 'pgtoon: rows_to_toon requires an array of records (got % non-record element(s))', bad;
    END IF;
    RETURN true;
END;
$$;

-- LANGUAGE sql on purpose: SQL functions accept record[] (anonymous row types
-- from subqueries), which plpgsql rejects at compile time.
--
-- NULL elements (e.g. unmatched rows from a LEFT JOIN feeding toon_agg) are
-- SKIPPED — a TOON tabular row cannot represent a null record, and the [N]
-- count reflects only the encoded rows. Non-record elements raise.
--
-- STABLE, not IMMUTABLE: output flows through array_to_json, whose rendering
-- of timestamps/floats depends on session GUCs.
--
-- Implementation note: the array is serialized ONCE via array_to_json and
-- iterated with json_array_elements. Never subscript a large flat array in a
-- loop (rows[i]): element access in a flat varlena array is O(i), which turns
-- a full pass into O(n²). (Expanded arrays don't have that problem, but a
-- caller-supplied array_agg result arrives flat.)
CREATE FUNCTION rows_to_toon(rows anyarray, delim text DEFAULT ',')
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH elems AS (
        SELECT a.elem, a.ord, json_typeof(a.elem) AS jt
        FROM json_array_elements(array_to_json(rows)) WITH ORDINALITY AS a(elem, ord)
    ),
    enc AS (
        SELECT ord, jt,
               CASE WHEN jt = 'object' THEN
                   (SELECT string_agg(@extschema@.toon_encode_field(e.value::text, t.value, delim),
                                      delim ORDER BY e.ordinality)
                    FROM json_each(elem) WITH ORDINALITY AS e
                    JOIN json_each_text(elem) WITH ORDINALITY AS t
                        ON e.ordinality = t.ordinality)
               END AS line
        FROM elems
    )
    SELECT CASE
        WHEN NOT @extschema@.toon_delim_ok(delim) THEN NULL
        WHEN rows IS NULL OR cardinality(rows) = 0 THEN NULL
        WHEN NOT @extschema@.toon_rows_ok(array_ndims(rows),
                 count(*) FILTER (WHERE jt NOT IN ('object', 'null'))::int) THEN NULL
        -- all elements NULL (e.g. every LEFT JOIN row unmatched) → NULL,
        -- matching an aggregate over zero rows
        WHEN count(*) FILTER (WHERE jt = 'object') = 0 THEN NULL
        ELSE
            -- §6/§9.3: [N<delim?>]{fields}: — comma has no symbol; pipe and
            -- tab are their own symbols. Rows at depth +1; no trailing newline.
            -- N counts encoded rows only (NULL records are skipped).
            '[' || count(*) FILTER (WHERE jt = 'object')
                || CASE WHEN delim = ',' THEN '' ELSE delim END || ']{'
            || (SELECT string_agg(@extschema@.toon_quote_key(key), delim ORDER BY ordinality)
                FROM json_each((SELECT elem FROM elems WHERE jt = 'object' ORDER BY ord LIMIT 1)) WITH ORDINALITY)
            || '}:' || E'\n  '
            || string_agg(line, E'\n  ' ORDER BY ord)
    END
    FROM enc
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

-- The default-delimiter aggregate collects rows with pg_catalog.array_append —
-- a C transition function, which is the only kind PostgreSQL keeps O(1) per
-- row (the executor keeps the state as a read-write expanded array in place).
-- Any SQL or plpgsql transition function is flattened/re-expanded at every
-- call, making accumulation O(n²) regardless of what the function body does
-- (measured: 39 s for a 40k-row aggregate; this shape takes ~1 s, issue #4).
-- All encoding happens once, in the finalizer, via rows_to_toon.

CREATE FUNCTION toon_agg_rows_ffunc(state anycompatiblearray)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT @extschema@.rows_to_toon(state, ',')
$$;

CREATE AGGREGATE toon_agg(anycompatible) (
    SFUNC = pg_catalog.array_append,
    STYPE = anycompatiblearray,
    FINALFUNC = @extschema@.toon_agg_rows_ffunc,
    INITCOND = '{}'
);

-- Explicit-delimiter variant. array_append cannot carry the extra delimiter
-- argument, so this keeps a plpgsql transition function: per-row encoding
-- into a text[] state (state[1] = field header, state[2] = delimiter,
-- state[3..] = encoded rows). The transition-boundary copying makes it
-- quadratic in row count; for large sets prefer
--     rows_to_toon(array_agg(q), '|')
-- which collects in C and encodes in one pass.

CREATE FUNCTION toon_agg_sfunc(state text[], rec anyelement, delim text DEFAULT ',')
RETURNS text[]
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    rec_json json;
    row_line text;
BEGIN
    -- Skip NULL records (e.g. unmatched LEFT JOIN rows): a TOON tabular row
    -- cannot represent a null record, and [N] must describe the actual rows.
    IF rec IS NULL THEN
        RETURN state;
    END IF;

    rec_json := row_to_json(rec);

    -- First invocation: capture field names and delimiter
    IF state IS NULL OR cardinality(state) = 0 THEN
        SELECT ARRAY[string_agg(@extschema@.toon_quote_key(key), delim ORDER BY ordinality), delim]
        INTO state
        FROM json_each(rec_json) WITH ORDINALITY;
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

    state := state || row_line;
    RETURN state;
END;
$$;

CREATE FUNCTION toon_agg_ffunc(state text[])
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    n int;
    delim_sym text;
BEGIN
    IF cardinality(state) = 0 OR state[1] IS NULL THEN
        RETURN NULL;
    END IF;

    n := cardinality(state) - 2;

    -- §6: delimiter symbol in bracket segment
    delim_sym := CASE
        WHEN state[2] = ',' THEN ''
        WHEN state[2] = '|' THEN '|'
        WHEN state[2] = E'\t' THEN E'\t'
        ELSE ''
    END;

    -- §6/§9.3: [N<delim?>]{fields}: with rows at depth +1, no trailing newline
    RETURN '[' || n || delim_sym || ']{' || state[1] || '}:'
        || E'\n  ' || array_to_string(state[3:], E'\n  ');
END;
$$;

CREATE AGGREGATE toon_agg(anyelement, text) (
    SFUNC = @extschema@.toon_agg_sfunc,
    STYPE = text[],
    FINALFUNC = @extschema@.toon_agg_ffunc,
    INITCOND = '{}'
);
