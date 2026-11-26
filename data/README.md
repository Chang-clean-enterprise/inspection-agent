# data

Database schema, data generator, generated seed files, and the stories file. All data is synthetic. It contains no real company, customer, or personal data.

## Contents

- `schema.sql`: PostgreSQL schema (seven tables, constraints, indexes). See [schema.sql](schema.sql).
- `generate.py`: deterministic data generator. Python 3.12, standard library only.
- `seed/`: generated seed files (seven CSV files and `METADATA.json`).
- `STORIES.md`: IDs and expected answers behind the demo questions. See [STORIES.md](STORIES.md).

## Generator

Run from the repository root:

```bash
python data/generate.py
```

Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `--seed` | `42` | Integer seed for filler values. |
| `--end-date` | `2026-11-20` | Last day of the 56-day window, `YYYY-MM-DD`. Story IDs depend on this date, not on the seed. |
| `--output-dir` | `data/seed/` | Directory the seed files are written to. |
| `--include-injection-story` | off | Adds story S4, one report note with injection-style text. The committed files do not include it. |

With the same options the output is byte-identical. Invalid option values exit non-zero before any file is written.

## Seed files

The committed files in `data/seed/` come from the defaults above.

- `lines.csv`
- `parts.csv`
- `characteristics.csv`
- `inspectors.csv`
- `lots.csv`
- `inspection_reports.csv`
- `measurements.csv`
- `METADATA.json`: records `synthetic`, `seed`, `end_date`, `include_injection_story`, and `generator_version`.

## Loading into PostgreSQL

Apply the schema, then load the CSV files in this order, so that foreign keys resolve. Run from the repository root with `psql`:

```
\i data/schema.sql
\copy lines FROM 'data/seed/lines.csv' CSV HEADER
\copy parts FROM 'data/seed/parts.csv' CSV HEADER
\copy characteristics FROM 'data/seed/characteristics.csv' CSV HEADER
\copy inspectors FROM 'data/seed/inspectors.csv' CSV HEADER
\copy lots FROM 'data/seed/lots.csv' CSV HEADER
\copy inspection_reports FROM 'data/seed/inspection_reports.csv' CSV HEADER
\copy measurements FROM 'data/seed/measurements.csv' CSV HEADER
```

To load the schema and seed files into the RDS database from your laptop, run `scripts/seed.sh` (or `make seed`). See [docs/database.md](../docs/database.md).

## See also

- [STORIES.md](STORIES.md): planted stories, IDs, and expected answers
- [schema.sql](schema.sql): table and constraint definitions
- [.kiro/steering/structure.md](../.kiro/steering/structure.md): repository layout and naming rules
