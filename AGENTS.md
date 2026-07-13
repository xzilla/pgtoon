# pgtoon — Agent Context

This file provides context for AI coding agents working on the pgtoon project.
It covers architecture, conventions, testing, and known constraints so you can
contribute effectively without re-discovering decisions already made.

## Project Summary

pgtoon is a pure PL/pgSQL PostgreSQL extension that encodes query results as
TOON (Token-Oriented Object Notation) — a compact, line-oriented format
designed for LLM prompt contexts. It conforms to TOON Specification v3.3.

- Spec: https://github.com/toon-format/spec/blob/main/SPEC.md
- Website: https://toonformat.dev

## Repository Layout

```
pgtoon--0.1.sql          # Canonical extension source (contains @extschema@ markers)
pgtoon.control           # PostgreSQL extension metadata (relocatable=false)
test_pgtoon.sql          # Regression suite (67 assertions)
Makefile                 # Build targets: tle (default), local, clean, help
create_pgtle_scripts.sh  # Vendored pg_tle helper (from github.com/aws/pg_tle)
README.md                # User-facing documentation
AGENTS.md                # This file
```

## Architecture

### Functions (public API)

| Function | Purpose |
|----------|---------|
| `to_toon(anyelement, delim)` | Generic encoder: scalars, arrays, records → TOON |
| `row_to_toon(record, delim)` | Record → TOON object (`key: value` lines) |
| `toon_agg(anyelement [, delim])` | Aggregate → TOON tabular array with header + rows |

### Internal helpers (not intended for direct use)

| Function | Purpose |
|----------|---------|
| `toon_escape(text)` | §7.1 escape rules inside quoted strings |
| `toon_quote_key(text)` | §7.3 key quoting |
| `toon_quote_value(text, delim)` | §7.2 value quoting |
| `toon_encode_field(raw_json, text_val, delim)` | Type-aware field encoding |

### Type

| Type | Purpose |
|------|---------|
| `toon_agg_state` | Composite type holding aggregate state (fields, rows[], delim) |

### Design Decisions

- **Uses `row_to_json` + `json_each` internally** to introspect record field
  names and values, since PL/pgSQL cannot iterate over record fields natively.
- **Type detection uses dual scan**: `json_each` (preserves JSON type markers in
  `value::text`) joined with `json_each_text` (provides unescaped text, NULL for
  JSON null) on ordinality. This avoids fragile JSON unescaping.
- **NaN/Infinity detection**: uses `pg_typeof(val)` to distinguish float NaN
  (→ null per §3) from the string literal "NaN" (→ normal string). PG wraps
  float NaN as a JSON string `"NaN"`, making them otherwise indistinguishable.

## Security Model

Every function has:
- `SET search_path = pg_catalog, pg_temp` (locked, no user-controlled schemas)
- Internal calls qualified with `@extschema@` (substituted at CREATE EXTENSION)
- `CREATE FUNCTION` (not `OR REPLACE`) to prevent pre-creation attacks

The extension is `relocatable = false` because `@extschema@` substitution
requires it for both filesystem and pg_tle installs.

## Build & Install Paths

There are three install methods. The canonical source `pgtoon--0.1.sql` contains
`@extschema@` markers that get substituted at `CREATE EXTENSION` time.

| Method | Command | How @extschema@ resolves |
|--------|---------|--------------------------|
| pg_tle (managed DB) | `make tle` → `psql -f .pgtle-pgtoon.sql` → `CREATE EXTENSION pgtoon` | pg_tle substitutes at install |
| Filesystem extension | Copy to `pg_config --sharedir`/extension → `CREATE EXTENSION pgtoon [SCHEMA x]` | PG substitutes at install |
| Standalone (no extension) | `make local SCHEMA=toon` → `psql -f pgtoon-local.sql` | sed replaces with literal schema |

**You cannot `\i pgtoon--0.1.sql` directly** — the `@extschema@` markers will
cause a parse error. Always use one of the three paths above.

## Testing

### Running tests

```sh
# Against a standalone install:
make local
psql -f pgtoon-local.sql
psql -c "SET search_path = toon, pg_catalog, pg_temp" -f test_pgtoon.sql

# Against a CREATE EXTENSION install (set search_path to the extension schema):
psql -c "CREATE EXTENSION pgtoon"
psql -f test_pgtoon.sql  # functions are in public by default
```

### Test framework

