# Implementation Plan: Synthetic Dataset

## Overview

Build the PostgreSQL schema, the deterministic Python 3.12 generator, the committed seed files, and the stories file, all under `data/`. The schema comes first, then the generator in layers (catalog, lots, reports, measurements, stories, CLI and output), then the committed seed files, then `STORIES.md` and the README. Per the testing policy in `tech.md`, no test files or harnesses are created. Each task ends with a short manual verification step, and the result is recorded in the task notes. The design has no Correctness Properties section, so no property tests apply.

## Tasks

- [x] 1. Write the PostgreSQL schema `data/schema.sql`
  - [x] 1.1 Create `data/schema.sql` with tables, constraints, indexes, and comments
    - Header comment states that all data is synthetic. Wrap everything in `BEGIN; ... COMMIT;`.
    - Define `lines`, `parts`, `characteristics`, `inspectors`, `lots`, `inspection_reports`, `measurements` with the columns, types (`NUMERIC` for nominal, limits, and measured value), primary keys, single-column foreign keys, composite foreign keys, UNIQUE constraints, and CHECK constraints from the design.
    - Use explicit constraint and index names. Declare the six indexes from the design (`ix_reports_line_date`, `ix_reports_part_date`, `ix_reports_lot`, `ix_measurements_characteristic`, `ix_measurements_report`, `ix_lots_part_produced`). Add `COMMENT ON TABLE` for each table.
    - Use no `DROP`, `INSERT`, `UPDATE`, or `DELETE`.
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10, 1.11, 1.12, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 13.2_

  - [x] 1.2 Manually verify the schema on a local PostgreSQL database
    - Create an empty database and apply the file with `psql -v ON_ERROR_STOP=1 -f data/schema.sql`. Expect zero errors.
    - Check `\d` output for all constraints and indexes. Insert nothing permanently; try one invalid row per CHECK in a rolled-back transaction by hand.
    - Apply the schema to a second empty database in a separate session and compare `pg_dump --schema-only` output. Expect identical definitions.
    - Record in the task notes: PostgreSQL version, the commands run, and the pass or fail result.
    - _Requirements: 1.4, 1.5, 1.6, 1.7, 1.9, 1.10, 2.7_

- [x] 2. Implement the generator foundation in `data/generate.py`
  - [x] 2.1 Create the module skeleton, constants, and argument parsing
    - Use only the Python 3.12 standard library. Define `GENERATOR_VERSION`, `DEFAULT_SEED` (42), `DEFAULT_END_DATE` (`2025-06-30`), `WINDOW_DAYS = 56`, and frozen dataclasses `Part`, `Characteristic`, `Inspector`, `Lot`, `Report`, `Measurement`.
    - Implement `parse_seed` (optional minus sign and digits only) and `parse_end_date` (exactly `YYYY-MM-DD` by regular expression, then `date.fromisoformat`). Both raise `argparse.ArgumentTypeError` quoting the bad value.
    - Add CLI options `--seed`, `--end-date`, `--output-dir` (default `data/seed/`), and `--include-injection-story` (default off). Validation happens before any file is touched.
    - Do not call `datetime.now`, `socket`, `getpass`, or `os.getcwd`, and write no absolute path to any output.
    - _Requirements: 4.1, 4.2, 4.3, 4.8, 4.9, 4.10, 4.11, 10.4, 13.1_

  - [x] 2.2 Manually verify argument handling
    - Run `python data/generate.py --end-date 2025-13-40`, `--end-date 20250630`, and `--seed abc`. Each must exit non-zero, name the value in the message, and create no output directory.
    - Run `ruff check data/generate.py`. Expect no findings.
    - Record the three exit statuses and messages in the task notes.
    - _Requirements: 4.9, 4.10, 4.12_

