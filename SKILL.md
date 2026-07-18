# SKILL.md — Driving the `boe` CLI

A reference for any agent (or human) working in this repo on how to operate the
Georgia board-of-elections database via the `boe` CLI.

## What this is

`boe` is a SQLite-backed store (in `generator/`, package `boe`) that tracks
Georgia's 159 county boards of elections, the people on them, how each board is
organized, when/where it meets, and how members are chosen. It has full-text
search and a networkx relations graph, both persisted to the database.

**The database is local and gitignored.** It lives at the repo root
(`database.db`) so every contributor/agent gets its own working copy. Never
commit it. Override the path with `BOE_DB_PATH` (use a temp path for
experiments/tests so you don't clobber a real one).

All commands run from `generator/`:

```bash
cd generator
uv run boe --help
```

## First-run setup

```bash
cd generator
uv sync                              # install deps (pydantic, networkx, typer)
uv run boe init                      # create the SQLite schema (idempotent)
uv run boe seed                      # load county boards from content/county-boards/*.md
uv run boe graph build               # build + persist the relations graph
```

`seed` is idempotent — it skips counties already present (matched by slug) and
adds placeholder members only for Bibb so the graph has people in it. Replace
placeholders with verified data via `boe members update`.

## Data model (pydantic, in `generator/boe/models.py`)

- **County** — `name`, `slug` (unique), `fips`, `seat`, `population`.
- **Board** — 1:1 with a county. `organization` (how it's structured),
  `meeting_schedule`, `meeting_location`, `selection_method`
  (`appointed` | `elected` | `mixed`), `selection_description` (how/by whom
  members are chosen), `authority` (the local act/charter that creates it),
  `term_length`, `notes`.
- **Member** — a person on a board: `name`, `role`, `party`, `is_elected`,
  `appointed_by`, `appointment_method`, `appointment_authority`, `term_start`,
  `term_end`, `notes`.

Relations: one county has one board; a board has many members. Deleting a
county cascades to its board and that board's members (and removes their search
rows).

## CRUD

```bash
# Counties
uv run boe counties add   --name Bibb --slug bibb [--fips 13021 --seat Macon --population 157000]
uv run boe counties list
uv run boe counties show <id>
uv run boe counties update <id> [--name ... --seat ... --population ...]
uv run boe counties delete <id>          # cascades to board + members

# Boards (note: --county-id, not --county)
uv run boe boards add   --county-id 1 --name "Macon-Bibb County Board of Elections" \
    [--organization "..." --meeting-schedule "Third Thursday monthly, 12:00 PM" \
     --meeting-location "..." --selection-method appointed \
     --selection-description "Two named by each major party, fifth by the mayor." \
     --authority "Consolidated government charter" --term-length "4 years" --notes "..."]
uv run boe boards list | show <id> | update <id> [...] | delete <id>

# Members (note: --board-id, not --board)
uv run boe members add   --board-id 1 --name "Jane Doe" \
    [--role chair --party Democratic --is-elected/--not-elected \
     --appointed-by "Democratic Party" --appointment-method "party nomination" \
     --appointment-authority "Local act" --term-start 2024-01 --term-end 2028-01 --notes "..."]
uv run boe members list [--board-id 1]      # filter to one board, or list all
uv run boe members show <id> | update <id> [...] | delete <id>
```

Update commands take only the flags you want to change; omitted flags are
left untouched (partial update, not overwrite).

## Full-text search

Every write keeps the FTS5 index in sync automatically — you do **not** need
to reindex after CRUD. Search is case-insensitive, stems words (`appoints` →
`appoint`, `democrats` → `Democratic`), and handles accents. Results are
ranked by `bm25` with highlighted snippets.

```bash
uv run boe search "appointed"
uv run boe search "democratic"          # stems → matches "Democratic"
uv run boe search "government center"   # multi-term
uv run boe search "zzznotreal"           # → "No matches."
uv run boe search "macon" -n 5           # -n / --limit caps results
```

If the index ever drifts (e.g. you edited the DB by hand), rebuild it:

```bash
uv run boe reindex
```

## Relations graph (networkx)

The graph models the hierarchy:

```
state:GA ──contains──▶ county:{slug} ──has_board──▶ board:{id} ──has_member──▶ person:{id}
                                          ◀──serves_on──
```

Node ids: `state:GA`, `county:{slug}` (e.g. `county:bibb`), `board:{id}`
(e.g. `board:1`), `person:{id}` (e.g. `person:3`).

```bash
uv run boe graph build                    # rebuild from tables + persist (run after data changes)
uv run boe graph show                     # node/edge counts + sample nodes
uv run boe graph neighbors board:1        # everything adjacent to a board
uv run boe graph neighbors county:bibb --relation has_board   # filter by edge type
uv run boe graph path state:GA person:1   # shortest path: state → county → board → person
```

**The graph is a snapshot.** `build_graph` reconstructs it from the relational
tables (the source of truth) and `persist_graph` writes it to `graph_nodes` /
`graph_edges`. It does **not** auto-update on CRUD — re-run `boe graph build`
after you change data if you want the persisted graph to reflect it.

## Idioms / gotchas

- **Always `cd generator` first.** The CLI and the `boe` package live there.
- **The DB is local.** Don't commit `database.db`. For throwaway work, set
  `BOE_DB_PATH=/tmp/something.db` so you don't mutate the real one.
- **`init` is idempotent** (uses `CREATE TABLE IF NOT EXISTS`); it will not
  add columns to an existing outdated table. If you change the schema, drop
  the DB (or use a fresh `BOE_DB_PATH`) and re-run `init` + `seed`.
- **`seed` skips existing counties** by slug, so it's safe to re-run.
- **`--county-id` / `--board-id`**, not `--county` / `--board`.
- **Search sync is automatic; graph sync is manual** (`boe graph build`).
- **Cascade**: `counties delete` removes the county's board and members and
  their search rows. `boards delete` removes the board's members + search rows.

## Where things live

```
generator/boe/
  models.py   pydantic models (County, Board, Member + Update payloads)
  db.py       SQLite connection + schema (FTS5, graph tables)
  repo.py     CRUD; keeps search_fts in sync on every write
  search.py   FTS5 search + reindex_all
  graph.py    build / persist / load / query the networkx graph
  cli.py      typer CLI (entry point: `boe`)
generator/tests/test_boe.py   CRUD + FTS + graph tests (temp DB via BOE_DB_PATH)
generator/boe/README.md        longer-form reference
```

## Verifying your work

```bash
cd generator
uv run ruff check .                       # lint must pass
uv run python -m pytest                   # 22 tests (16 boe + 6 existing)
uv run build.py                           # the report-data build still works
```

Tests use a temp DB via `BOE_DB_PATH`, so running them never touches the real
`database.db`.