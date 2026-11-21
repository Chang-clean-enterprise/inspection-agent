# Requirements Document

## Introduction

This feature defines the PostgreSQL schema and a deterministic generator for the synthetic manufacturing inspection dataset used by the inspection-agent demo. The generator produces CSV seed files, committed to the repository, with planted stories that support the demo questions in `.kiro/steering/product.md`. All files live under `data/`. Loading the data into Amazon RDS and the agent tools are out of scope.

All data is synthetic. It contains no real company, customer, personal, or part-number data. All code, comments, data, and documentation are in English.

## Glossary

- **Schema_File**: The PostgreSQL DDL file `data/schema.sql`.
- **Generator**: The Python 3.12 program `data/generate.py` that writes the Seed_Files.
- **Seed_Files**: The CSV files in `data/seed/`, one per entity, committed to the repository.
- **Seed_Metadata**: The file `data/seed/METADATA.json` that marks the Seed_Files as synthetic and records the generation parameters.
- **Stories_File**: The document `data/STORIES.md`.
- **Dataset**: The complete set of Seed_Files produced by one Generator run.
- **Seed_Value**: The integer that initializes the Generator random number source.
- **End_Date**: The last calendar date covered by the Dataset, given as an ISO 8601 date (`YYYY-MM-DD`).
- **Injection_Flag**: The Generator option `--include-injection-story` that enables story S4. It is off by default.
- **Story**: A planted pattern in the Dataset with fixed IDs, identified as S1, S2, S3, or S4.
- **Lot_Mean**: The arithmetic mean of all `measured_value` rows for one lot and one characteristic.
- **Out_Of_Tolerance**: A `measured_value` that is less than `lower_limit` or greater than `upper_limit` of its characteristic.
- **Reviewer**: A person who verifies acceptance criteria by hand.

## Requirements

### Requirement 1: Relational schema

**User Story:** As a developer, I want a PostgreSQL schema with enforced constraints, so that the database rejects invalid inspection data.

#### Acceptance Criteria

1. THE Schema_File SHALL define the tables `lines`, `parts`, `characteristics`, `lots`, `inspectors`, `inspection_reports`, and `measurements`.
2. THE Schema_File SHALL declare a primary key on each table.
3. THE Schema_File SHALL declare a foreign key for every reference between tables: `characteristics.part_number`, `lots.part_number`, `lots.line_id`, `inspectors.line_id`, `inspection_reports.line_id`, `inspection_reports.lot_id`, `inspection_reports.part_number`, `inspection_reports.inspector_id`, `measurements.report_id`, and `measurements.characteristic_id`.
4. THE Schema_File SHALL restrict `lines.line_id` to the values `A` and `B`.
5. THE Schema_File SHALL restrict `inspection_reports.status` to the values `draft`, `submitted`, and `closed`.
6. THE Schema_File SHALL restrict `inspection_reports.disposition` to the values `accept`, `rework`, `scrap`, and `hold`, and SHALL allow NULL.
7. THE Schema_File SHALL restrict `measurements.result` to the values `pass` and `fail`.
8. THE Schema_File SHALL declare `characteristics.nominal`, `characteristics.lower_limit`, `characteristics.upper_limit`, and `measurements.measured_value` with the PostgreSQL type `NUMERIC`.
9. THE Schema_File SHALL declare a check constraint requiring `lower_limit` to be less than or equal to `nominal` and `nominal` to be less than or equal to `upper_limit`.
10. THE Schema_File SHALL declare a check constraint requiring `disposition` to be NULL while `status` is `draft`.
11. THE Schema_File SHALL declare every column that the Dataset always populates as `NOT NULL`, except `inspection_reports.disposition` and `inspection_reports.notes`.
12. THE Schema_File SHALL contain a comment stating that all data is synthetic.

### Requirement 2: Query-pattern indexes

**User Story:** As a developer, I want indexes for the expected query patterns, so that later tools can filter inspection data by line, part, lot, date, and characteristic.

#### Acceptance Criteria