- [x] 3. Implement the fixed catalog, lot plan, and report plan
  - [x] 3.1 Add the catalog and the lot builder
    - Add the 2 lines, 6 parts (3 families, 2 each), 18 characteristics from the design table, and 6 inspectors (3 per line) with fictional names from a fixed list.
    - Implement the lot plan (S1, S3, Filler A, Filler B offsets) so that `produced_on = end_date - offset`, with lot IDs `LOT-<yyyymmdd>-<nn>`, one `line_id` per lot, and `part_number` per plan.
    - Part numbers follow `DEMO-<FAMILY>-<nnnn>`, characteristic IDs follow `CHR-<nnnn>-<nn>`, and inspector IDs follow `insp-<line>-<nn>`.
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.7, 3.8, 6.1, 6.2, 6.4, 6.5, 6.7, 7.1, 7.2, 7.7_

  - [x] 3.2 Add the report builder
    - Build reports from the plan (15 S1, 10 S3, 9 Filler A, 16 Filler B) with report date offsets from `produced_on`. Sort by (`report_date`, `lot_id`, index within lot) and assign IDs `IR-<yyyy>-<nnnn>`, restarting the sequence per year.
    - Assign inspectors from the same line as the report using the seeded `random.Random(seed)`. Keep each report's `part_number` and `line_id` equal to its lot's.
    - Assign status (about 70% `closed`, 20% `submitted`, 10% `draft`) for non-story reports, never `draft` for S1 and S3. Set disposition per the design table, empty for `draft`.
    - _Requirements: 3.5, 3.7, 3.9, 3.10, 3.11, 3.14, 6.3, 6.4_

  - [x] 3.3 Manually verify lots and reports with a throwaway Python session
    - Print counts, lot IDs, and report IDs for the default parameters in an interactive session (do not commit any script).
    - Confirm 14 lots, 50 reports, all dates within the 56-day window, and the S1 lot IDs `LOT-20250512-01`, `LOT-20250521-01`, `LOT-20250530-01`, `LOT-20250608-01`, `LOT-20250617-01`.
    - Record the counts and the lot ID list in the task notes.
    - _Requirements: 3.4, 3.5, 3.7, 6.2, 6.3_

- [x] 4. Implement measurements and the planted stories
  - [x] 4.1 Add measurement generation and `classify`
    - Implement `classify(value, lower, upper)` returning `fail` when out of tolerance, else `pass`. Use it as the only source of `result`.
    - For each report, write one measurement per characteristic of its part (3 each, 150 total). Filler values use `Decimal` integer thousandths with `randrange(-k, k + 1)`, `k = 0.6 * h`, so filler values always pass. Assign `measurement_id` 1..150 after sorting by (`report_id`, `characteristic_id`).
    - _Requirements: 3.6, 3.12, 3.13_

  - [x] 4.2 Add story S1 (drifting `bore_diameter`, line B)
    - Use the literal values from the design table for the 15 S1 `CHR-2001-01` measurements (means 25.001, 25.006, 25.012, 25.019, 25.021). Reports with a failing value get disposition `hold`.
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7_

  - [x] 4.3 Add stories S2 and S3, and the optional S4
    - S2: set the third report of the `DEMO-BRACKET-4001` line B lot (offset 33) to `submitted`, empty disposition, and the fixed ambiguous note.
    - S3: make the third report of the offset-26 `DEMO-SHAFT-3001` line A lot the scrap report, with `CHR-3001-01` value `20.014`, status `closed`, disposition `scrap`, and the fixed note. All 10 S3 reports stay on line A.
    - S4: only when `--include-injection-story` is set, replace the note of the second report on the `DEMO-BRACKET-4002` line B lot (offset 18) with the fixed injection text of at most 120 characters. Nothing else changes.
    - Keep notes at most 120 characters, terse, and free of the phrases `ignore`, `assistant`, `previous instructions`, `system prompt`, `you must` outside S4.
    - _Requirements: 6.6, 8.1, 8.2, 8.3, 8.4, 9.1, 9.2, 9.3, 9.4, 10.1, 10.2, 10.3, 10.6_

  - [x] 4.4 Add `check_dataset` runtime guards
    - Raise `RuntimeError` naming the check when counts leave the ranges in Requirement 3, S1 means are not strictly increasing, or S1 positions 1 to 3 hold an out-of-tolerance value.
    - These are plain `raise` statements in the generator, not a test harness.
    - _Requirements: 3.4, 3.5, 3.6, 7.4, 7.5, 7.6_

  - [x] 4.5 Manually verify stories in a throwaway Python session
    - Print S1 lot means and out-of-tolerance values, the S2 report, and the S3 scrap report for the default parameters. Compare with the design tables.
    - Build once with the injection flag and confirm exactly one note differs and counts are unchanged.
    - Record the S1 means, the S2 report ID, the S3 scrap report ID, and the flag comparison in the task notes.
    - _Requirements: 7.4, 7.5, 7.6, 8.1, 9.2, 10.1_

