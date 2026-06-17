# pgtoon — TOON Support for PostgreSQL

A pure PL/pgSQL implementation of [TOON (Token-Oriented Object Notation)](https://toonformat.dev) encoding for PostgreSQL, conforming to **TOON Specification v3.3**.

NOTE: This code is completely vibe coded and should be considered
experimental, although by its nature it is non-destructive. Feedback welcome.


## What is TOON?

TOON is a line-oriented, indentation-based text format that encodes the JSON data model with explicit structure and minimal quoting. It's designed for token efficiency in LLM contexts — arrays of objects declare their shape once and use compact delimiter-separated rows.

```
[3]{id,name,role}:
  1,Alice,admin
  2,Bob,user
  3,Carol,dev
```

vs. the equivalent JSON (96 bytes larger):

```json
[{"id":1,"name":"Alice","role":"admin"},{"id":2,"name":"Bob","role":"user"},{"id":3,"name":"Carol","role":"dev"}]
```

## Installation

### Standard (filesystem extension)

```sql
\i pgtoon--0.1.sql
```

Requires PostgreSQL 12+.

### As a Trusted Language Extension (pg_tle)

For managed environments without filesystem access (e.g. Amazon RDS / Aurora),
install via [pg_tle](https://github.com/aws/pg_tle). The `create_pgtle_scripts.sh`
helper reads `pgtoon.control` and generates `.pgtle-pgtoon.sql`:

```sh
EXTENSION=pgtoon ./create_pgtle_scripts.sh pgtoon--0.1.sql
psql -f .pgtle-pgtoon.sql
```

Or via the Makefile (defaults to `USE_PGTLE=1`):

```sh
make install PGDB=mydb PGUSER=postgres PGHOST=localhost PGPORT=5432
```

Then, in the target database:

```sql
CREATE EXTENSION pgtoon;
```

To install as a standard filesystem extension via PGXS instead:

```sh
make install USE_PGTLE=0
```

## Functions

### `row_to_toon(record, delimiter text DEFAULT ',')`

Converts a single record to a TOON object (§8). Analog of `row_to_json()`.

```sql
SELECT row_to_toon(q) FROM (SELECT 42 AS id, 'Alice' AS name, true AS active) q;
```

Output:
```
id: 42
name: Alice
active: true
```

### `toon_agg(anyelement)` / `toon_agg(anyelement, delimiter text)`

Aggregate function that produces a TOON tabular array (§9.3). This is where the real compression wins are — field names declared once, rows are compact delimiter-separated values.

```sql
SELECT toon_agg(q)
FROM (SELECT id, name, role FROM users ORDER BY id) q;
```

Output:
```
[3]{id,name,role}:
  1,Alice,admin
  2,Bob,user
  3,Carol,dev
```

With pipe delimiter:

```sql
SELECT toon_agg(q, '|')
FROM (SELECT id, name, role FROM users ORDER BY id) q;
```

Output:
```
[3|]{id|name|role}:
  1|Alice|admin
  2|Bob|user
  3|Carol|dev
```

### `toon_quote_key(text)`

Quotes a key per §7.3. Keys matching `^[A-Za-z_][A-Za-z0-9_.]*$` are emitted bare; others are quoted.

### `toon_quote_value(text, delimiter text DEFAULT ',')`

Quotes a string value per §7.2. Returns the value quoted only when required (empty, whitespace, reserved words, contains delimiter/colon/special chars, starts with hyphen, numeric-like).

### `toon_escape(text)`

Applies §7.1 escape rules inside quoted strings: `\\`, `\"`, `\n`, `\r`, `\t`.

## Spec Conformance

This implementation targets the encoder conformance checklist (§13.1):

| Requirement | Status |
|---|---|
| UTF-8 output with LF line endings | ✅ |
| Consistent indentation (2 spaces) | ✅ |
| Escape per §7.1 in quoted strings | ✅ |
| Quote strings per §7.2 | ✅ |
| Array lengths [N] match count | ✅ |
| Preserve object key order | ✅ |
| Numbers per §2 | ✅ (delegated to PG) |
| -0 → 0 | ✅ |
| Booleans/null as lowercase | ✅ |
| NaN/±Infinity → null | ✅ |
| No trailing spaces or newline | ✅ |

### Known Limitations

- **U+0000–U+001F control chars** (other than `\n`, `\r`, `\t`): should emit `\uXXXX` but PG text fields rarely contain these. Not yet implemented.
- **Nested objects/arrays in record fields**: values that are themselves composite types are rendered via their text representation. True recursive TOON nesting would require deeper type introspection than PL/pgSQL allows.
- **`toon_agg` assumes tabular-eligible input**: all rows must have the same fields with primitive values. SQL query results naturally satisfy this constraint.
- **Number canonical form**: deferred to PostgreSQL's numeric output. PG generally conforms (no leading zeros, no trailing zeros in decimal) but edge cases with very small/large floats may emit exponent notation differently than spec prefers.

## Delimiter Support

Per §11, three delimiters are supported:

| Delimiter | Header syntax | Example |
|---|---|---|
| Comma (default) | `[N]{fields}:` | `[2]{id,name}: 1,Alice` |
| Pipe | `[N\|]{fields}:` | `[2\|]{id\|name}: 1\|Alice` |
| Tab | `[N\t]{fields}:` | `[2\t]{id\tname}: 1\tAlice` |

## Running Tests

```sql
\i pgtoon--0.1.sql
\i test_pgtoon.sql
```

The test suite validates key quoting, value quoting, object encoding, tabular array encoding, null handling, NaN/Infinity normalization, and delimiter variants.

## Future Work

Functions to be implemented (mapping from PostgreSQL JSON functions):

| JSON Function | TOON Equivalent | Notes |
|---|---|---|
| `to_json(anyelement)` | `to_toon(anyelement)` | Generic scalar/composite → TOON |
| `array_to_json(anyarray)` | `array_to_toon(anyarray)` | Primitive array → inline `[N]: v1,v2` |
| `json_agg(anyelement)` | `toon_agg(anyelement)` | ✅ Implemented |
| `json_build_object(...)` | — | TOON objects are structural, not a single token |
| `json_each(json)` | `toon_parse_object(text)` | Decode TOON object → set of (key, value) |
| `json_populate_record(...)` | `toon_populate_record(...)` | Decode tabular TOON row → record |

## Specification Reference

- Full spec: https://github.com/toon-format/spec/blob/main/SPEC.md
- Website: https://toonformat.dev
- Syntax cheatsheet: https://toonformat.dev/reference/syntax-cheatsheet.html