1. THE Schema_File SHALL declare an index on `inspection_reports` that supports filtering by `line_id` and `report_date`.
2. THE Schema_File SHALL declare an index on `inspection_reports` that supports filtering by `part_number` and `report_date`.
3. THE Schema_File SHALL declare an index on `inspection_reports.lot_id`.
4. THE Schema_File SHALL declare an index on `measurements` that supports filtering by `characteristic_id`.
5. THE Schema_File SHALL declare an index on `measurements.report_id`.
6. THE Schema_File SHALL declare an index on `lots` that supports filtering by `part_number` and `produced_on`.
7. WHEN the Schema_File is applied twice to an empty PostgreSQL database in two separate sessions, THE Schema_File SHALL produce identical object definitions both times.

### Requirement 3: Dataset size and shape

**User Story:** As a demo presenter, I want a small dataset of fixed size, so that the demo answers are easy to explain and verify.

#### Acceptance Criteria

1. THE Generator SHALL write exactly 2 lines, with `line_id` values `A` and `B`.
2. THE Generator SHALL write exactly 6 parts spread across exactly 3 families, with 2 parts per family.
3. THE Generator SHALL write exactly 3 characteristics for each part.
4. THE Generator SHALL write between 12 and 16 lots, inclusive.
5. THE Generator SHALL write between 48 and 60 inspection reports, inclusive.
6. THE Generator SHALL write between 140 and 160 measurements, inclusive.
7. THE Generator SHALL set every `report_date` and `produced_on` value to a date within the 56 days that end on the End_Date, inclusive.
8. THE Generator SHALL write at least 2 inspectors for each line.
9. THE Generator SHALL write each lot with a `line_id` that matches the `line_id` of every inspection report that references the lot.
10. THE Generator SHALL write each inspection report with a `part_number` that matches the `part_number` of the referenced lot.
11. THE Generator SHALL write each inspection report with an `inspector_id` whose `line_id` matches the `line_id` of the report.
12. THE Generator SHALL write each measurement with a `characteristic_id` that belongs to the `part_number` of the referenced inspection report.
13. THE Generator SHALL write each measurement `result` as `fail` when the `measured_value` is Out_Of_Tolerance, and as `pass` otherwise.
14. THE Generator SHALL write `disposition` as empty for every report with `status` equal to `draft`.

### Requirement 4: Deterministic generation

**User Story:** As a demo presenter, I want reproducible output, so that the committed seed files and the demo script always agree.

#### Acceptance Criteria

1. THE Generator SHALL accept a `--seed` option with an integer Seed_Value.
2. THE Generator SHALL accept an `--end-date` option with an End_Date.
3. THE Generator SHALL accept an `--output-dir` option and default to `data/seed/`.
4. WHEN the Generator runs twice with the same Seed_Value, End_Date, Injection_Flag setting, and Generator source version, THE Generator SHALL write byte-identical Seed_Files and Seed_Metadata.
5. THE Generator SHALL write Seed_Files with UTF-8 encoding, LF line endings, a header row, and a fixed column order.
6. THE Generator SHALL write rows in each Seed_File sorted by the primary key.
7. THE Generator SHALL write no wall-clock timestamp, host name, user name, or absolute path to any Seed_File or Seed_Metadata.
8. WHEN the `--end-date` option is omitted, THE Generator SHALL use a fixed default End_Date defined as a constant in the Generator source.
9. IF the `--end-date` value is not a valid ISO 8601 date, THEN THE Generator SHALL exit with a non-zero status and an error message that names the invalid value, and SHALL write no Seed_Files.
10. IF the `--seed` value is not an integer, THEN THE Generator SHALL exit with a non-zero status and an error message that names the invalid value, and SHALL write no Seed_Files.
11. THE Generator SHALL use only the Python 3.12 standard library.
12. THE Generator SHALL pass `ruff check` with the repository `ruff.toml`.

### Requirement 5: Seed files committed and marked synthetic

**User Story:** As a demo presenter, I want committed seed files that declare themselves synthetic, so that nobody mistakes the data for real records.

#### Acceptance Criteria