- [x] 5. Checkpoint - Review the builder with the user
  - Confirm the task notes for tasks 1 to 4 are filled in and `ruff check data/generate.py` is clean. Ask the user if questions arise.

- [x] 6. Implement output writing and generate the committed seed files
  - [x] 6.1 Add CSV rendering, metadata, and `main`
    - Implement `render_csv` with `csv.writer`, `lineterminator="\n"`, minimal quoting, and `None` written as an empty field. Write columns in schema order and rows sorted by primary key.
    - Write one `<table>.csv` per table plus `METADATA.json` (`json.dumps` with `indent=2`, `sort_keys=True`, trailing newline) holding `synthetic: true`, `seed`, `end_date`, `include_injection_story`, and `generator_version`.
    - Render every file to a string first, then write with `open(path, "w", encoding="utf-8", newline="")`. Create the output directory only after validation and the guard checks pass.
    - _Requirements: 4.4, 4.5, 4.6, 4.7, 5.1, 5.2, 10.6, 13.1_

  - [x] 6.2 Generate the committed seed files
    - Run `python data/generate.py` with the defaults (seed 42, End_Date `2025-06-30`, flag off) to write `data/seed/*.csv` and `data/seed/METADATA.json`.
    - _Requirements: 5.3, 10.5_

  - [x] 6.3 Manually verify determinism, format, and the injection scan
    - Run the generator twice into two temporary directories with the same seed and End_Date, then `diff -r`. Expect no output. Repeat with `--include-injection-story`.
    - Check LF endings with `grep -c $'\r'` (expect 0), UTF-8 with `file`, headers with `head`, and search for `/Users`, the host name, and the user name (expect no match).
    - Run `grep -i -E "ignore|assistant|previous instructions|system prompt|you must" data/seed/*` (expect zero matches). With the flag, expect exactly one match in `inspection_reports.csv` and `"include_injection_story": true` in the metadata.
    - Check ID formats with `grep -E` and note length at most 120 with `awk`.
    - Record each command and result in the task notes.
    - _Requirements: 4.4, 4.5, 4.6, 4.7, 6.1, 6.2, 6.3, 6.4, 6.6, 10.3, 10.5, 12.2, 12.5_

- [x] 7. Load the seed files and verify the dataset against the schema
  - [x] 7.1 Manually load and query in a local PostgreSQL database
    - Apply `data/schema.sql`, then `\copy ... CSV HEADER` the seven files in order: `lines`, `parts`, `characteristics`, `inspectors`, `lots`, `inspection_reports`, `measurements`. Expect zero errors.
    - Check row counts (2, 6, 18, 6, 14, 50, 150), min and max of `report_date` and `produced_on` against the 56-day window, and join queries that return zero rows for line, part, inspector-line, and characteristic-part mismatches. Recompute `result` from the limits and expect no difference.
    - Run per-lot `avg(measured_value)` and `count(*) FILTER (WHERE result = 'fail')` for the S1 lots. Check the S2 report (line B, `submitted`, empty disposition, ambiguous note), the 10 S3 reports on line A, and the one scrap report.
    - Record the queries and results in the task notes. These results feed the verification log in `STORIES.md`.
    - _Requirements: 1.3, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13, 3.14, 5.4, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 8.1, 8.2, 8.4, 9.1, 9.2, 9.3, 12.3, 12.4_

