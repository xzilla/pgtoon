-- pgtoon test suite
-- Tests conform to TOON Specification v3.3
-- https://github.com/toon-format/spec/blob/main/SPEC.md
--
-- Run against an installed build (canonical source needs @extschema@ substitution):
--   make local && psql -f pgtoon-local.sql
--   psql -c "SET search_path = toon, pg_catalog, pg_temp" -f test_pgtoon.sql

\set ON_ERROR_STOP on

-- =============================================================================
-- Setup
-- =============================================================================
CREATE TEMP TABLE test_results (
    test_name text,
    passed boolean,
    expected text,
    actual text
);

CREATE OR REPLACE FUNCTION assert_toon(test_name text, actual text, expected text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO test_results VALUES (test_name, actual IS NOT DISTINCT FROM expected, expected, actual);
    IF actual IS DISTINCT FROM expected THEN
        RAISE NOTICE 'FAIL: % — expected [%], got [%]', test_name, expected, actual;
    END IF;
END;
$$;

-- =============================================================================
-- §7.1 / §7.3: Key quoting
-- =============================================================================
SELECT assert_toon('key: simple alpha',
    toon_quote_key('name'), 'name');

SELECT assert_toon('key: with underscore',
    toon_quote_key('user_id'), 'user_id');

SELECT assert_toon('key: with dot (valid unquoted per §7.3)',
    toon_quote_key('user.name'), 'user.name');

SELECT assert_toon('key: with hyphen (must quote)',
    toon_quote_key('my-key'), '"my-key"');

SELECT assert_toon('key: starts with digit (must quote)',
    toon_quote_key('1st'), '"1st"');

SELECT assert_toon('key: with space (must quote)',
    toon_quote_key('first name'), '"first name"');

SELECT assert_toon('key: with colon (must quote)',
    toon_quote_key('time:zone'), '"time:zone"');

-- =============================================================================
-- §7.2: Value quoting
-- =============================================================================
SELECT assert_toon('val: simple string no quote needed',
    toon_quote_value('hello', ','), 'hello');

SELECT assert_toon('val: empty string must quote',
    toon_quote_value('', ','), '""');

SELECT assert_toon('val: leading space must quote',
    toon_quote_value(' hi', ','), '" hi"');

SELECT assert_toon('val: trailing space must quote',
    toon_quote_value('hi ', ','), '"hi "');

SELECT assert_toon('val: literal true must quote',
    toon_quote_value('true', ','), '"true"');

SELECT assert_toon('val: literal false must quote',
    toon_quote_value('false', ','), '"false"');

SELECT assert_toon('val: literal null must quote',
    toon_quote_value('null', ','), '"null"');

SELECT assert_toon('val: numeric-like must quote',
    toon_quote_value('42', ','), '"42"');

SELECT assert_toon('val: negative numeric must quote',
    toon_quote_value('-3.14', ','), '"-3.14"');

SELECT assert_toon('val: contains comma (active delim)',
    toon_quote_value('a,b', ','), '"a,b"');

SELECT assert_toon('val: contains pipe (not active delim for comma)',
    toon_quote_value('a|b', ','), 'a|b');

SELECT assert_toon('val: contains pipe (active delim for pipe)',
    toon_quote_value('a|b', '|'), '"a|b"');

SELECT assert_toon('val: contains colon must quote',
    toon_quote_value('http://x', ','), '"http://x"');

SELECT assert_toon('val: contains backslash must quote and escape',
    toon_quote_value(E'path\\to', ','), E'"path\\\\to"');

SELECT assert_toon('val: contains double quote must quote and escape',
    toon_quote_value('say "hi"', ','), '"say \"hi\""');

SELECT assert_toon('val: starts with hyphen must quote',
    toon_quote_value('-flag', ','), '"-flag"');

SELECT assert_toon('val: contains brackets must quote',
    toon_quote_value('[arr]', ','), '"[arr]"');

SELECT assert_toon('val: contains braces must quote',
    toon_quote_value('{obj}', ','), '"{obj}"');

SELECT assert_toon('val: internal space OK unquoted',
    toon_quote_value('hello world', ','), 'hello world');

SELECT assert_toon('val: unicode OK unquoted',
    toon_quote_value('café', ','), 'café');

SELECT assert_toon('val: emoji OK unquoted',
    toon_quote_value('👍', ','), '👍');

-- =============================================================================
-- §8: row_to_toon — single record as TOON object
-- =============================================================================

-- Basic record
SELECT assert_toon('row: simple int and string',
    row_to_toon(row(1, 'foo')),
    E'f1: 1\nf2: foo');

-- Named columns
SELECT assert_toon('row: named columns',
    row_to_toon(q),
    E'id: 42\nname: Alice\nactive: true')
FROM (SELECT 42 AS id, 'Alice' AS name, true AS active) q;

-- NULL becomes literal null (§2)
SELECT assert_toon('row: null value',
    row_to_toon(q),
    E'a: 1\nb: null\nc: hello')
FROM (SELECT 1 AS a, NULL::text AS b, 'hello' AS c) q;

-- Boolean values (§2: lowercase literals)
SELECT assert_toon('row: booleans',
    row_to_toon(q),
    E'flag_a: true\nflag_b: false')
FROM (SELECT true AS flag_a, false AS flag_b) q;

-- Numeric values
SELECT assert_toon('row: numeric types',
    row_to_toon(q),
    E'i: 42\nf: 3.14\nbig: 1000000')
FROM (SELECT 42 AS i, 3.14 AS f, 1000000::bigint AS big) q;

-- NaN/Infinity → null per §3
-- Note: PostgreSQL row_to_json outputs NaN/Infinity as bare JSON tokens.
-- Our encoder detects these and converts to null per TOON §3.
SELECT assert_toon('row: NaN becomes null',
    row_to_toon(q),
    E'val: null')
FROM (SELECT 'NaN'::float8 AS val) q;

SELECT assert_toon('row: Infinity becomes null',
    row_to_toon(q),
    E'val: null')
FROM (SELECT 'Infinity'::float8 AS val) q;

SELECT assert_toon('row: -Infinity becomes null',
    row_to_toon(q),
    E'val: null')
FROM (SELECT '-Infinity'::float8 AS val) q;

-- String needing quoting (contains comma = document delimiter)
SELECT assert_toon('row: string with comma quoted',
    row_to_toon(q),
    E'val: "a,b"')
FROM (SELECT 'a,b' AS val) q;

-- String with colon (must quote per §7.2)
SELECT assert_toon('row: string with colon quoted',
    row_to_toon(q),
    E'val: "http://example.com"')
FROM (SELECT 'http://example.com' AS val) q;

-- Date values (rendered as string, no quoting needed if no special chars)
SELECT assert_toon('row: date value',
    row_to_toon(q),
    E'd: 2014-05-28')
FROM (SELECT '2014-05-28'::date AS d) q;

-- Key needing quoting
SELECT assert_toon('row: key with hyphen quoted',
    row_to_toon(q),
    E'"my-field": hello')
FROM (SELECT 'hello' AS "my-field") q;

-- Empty string value must be quoted
SELECT assert_toon('row: empty string value',
    row_to_toon(q),
    E'a: ""\nb: real')
FROM (SELECT ''::text AS a, 'real' AS b) q;

-- =============================================================================
-- §9.3: toon_agg — tabular array encoding
-- =============================================================================

CREATE TEMP TABLE users (id int, name text, role text);
INSERT INTO users VALUES (1, 'Alice', 'admin'), (2, 'Bob', 'user'), (3, 'Carol', 'dev');

-- Basic tabular array (comma delimiter, default)
SELECT assert_toon('agg: basic tabular comma',
    (SELECT toon_agg(q) FROM (SELECT id, name, role FROM users ORDER BY id) q),
    E'[3]{id,name,role}:\n  1,Alice,admin\n  2,Bob,user\n  3,Carol,dev');

-- Tabular with null value
TRUNCATE users;
INSERT INTO users VALUES (1, 'Alice', 'admin'), (2, NULL, 'user');

SELECT assert_toon('agg: tabular with null',
    (SELECT toon_agg(q) FROM (SELECT id, name, role FROM users ORDER BY id) q),
    E'[2]{id,name,role}:\n  1,Alice,admin\n  2,null,user');

-- Tabular with value needing quoting (contains comma)
TRUNCATE users;
INSERT INTO users VALUES (1, 'Alice, Jr.', 'admin');

SELECT assert_toon('agg: tabular with quoted value (comma in data)',
    (SELECT toon_agg(q) FROM (SELECT id, name, role FROM users ORDER BY id) q),
    E'[1]{id,name,role}:\n  1,"Alice, Jr.",admin');

-- Tabular with pipe delimiter
TRUNCATE users;
INSERT INTO users VALUES (1, 'Alice', 'admin'), (2, 'Bob', 'user');

SELECT assert_toon('agg: tabular pipe delimiter',
    (SELECT toon_agg(q, '|') FROM (SELECT id, name, role FROM users ORDER BY id) q),
    E'[2|]{id|name|role}:\n  1|Alice|admin\n  2|Bob|user');

-- Tabular with pipe delimiter and pipe in data (must quote)
TRUNCATE users;
INSERT INTO users VALUES (1, 'A|B', 'admin');

SELECT assert_toon('agg: pipe delim with pipe in data',
    (SELECT toon_agg(q, '|') FROM (SELECT id, name, role FROM users ORDER BY id) q),
    E'[1|]{id|name|role}:\n  1|"A|B"|admin');

-- Single row tabular
TRUNCATE users;
INSERT INTO users VALUES (42, 'test', 'dev');

SELECT assert_toon('agg: single row',
    (SELECT toon_agg(q) FROM (SELECT id, name FROM users ORDER BY id) q),
    E'[1]{id,name}:\n  42,test');

-- =============================================================================
-- §3: NaN/Infinity normalization in aggregates
-- =============================================================================
SELECT assert_toon('agg: NaN in tabular',
    (SELECT toon_agg(q) FROM (SELECT 'NaN'::float8 AS val, 'x' AS label) q),
    E'[1]{val,label}:\n  null,x');

-- =============================================================================
-- to_toon — generic value encoding
-- =============================================================================

-- Scalars
SELECT assert_toon('to_toon: integer',
    to_toon(42), '42');

SELECT assert_toon('to_toon: float',
    to_toon(3.14), '3.14');

SELECT assert_toon('to_toon: boolean true',
    to_toon(true), 'true');

SELECT assert_toon('to_toon: boolean false',
    to_toon(false), 'false');

SELECT assert_toon('to_toon: null',
    to_toon(NULL::int), 'null');

SELECT assert_toon('to_toon: simple string',
    to_toon('hello'::text), 'hello');

SELECT assert_toon('to_toon: string needing quote (comma)',
    to_toon('a,b'::text), '"a,b"');

SELECT assert_toon('to_toon: string literal true',
    to_toon('true'::text), '"true"');

SELECT assert_toon('to_toon: NaN float',
    to_toon('NaN'::float8), 'null');

SELECT assert_toon('to_toon: NaN string (should NOT be null)',
    to_toon('NaN'::text), 'NaN');

SELECT assert_toon('to_toon: Infinity string (should NOT be null)',
    to_toon('Infinity'::text), 'Infinity');

SELECT assert_toon('to_toon: -0',
    to_toon('-0'::float8), '0');

-- Arrays (§9.1 inline primitive)
SELECT assert_toon('to_toon: int array',
    to_toon(ARRAY[1,2,3]), '[3]: 1,2,3');

SELECT assert_toon('to_toon: text array',
    to_toon(ARRAY['foo','bar','baz']), '[3]: foo,bar,baz');

SELECT assert_toon('to_toon: text array with comma in value',
    to_toon(ARRAY['a,b','c']), '[2]: "a,b",c');

SELECT assert_toon('to_toon: empty array',
    to_toon(ARRAY[]::int[]), '[]');

SELECT assert_toon('to_toon: array with null',
    to_toon(ARRAY[1,NULL,3]::int[]), '[3]: 1,null,3');

SELECT assert_toon('to_toon: array with pipe delimiter',
    to_toon(ARRAY[1,2,3], '|'), '[3|]: 1|2|3');

-- Record (delegates to row_to_toon)
SELECT assert_toon('to_toon: record',
    to_toon(row(1, 'hi')),
    E'f1: 1\nf2: hi');

-- =============================================================================
-- Volatility: wrappers over to_json/row_to_json must be STABLE (GUC-dependent),
-- pure string helpers stay IMMUTABLE. Guards against wrong-result expression
-- indexes (see issue #2).
-- =============================================================================
SELECT assert_toon('volatility: STABLE wrappers, IMMUTABLE helpers',
    (SELECT string_agg(p.proname || '=' || p.provolatile::text, ',' ORDER BY p.proname)
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = (current_schemas(false))[1]
       AND p.prokind = 'f'
       AND p.proname IN ('row_to_toon', 'to_toon', 'toon_agg_ffunc',
                         'toon_agg_sfunc', 'toon_agg_sfunc_default',
                         'toon_encode_field', 'toon_escape',
                         'toon_quote_key', 'toon_quote_value')),
    'row_to_toon=s,to_toon=s,toon_agg_ffunc=s,toon_agg_sfunc=s,toon_agg_sfunc_default=s,'
    || 'toon_encode_field=i,toon_escape=i,toon_quote_key=i,toon_quote_value=i');

-- =============================================================================
-- Report results
-- =============================================================================
SELECT
    count(*) FILTER (WHERE passed) AS passed,
    count(*) FILTER (WHERE NOT passed) AS failed,
    count(*) AS total
FROM test_results;

SELECT test_name, expected, actual
FROM test_results
WHERE NOT passed
ORDER BY test_name;

-- Fail the run (non-zero psql exit under ON_ERROR_STOP) if any assertion failed
DO $$
DECLARE
    n_failed int;
BEGIN
    SELECT count(*) INTO n_failed FROM test_results WHERE NOT passed;
    IF n_failed > 0 THEN
        RAISE EXCEPTION '% test(s) failed', n_failed;
    END IF;
END;
$$;

-- Cleanup
DROP TABLE test_results;
DROP TABLE users;
DROP FUNCTION assert_toon;