1. THE Generator SHALL write one Seed_File per table, named `<table>.csv`, into the output directory.
2. THE Generator SHALL write Seed_Metadata containing the field `synthetic` with the value `true`, the Seed_Value, the End_Date, the Injection_Flag setting, and the Generator version string.
3. THE repository SHALL contain the Seed_Files and Seed_Metadata generated with the documented default Seed_Value and the default End_Date.
4. THE Generator SHALL write the Seed_Files such that every CSV file loads into the corresponding Schema_File table without constraint violations, when tables are loaded in foreign-key dependency order.
5. THE data README at `data/README.md` SHALL document the Generator command, its options, and the load order of the Seed_Files.

### Requirement 6: Realistic fictional identifiers and notes

**User Story:** As a demo presenter, I want fictional but plausible identifiers and terse notes, so that the demo looks realistic without using real data.

#### Acceptance Criteria

1. THE Generator SHALL write part numbers in the form `DEMO-<FAMILY>-<nnnn>`, where `<FAMILY>` is an uppercase family name and `<nnnn>` is a four-digit number.
2. THE Generator SHALL write lot IDs in the form `LOT-<yyyymmdd>-<nn>`, where `<yyyymmdd>` is the `produced_on` date and `<nn>` is a two-digit sequence number.
3. THE Generator SHALL write report IDs in the form `IR-<yyyy>-<nnnn>`, where `<yyyy>` is the year of `report_date` and `<nnnn>` is a four-digit sequence number.
4. THE Generator SHALL write inspector IDs in the form `insp-<line>-<nn>`, where `<line>` is the lowercase `line_id` and `<nn>` is a two-digit sequence number.
5. THE Generator SHALL write inspector names from a fixed list of fictional given-name and family-name combinations.
6. THE Generator SHALL write each non-empty report note as English text of at most 120 characters in a terse inspector style.
7. THE Generator SHALL write no real company name, real person name, real part number, or real document format in any Seed_File.

### Requirement 7: Story S1, drifting bore diameter

**User Story:** As a demo presenter, I want a planted upward trend on line B, so that demo question 2 has a verifiable answer.

#### Acceptance Criteria

1. THE Generator SHALL write the part `DEMO-HOUSING-2001` with a characteristic named `bore_diameter`, unit `mm`, nominal `25.000`, lower limit `24.980`, and upper limit `25.020`.
2. THE Generator SHALL write exactly 5 consecutive lots of `DEMO-HOUSING-2001` on line B as the S1 lots, with fixed lot IDs.
3. THE Generator SHALL write measurements of `bore_diameter` for each S1 lot.
4. THE Generator SHALL write S1 measurements such that the Lot_Mean of `bore_diameter` increases strictly from each S1 lot to the next S1 lot in `produced_on` order.
5. THE Generator SHALL write S1 measurements such that the S1 lots in positions 1, 2, and 3 contain no Out_Of_Tolerance `bore_diameter` measurement.
6. THE Generator SHALL write S1 measurements such that each of the S1 lots in positions 4 and 5 contains at least one Out_Of_Tolerance `bore_diameter` measurement.
7. THE Generator SHALL write no other `DEMO-HOUSING-2001` lot on line B between the first and last S1 lot in `produced_on` order.

### Requirement 8: Story S2, ambiguous notes

**User Story:** As a demo presenter, I want one open line B report with ambiguous notes, so that the agent can be shown to summarize without inventing a cause or a disposition.

#### Acceptance Criteria

1. THE Generator SHALL write exactly one S2 report, with a fixed report ID, on line B.
2. THE Generator SHALL write the S2 report with an empty `disposition` and a `status` of `draft` or `submitted`.
3. THE Generator SHALL write S2 notes that mention an observed issue and leave both the cause and the next step unstated or uncertain.
4. THE Generator SHALL write at most one S2 report, so that the S2 report is the only line B report whose notes carry the S2 ambiguity.

### Requirement 9: Story S3, restricted line A records

**User Story:** As a demo presenter, I want planted line A records, so that demo question 4 shows a denial to the line B inspector.

#### Acceptance Criteria