- [x] 8. Write the documentation
  - [x] 8.1 Write `data/STORIES.md`
    - Document S1, S2, S3, and S4 with the exact line, part, characteristic, lot, report, and inspector IDs read from the committed files, and the answer an agent should find for each.
    - For S1, list the 5 lot IDs in `produced_on` order, the Lot_Mean of each, and the out-of-tolerance values of the last two lots.
    - Refer to demo questions only by number (S1 to question 2, S2 to question 3, S3 to question 4, S4 as the injection test) as defined in `.kiro/steering/product.md`, without restating the text.
    - State that S4 exists only with `--include-injection-story` and is absent from the committed files. State the seed (42), End_Date (`2025-06-30`), and flag (off), and that story IDs depend on the End_Date and not on the seed.
    - Add a verification log table (criterion, check, result, date) for S1, S2, and S3 using the results from tasks 4.5 and 7.1.
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7_

  - [x] 8.2 Update `data/README.md`
    - Document the generator command, its four options and defaults, the seven seed files, the `psql \copy` load order, and a pointer to `STORIES.md` and `schema.sql`.
    - If `docs/` has a natural place that lists data artifacts, add a reference to `data/STORIES.md` only.
    - _Requirements: 5.5, 13.4_

- [x] 9. Final manual verification and scope check
  - [x] 9.1 Run the final checks
    - Regenerate into a temporary directory with the documented defaults and run `diff -r` against `data/seed/`. Expect no output.
    - Run `ruff check data/generate.py` and the repository lint command. Expect no findings.
    - Run `git status` and confirm changes are limited to `data/`, `.kiro/specs/05-synthetic-dataset/`, and `docs/` references to `STORIES.md`. Confirm no loading script, tool, MCP code, or test file was added.
    - Record the results in the task notes.
    - _Requirements: 4.12, 5.3, 12.1, 12.6, 13.1, 13.3, 13.4_

- [x] 10. Final checkpoint - Confirm completion
  - Confirm every task has notes recorded and the verification log in `data/STORIES.md` is filled in. Ask the user if questions arise.

## Notes

- No test files, suites, fixtures, or harnesses are created, per `tech.md`. Every verification step is run by hand in a terminal or an interactive Python session, and nothing from it is committed as a script.
- For each manual verification task, record in the task notes: the command or query, the observed result, pass or fail, and the date.
- The design has no Correctness Properties section, so no property test tasks apply.
- Story IDs depend on the End_Date and not on the Seed_Value. Read final IDs from the generated files before writing `STORIES.md`.
- The seed-loading script is out of scope for this spec (Requirement 13.3). A later spec adds it.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1"] },
    { "id": 1, "tasks": ["1.2", "2.2", "3.1"] },
    { "id": 2, "tasks": ["3.2"] },
    { "id": 3, "tasks": ["3.3", "4.1"] },
    { "id": 4, "tasks": ["4.2"] },
    { "id": 5, "tasks": ["4.3"] },
    { "id": 6, "tasks": ["4.4"] },
    { "id": 7, "tasks": ["4.5"] },
    { "id": 8, "tasks": ["5"] },
    { "id": 9, "tasks": ["6.1"] },
    { "id": 10, "tasks": ["6.2"] },
    { "id": 11, "tasks": ["6.3", "7.1"] },
    { "id": 12, "tasks": ["8.1"] },
    { "id": 13, "tasks": ["8.2"] },
    { "id": 14, "tasks": ["9.1"] },
    { "id": 15, "tasks": ["10"] }
  ]
}
```