Tests use a temp table + `assert_toon(name, actual, expected)` helper.
Output is a summary row: `passed | failed | total`. Any failures also print
the test name with expected vs actual values via `RAISE NOTICE`.

### Test requirements

- PostgreSQL 12+ (tested on 16 and 18)
- The extension must be installed before running tests
- Tests are self-contained (CREATE/DROP their own temp tables)

## Conventions

### Commits

Follow Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`.
Imperative mood, max 50-char subject. Body explains what/why.

### Code style

- SQL keywords lowercase in function bodies
- 4-space indent inside function bodies
- `LANGUAGE sql` preferred over `plpgsql` for pure-SQL functions
- `IMMUTABLE` on all functions (they are deterministic for same input)
- Every function must have `SET search_path = pg_catalog, pg_temp`
- Internal calls must use `@extschema@.function_name()`

### Adding a new function

1. Add to `pgtoon--0.1.sql` with `CREATE FUNCTION` (no `OR REPLACE`)
2. Add `SET search_path = pg_catalog, pg_temp`
3. Qualify any calls to other pgtoon functions with `@extschema@.`
4. Add tests in `test_pgtoon.sql`
5. Verify all three install paths work (`make tle`, `make local`, filesystem)
6. Run the regression suite: expect 0 failures

### Before committing

- Run `make local && psql -f pgtoon-local.sql && psql -f test_pgtoon.sql` (all tests pass)
- Ideally test `make tle` + `CREATE EXTENSION` on a real pg_tle install

## TOON Spec Quick Reference (for encoders)

Key rules from the spec that affect implementation decisions:

- **§2**: Numbers in canonical decimal for [1e-6, 1e21); -0→0; NaN/±Infinity→null
- **§7.1**: Escapes in quoted strings: `\\`, `\"`, `\n`, `\r`, `\t`, `\uXXXX`
- **§7.2**: Quote strings if: empty, leading/trailing whitespace, true/false/null,
  numeric-like, contains `:"\\{}[]`, contains active delimiter, starts with `-`
- **§7.3**: Keys unquoted only if `^[A-Za-z_][A-Za-z0-9_.]*$`
- **§8**: Objects: `key: value` lines, indented for nesting
- **§9.1**: Inline arrays: `[N]: v1,v2,...`; empty: `[]`
- **§9.3**: Tabular arrays: `[N]{f1,f2}:` + indented rows
- **§11**: Delimiters: comma (default, no symbol), pipe (`|`), tab
- **§12**: 2-space indent, LF line endings, no trailing whitespace/newline
- **§13.1**: Encoder conformance checklist (all items implemented)

## Known Limitations

- **Text values `NaN`/`Infinity`/`-Infinity` in records and arrays**: encoded
  as `null` by `row_to_toon`, `toon_agg`, and the array path of `to_toon`
  (data loss). On those paths the encoder sees only `row_to_json`/JSON output, and PostgreSQL emits a float NaN and the *string*
  `"NaN"` identically (`{"f1":"NaN"}`), so the two are indistinguishable; the
  ambiguity is resolved toward §3's float rule (NaN → `null`). The scalar
  `to_toon('NaN'::text)` path has `pg_typeof` available and correctly returns
  the string. Workaround: cast such columns explicitly, e.g. `'x' || col`, or
  pre-quote them.
- **Nested objects/arrays in record fields**: rendered as quoted text representation,
  not as indented TOON nesting. PL/pgSQL lacks the type introspection needed.
- **Multi-dimensional arrays**: flattened to quoted string, not §9.2 expanded list.
- **`\uXXXX` for U+0000-U+001F** (other than \n\r\t): not yet implemented.
  PG text fields rarely contain these.
- **Number canonical form**: delegated to PostgreSQL's numeric output. Generally
  conforms but edge cases with very small/large floats may differ from spec preference.

## Roadmap (unimplemented, prioritized)

1. `toon_to_json(text)` — TOON decoder (parse TOON → json value)
2. `array_to_toon(anyarray)` — multi-dimensional array support (§9.2)
3. `toon_each` - parse a TOON object & return key/value rows (analag of JSON_each)
4. `toon_populate_record(anyrecord,text) - fill a record type from TOON row data
5. Nested object encoding in `row_to_toon` for composite-typed fields
6. `\uXXXX` control character escaping
7. Spec compliance test vectors (from github.com/toon-format/spec/tree/main/tests)
8. Performance benchmarks - compare toon_agg vs json_agg
9. Version upgrade path (`pgtoon--0.1--0.2.sql`)
