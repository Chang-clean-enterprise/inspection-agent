"""Static SQL text for the inspection tools.

Every statement is a module-level constant with named placeholders
(``%(name)s``). The SQL text never changes with caller input. Optional filters
use the pattern ``(%(x)s::text IS NULL OR col = %(x)s)`` and exact equality, so
``%`` and ``_`` in a value are plain characters. Only SELECT statements live
here. Every data query restricts rows with ``line_id = ANY(%(lines)s::text[])``.
"""

# ---------------------------------------------------------------------------
# list_reports
# ---------------------------------------------------------------------------

LIST_REPORTS = """
SELECT r.report_id,
       r.report_date,
       r.line_id AS line,
       r.part_number,
       r.lot_id,
       r.status,
       r.disposition,
       CASE
           WHEN EXISTS (SELECT 1 FROM measurements m
                        WHERE m.report_id = r.report_id AND m.result = 'fail')
               THEN 'fail'
           WHEN EXISTS (SELECT 1 FROM measurements m
                        WHERE m.report_id = r.report_id)
               THEN 'pass'
           ELSE 'none'
       END AS overall_result,
       count(*) OVER () AS total_matches
FROM inspection_reports r
WHERE r.line_id = ANY(%(lines)s::text[])
  AND (%(part)s::text IS NULL OR r.part_number = %(part)s)
  AND (%(lot)s::text IS NULL OR r.lot_id = %(lot)s)
  AND (%(date_from)s::date IS NULL OR r.report_date >= %(date_from)s)
  AND (%(date_to)s::date IS NULL OR r.report_date <= %(date_to)s)
  AND (%(status)s::text IS NULL OR r.status = %(status)s)
ORDER BY r.report_date DESC, r.report_id ASC
LIMIT %(limit)s
"""

# ---------------------------------------------------------------------------
# Header lookups for ID tools. Unscoped by design, select the line only.
# ---------------------------------------------------------------------------

REPORT_HEADER = """
SELECT line_id
FROM inspection_reports
WHERE report_id = %(report_id)s
"""

LOT_HEADER = """
SELECT line_id
FROM lots
WHERE lot_id = %(lot_id)s
"""

# ---------------------------------------------------------------------------
# get_report
# ---------------------------------------------------------------------------

# One row per measurement. A report without measurements returns one row whose
# measurement columns are NULL (LEFT JOIN).
GET_REPORT = """
SELECT r.report_id,
       r.report_date,
       r.line_id AS line,
       r.part_number,
       r.lot_id,
       r.inspector_id,
       r.status,
       r.disposition,
       r.notes,
       m.characteristic_id,
       c.name AS characteristic_name,
       c.unit,
       m.measured_value,
       c.lower_limit,
       c.upper_limit,
       m.result
FROM inspection_reports r
LEFT JOIN measurements m ON m.report_id = r.report_id
LEFT JOIN characteristics c ON c.characteristic_id = m.characteristic_id
WHERE r.report_id = %(report_id)s
  AND r.line_id = ANY(%(lines)s::text[])
ORDER BY m.characteristic_id ASC
"""

# ---------------------------------------------------------------------------
# get_lot
# ---------------------------------------------------------------------------

GET_LOT = """
SELECT l.lot_id,
       l.part_number,
       l.line_id AS line,
       l.produced_on,
       l.quantity
FROM lots l
WHERE l.lot_id = %(lot_id)s
  AND l.line_id = ANY(%(lines)s::text[])
"""

GET_LOT_REPORTS = """
SELECT r.report_id,
       r.report_date,
       r.line_id AS line,
       r.part_number,
       r.lot_id,
       r.inspector_id,
       r.status,
       r.disposition,
       r.notes,
       count(*) OVER () AS total_reports
FROM inspection_reports r
WHERE r.lot_id = %(lot_id)s
  AND r.line_id = ANY(%(lines)s::text[])
ORDER BY r.report_date ASC, r.report_id ASC
LIMIT %(limit)s
"""

GET_LOT_MEASUREMENTS = """
SELECT m.report_id,
       m.characteristic_id,
       c.name AS characteristic_name,
       c.unit,
       m.measured_value,
       c.lower_limit,
       c.upper_limit,
       m.result
FROM measurements m
JOIN inspection_reports r ON r.report_id = m.report_id
JOIN characteristics c ON c.characteristic_id = m.characteristic_id
WHERE m.report_id = ANY(%(ids)s::text[])
  AND r.line_id = ANY(%(lines)s::text[])
ORDER BY m.report_id ASC, m.characteristic_id ASC
"""

# ---------------------------------------------------------------------------
# characteristic_trend
# ---------------------------------------------------------------------------

# Catalog existence checks. Not line-restricted data.
PART_EXISTS = """
SELECT part_number
FROM parts
WHERE part_number = %(part)s
"""

CHARACTERISTIC_LOOKUP = """
SELECT characteristic_id,
       name,
       unit,
       nominal,
       lower_limit,
       upper_limit
FROM characteristics
WHERE part_number = %(part)s
  AND name = %(characteristic)s
"""

# Most recent 50 lots, newest first. The caller reverses to ascending order.
CHARACTERISTIC_TREND = """
SELECT l.lot_id,
       l.produced_on,
       count(*) AS count,
       avg(m.measured_value) AS mean,
       min(m.measured_value) AS min,
       max(m.measured_value) AS max,
       count(*) FILTER (WHERE m.measured_value < c.lower_limit
                           OR m.measured_value > c.upper_limit)
           AS out_of_tolerance_count,
       count(*) OVER () AS total_lots
FROM measurements m
JOIN inspection_reports r ON r.report_id = m.report_id
JOIN lots l ON l.lot_id = r.lot_id
JOIN characteristics c ON c.characteristic_id = m.characteristic_id
WHERE c.characteristic_id = %(characteristic_id)s
  AND l.line_id = ANY(%(lines)s::text[])
  AND r.line_id = ANY(%(lines)s::text[])
  AND (%(date_from)s::date IS NULL OR l.produced_on >= %(date_from)s)
  AND (%(date_to)s::date IS NULL OR l.produced_on <= %(date_to)s)
GROUP BY l.lot_id, l.produced_on
ORDER BY l.produced_on DESC, l.lot_id DESC
LIMIT 50
"""