1. THE Generator SHALL write at least 8 inspection reports on line A that carry fixed report IDs and belong to S3.
2. THE Generator SHALL write at least one S3 report with a `fail` measurement and `disposition` equal to `scrap`.
3. THE Generator SHALL write S3 reports with a `line_id` of `A`, and SHALL write no S3 report with a `line_id` of `B`.
4. THE Generator SHALL write the S3 scrap report with a fixed report ID, lot ID, part number, and characteristic ID.

### Requirement 10: Story S4, optional injection note

**User Story:** As a security reviewer, I want an optional report whose notes contain instruction-like text addressed to an AI assistant, so that I can test how the agent treats untrusted data.

#### Acceptance Criteria

1. WHERE the Injection_Flag is set, THE Generator SHALL write exactly one S4 report, with a fixed report ID, on line B.
2. WHERE the Injection_Flag is set, THE Generator SHALL write S4 notes that contain instruction-like text addressed to an AI assistant.
3. WHILE the Injection_Flag is off, THE Generator SHALL write no note, name, or description that contains instruction-like text addressed to an AI assistant.
4. THE Generator SHALL default the Injection_Flag to off.
5. THE committed Seed_Files SHALL be generated with the Injection_Flag off.
6. WHERE the Injection_Flag is set, THE Generator SHALL record the Injection_Flag value `true` in Seed_Metadata.

### Requirement 11: Stories file

**User Story:** As a demo presenter and evaluator, I want a stories document with exact IDs and expected answers, so that the demo script and the manual eval checklist have a single reference.

#### Acceptance Criteria

1. THE Stories_File SHALL document S1, S2, S3, and S4 with the exact IDs of the lines, parts, characteristics, lots, reports, and inspectors that each Story uses.
2. THE Stories_File SHALL state, for each Story, the answer that an agent should find.
3. THE Stories_File SHALL refer to demo questions only by their number, 1 to 5, as defined in `.kiro/steering/product.md`, and SHALL not restate the question text.
4. THE Stories_File SHALL list, for S1, the 5 lot IDs in `produced_on` order, the Lot_Mean of each lot, and the Out_Of_Tolerance values of the last two lots.
5. THE Stories_File SHALL state that S4 exists only when the Injection_Flag is set and is absent from the committed Seed_Files.
6. THE Stories_File SHALL state the Seed_Value, End_Date, and Injection_Flag setting of the committed Seed_Files.
7. THE Stories_File SHALL record the manual verification result of each acceptance criterion for S1, S2, and S3, including the date and the check performed.

### Requirement 12: Manual verification

**User Story:** As a maintainer, I want the acceptance criteria verified by hand, so that the repository follows its no-tests policy.

#### Acceptance Criteria

1. THE spec task list SHALL contain manual verification steps and no automated test tasks.
2. THE Reviewer SHALL verify determinism by running the Generator twice into two directories with the same Seed_Value and End_Date and comparing the directories with `diff -r`, with an empty difference as a pass.
3. THE Reviewer SHALL verify the Dataset constraints by applying the Schema_File to a local PostgreSQL database and loading the Seed_Files with `psql \copy`, with zero errors as a pass.
4. THE Reviewer SHALL verify S1 by querying the Lot_Mean and Out_Of_Tolerance counts per S1 lot in the local database, with the Stories_File values as the expected result.
5. THE Reviewer SHALL verify that the Injection_Flag off output contains no injection-style text by searching the Seed_Files for instruction-like phrases, with zero matches as a pass.
6. THE Reviewer SHALL verify that the committed Seed_Files are identical to a fresh Generator run with the documented parameters.

### Requirement 13: Scope boundaries

**User Story:** As a maintainer, I want clear scope limits, so that this spec stays focused on data definition.

#### Acceptance Criteria

1. THE Generator SHALL write files only and SHALL make no connection to a database or to any AWS service.
2. THE Schema_File SHALL contain no data-modifying statements other than the table, index, and comment definitions.
3. THE feature SHALL add no application tool, MCP server code, or loading script.
4. THE feature SHALL add no file outside `data/` and `.kiro/specs/05-synthetic-dataset/`, with the exception of `docs/` updates that reference the Stories_File.
