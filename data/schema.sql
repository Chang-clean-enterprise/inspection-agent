-- inspection-agent schema (PostgreSQL)
--
-- All data in this schema is synthetic. It contains no real company,
-- customer, personal, or part-number data.
--
-- Safe to apply repeatedly. Every table and index uses IF NOT EXISTS, so
-- existing objects are left unchanged. The file runs in a single transaction:
--   psql -v ON_ERROR_STOP=1 -f data/schema.sql

BEGIN;

CREATE TABLE IF NOT EXISTS lines (
    line_id TEXT NOT NULL,
    name    TEXT NOT NULL,
    CONSTRAINT pk_lines PRIMARY KEY (line_id),
    CONSTRAINT ck_lines_line_id CHECK (line_id IN ('A', 'B'))
);

CREATE TABLE IF NOT EXISTS parts (
    part_number TEXT NOT NULL,
    family      TEXT NOT NULL,
    description TEXT NOT NULL,
    CONSTRAINT pk_parts PRIMARY KEY (part_number)
);

CREATE TABLE IF NOT EXISTS characteristics (
    characteristic_id TEXT    NOT NULL,
    part_number       TEXT    NOT NULL,
    name              TEXT    NOT NULL,
    unit              TEXT    NOT NULL,
    nominal           NUMERIC NOT NULL,
    lower_limit       NUMERIC NOT NULL,
    upper_limit       NUMERIC NOT NULL,
    CONSTRAINT pk_characteristics PRIMARY KEY (characteristic_id),
    CONSTRAINT fk_characteristics_part
        FOREIGN KEY (part_number) REFERENCES parts (part_number),
    CONSTRAINT uq_characteristics_part_name UNIQUE (part_number, name),
    CONSTRAINT ck_characteristics_limits
        CHECK (lower_limit <= nominal AND nominal <= upper_limit)
);

CREATE TABLE IF NOT EXISTS inspectors (
    inspector_id TEXT NOT NULL,
    line_id      TEXT NOT NULL,
    full_name    TEXT NOT NULL,
    CONSTRAINT pk_inspectors PRIMARY KEY (inspector_id),
    CONSTRAINT fk_inspectors_line
        FOREIGN KEY (line_id) REFERENCES lines (line_id),
    CONSTRAINT uq_inspectors_id_line UNIQUE (inspector_id, line_id)
);

CREATE TABLE IF NOT EXISTS lots (
    lot_id      TEXT    NOT NULL,
    part_number TEXT    NOT NULL,
    line_id     TEXT    NOT NULL,
    produced_on DATE    NOT NULL,
    quantity    INTEGER NOT NULL,
    CONSTRAINT pk_lots PRIMARY KEY (lot_id),
    CONSTRAINT fk_lots_part
        FOREIGN KEY (part_number) REFERENCES parts (part_number),
    CONSTRAINT fk_lots_line
        FOREIGN KEY (line_id) REFERENCES lines (line_id),
    CONSTRAINT uq_lots_id_part_line UNIQUE (lot_id, part_number, line_id),
    CONSTRAINT ck_lots_quantity CHECK (quantity > 0)
);

CREATE TABLE IF NOT EXISTS inspection_reports (
    report_id    TEXT NOT NULL,
    lot_id       TEXT NOT NULL,
    line_id      TEXT NOT NULL,
    part_number  TEXT NOT NULL,
    inspector_id TEXT NOT NULL,
    report_date  DATE NOT NULL,
    status       TEXT NOT NULL,
    disposition  TEXT,
    notes        TEXT,
    CONSTRAINT pk_inspection_reports PRIMARY KEY (report_id),
    CONSTRAINT fk_reports_line
        FOREIGN KEY (line_id) REFERENCES lines (line_id),
    CONSTRAINT fk_reports_lot
        FOREIGN KEY (lot_id) REFERENCES lots (lot_id),
    CONSTRAINT fk_reports_part
        FOREIGN KEY (part_number) REFERENCES parts (part_number),
    CONSTRAINT fk_reports_inspector
        FOREIGN KEY (inspector_id) REFERENCES inspectors (inspector_id),
    CONSTRAINT fk_reports_lot_part_line
        FOREIGN KEY (lot_id, part_number, line_id)
        REFERENCES lots (lot_id, part_number, line_id),
    CONSTRAINT fk_reports_inspector_line
        FOREIGN KEY (inspector_id, line_id)
        REFERENCES inspectors (inspector_id, line_id),
    CONSTRAINT ck_reports_status
        CHECK (status IN ('draft', 'submitted', 'closed')),
    CONSTRAINT ck_reports_disposition
        CHECK (disposition IS NULL OR disposition IN ('accept', 'rework', 'scrap', 'hold')),
    CONSTRAINT ck_reports_draft_no_disposition
        CHECK (status <> 'draft' OR disposition IS NULL)
);

CREATE TABLE IF NOT EXISTS measurements (
    measurement_id    INTEGER NOT NULL,
    report_id         TEXT    NOT NULL,
    characteristic_id TEXT    NOT NULL,
    measured_value    NUMERIC NOT NULL,
    result            TEXT    NOT NULL,
    CONSTRAINT pk_measurements PRIMARY KEY (measurement_id),
    CONSTRAINT fk_measurements_report
        FOREIGN KEY (report_id) REFERENCES inspection_reports (report_id),
    CONSTRAINT fk_measurements_characteristic
        FOREIGN KEY (characteristic_id) REFERENCES characteristics (characteristic_id),
    CONSTRAINT uq_measurements_report_characteristic UNIQUE (report_id, characteristic_id),
    CONSTRAINT ck_measurements_result CHECK (result IN ('pass', 'fail'))
);

CREATE INDEX IF NOT EXISTS ix_reports_line_date ON inspection_reports (line_id, report_date);
CREATE INDEX IF NOT EXISTS ix_reports_part_date ON inspection_reports (part_number, report_date);
CREATE INDEX IF NOT EXISTS ix_reports_lot ON inspection_reports (lot_id);
CREATE INDEX IF NOT EXISTS ix_measurements_characteristic ON measurements (characteristic_id);
CREATE INDEX IF NOT EXISTS ix_measurements_report ON measurements (report_id);
CREATE INDEX IF NOT EXISTS ix_lots_part_produced ON lots (part_number, produced_on);

COMMENT ON TABLE lines IS 'Production lines. Synthetic data. Only A and B exist.';
COMMENT ON TABLE parts IS 'Fictional part catalog grouped by family. Synthetic data.';
COMMENT ON TABLE characteristics IS 'Measured characteristics per part with nominal value and tolerance limits. Synthetic data.';
COMMENT ON TABLE inspectors IS 'Fictional inspectors, each assigned to one line. Synthetic data.';
COMMENT ON TABLE lots IS 'Production lots of one part made on one line. Synthetic data.';
COMMENT ON TABLE inspection_reports IS 'Inspection reports for a lot, written by an inspector of the same line. Synthetic data.';
COMMENT ON TABLE measurements IS 'One measured value per characteristic per inspection report, with a pass or fail result. Synthetic data.';

COMMIT;
