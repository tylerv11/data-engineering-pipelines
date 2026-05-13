# Facility Movement & Shift Presence Analytics

An anonymized data engineering portfolio project that transforms raw badge access events into two analytics-ready datasets: one for movement path visualization and one for historical shift-based workforce presence analysis.

> All company names, building names, door names, coordinates, database names, and employee identifiers have been replaced with generic equivalents. The logic, sessionization design, and shift classification approach are original work.

---

## Overview

This project takes raw badge swipe telemetry from an access control system and produces two distinct analytical outputs from the same event source:

1. **Badge Pathing Points** — reconstructs movement paths between access points, formatted for map visualization
2. **Badge Activity Sessions** — sessionizes badge activity into continuous presence windows and classifies each session by primary shift

Both pipelines anonymize employee identity at the source using a SHA-256 hash, allowing repeatable joins and cross-session tracking without exposing raw employee identifiers.

---

## Business Problem

Raw badge access data is operationally rich but analytically unusable in its raw form. It answers the question "who badged where and when" but not:

- How long was someone active on site during a given period?
- Which shift were they most likely supporting?
- Did their activity meaningfully spill into a second shift?
- What movement patterns exist between access points?
- Which records are unreliable due to system noise or data gaps?

This project builds the transformation layer that turns event-level badge telemetry into answers to those questions.

---

## What It Does

### Badge Pathing Pipeline
- Pulls recent badge events from the access control history table
- Hashes employee IDs into anonymized, repeatable keys
- Matches each door or access point to known coordinates using pattern-based reference lookup
- Sequences badge events by anonymized employee and card number
- Uses `LEAD()` to pair each swipe with the next swipe as its destination
- Calculates elapsed time between origin and destination events
- Filters out invalid or unrealistic segments
- Outputs one origin row and one destination row per movement segment, ready for map visualization

### Session Analysis Pipeline
- Pulls a longer historical window of badge events
- Hashes employee IDs using the same anonymization approach
- Uses `LAG()` to calculate inactivity gaps between consecutive swipes per employee
- Starts a new session when the gap exceeds the configured threshold
- Assigns session numbers using a cumulative sum over the new-session flag
- Calculates raw and usable session duration
- Flags unreliable sessions: micro sessions, single-swipe sessions, and sessions exceeding the max duration cap
- Calculates overlap between each session and five shift windows
- Assigns a primary shift based on greatest overlap
- Assigns a minor shift when the second-largest overlap is meaningful

---

## Architecture

### Badge Pathing

```text
Access Control Badge Events
        ↓
Employee ID Hashing (SHA-256)
        ↓
Door / Location Reference Mapping (pattern match)
        ↓
Event Sequencing (LEAD by employee + card)
        ↓
Origin-to-Destination Segment Generation
        ↓
Map-Ready Movement Point Dataset
```

### Activity Session Analysis

```text
Access Control Badge Events
        ↓
Employee ID Hashing (SHA-256)
        ↓
Swipe Gap Detection (LAG by employee)
        ↓
New Session Flagging (gap > threshold)
        ↓
Session Number Assignment (cumulative sum)
        ↓
Session Duration + Data Quality Flagging
        ↓
Shift Window Overlap Calculation
        ↓
Primary / Minor Shift Classification
        ↓
Historical Presence Dataset
```

---

## ERD

See [`diagrams/erd.md`](diagrams/erd.md) for the full Mermaid entity-relationship diagram.

See [`diagrams/pipeline_flow.md`](diagrams/pipeline_flow.md) for the logical pipeline flow diagram.

---

## Key Business Logic

### Identity Anonymization

Employee IDs are trimmed, uppercased, and hashed using SHA-256 before any join or grouping operation. The hash is stable across runs, which allows session tracking and path sequencing without retaining or exposing raw employee identifiers in the output.

### Door Coordinate Mapping

Access point names are matched to a reference table of known coordinates using pattern-based matching. A `TOP 1` ordered by pattern specificity ensures the most precise match is used when multiple patterns could apply. Access points without a coordinate match pass through with NULL coordinates and are flagged with a coordinate availability indicator.

### Path Reconstruction

Badge events are ordered by anonymized employee key and card number. `LEAD()` projects the next badge event onto each row, creating an origin-to-destination segment. The time between origin and destination becomes the segment duration. The final output unions both points into one row each so a mapping visual can draw lines between them.

### Dwell and Duration

Duration is calculated as the time between the origin badge event and the next observed badge event. This approximates time between observed badge locations. It is not proof of continuous physical presence between points, and the output does not represent it as such.

### Sessionization

Any badge swipe is treated as activity, not just parking or building entry events. This is intentional: employees in controlled environments may badge into internal rooms, gowning zones, warehouses, or other restricted areas without clean facility entry or exit pairs. Using any swipe makes the session model more complete for historical analysis.

A new session begins when:
- It is the first swipe for that employee, or
- The inactivity gap since the previous swipe exceeds the configured threshold

Session numbers are assigned by cumulatively summing a new-session flag, partitioned by employee.

Sessions are not anchored to calendar dates. This prevents overnight sessions from being incorrectly split at midnight, which is critical for accurate night-shift analysis.

### Shift Window Overlap

Overlap between each session and each shift window is calculated as:

```text
max(0, min(session_end, shift_end) - max(session_start, shift_start))
```

Five shift windows are evaluated:

| Shift | Days | Window |
|---|---|---|
| Day | Mon–Fri | 06:00–14:00 |
| Swing | Mon–Fri | 14:00–22:00 |
| Night | Mon–Fri | 22:00–06:00 (crosses midnight) |
| Weekend Swing | Sat–Sun | 10:00–22:00 |
| Weekend Night | Fri–Sat nights | 22:00–10:00 (crosses midnight) |

Night and weekend night windows require evaluating two candidate windows (previous-night and same-night) and taking the maximum overlap to handle sessions that could legitimately align with either.

### Primary and Minor Shift

The shift with the greatest overlap becomes the primary shift. A `MinorShift` is assigned when the second-largest overlap is between 1 and 4 hours. This captures employees who meaningfully spill into a second shift without reclassifying them entirely.

### Data Quality Flags

Each session receives a `data_quality_flag` set to 1 when:
- Session duration is below the minimum threshold (likely a system duplicate or reader noise)
- Session duration exceeds the maximum threshold (likely stitched days or missing badge events)
- The session contains only one swipe (duration cannot be meaningfully interpreted)

These flags are retained in the output so downstream consumers can filter them out or analyze them separately without losing the records.

---

## Output Datasets

### Badge Pathing Points

One origin row and one destination row per movement segment. Designed for map visualization.

| path_id | anon_employee_key | segment_order | point_type | point_time | door_name | latitude | longitude | duration_hours | has_coordinates |
|---|---|---:|---|---|---|---:|---:|---:|---:|
| 839201 | HASH001 | 1 | Origin | 2026-01-08 06:02 | Main Entry | 34.0001 | -118.0001 | 1.4 | 1 |
| 839201 | HASH001 | 1 | End | 2026-01-08 07:26 | Production Gowning | 34.0002 | -118.0002 | 1.4 | 1 |
| 839201 | HASH001 | 2 | Origin | 2026-01-08 07:26 | Production Gowning | 34.0002 | -118.0002 | 3.2 | 1 |
| 839201 | HASH001 | 2 | End | 2026-01-08 10:38 | Warehouse Entry | 34.0003 | -118.0003 | 3.2 | 1 |

### Badge Activity Sessions

One row per employee session, with shift classification and data quality flags.

| anon_employee_key | session_number | begin_session_time | end_session_time | session_duration_hours | shift | minor_shift | swipe_count | data_quality_flag |
|---|---:|---|---|---:|---|---|---:|---:|
| HASH001 | 1 | 2026-01-08 05:55 | 2026-01-08 14:12 | 8.28 | Day | Swing | 9 | 0 |
| HASH002 | 1 | 2026-01-08 13:48 | 2026-01-08 22:31 | 8.72 | Swing | Night | 11 | 0 |
| HASH003 | 1 | 2026-01-10 21:44 | 2026-01-11 09:12 | 11.47 | Weekend Night | null | 7 | 0 |
| HASH004 | 1 | 2026-01-08 07:00 | 2026-01-08 07:00 | null | null | null | 1 | 1 |

---

## Governance and Privacy Design

- Employee identifiers are hashed at the earliest possible step and never appear in any output
- The hash function is applied consistently (trimmed, uppercased) so the same employee produces the same key across both pipelines
- No personally identifiable fields are selected from the source system
- Coordinate data is mapped from a controlled reference table, not sourced from employee devices or systems
- Data quality flags allow consumers to exclude unreliable records without discarding them from the model

---

## Tech Stack

- **Query language:** T-SQL (SQL Server / Azure SQL compatible)
- **Identity anonymization:** SHA-256 via `HASHBYTES`
- **Event sequencing:** `LEAD()` and `LAG()` window functions
- **Session assignment:** Cumulative sum over new-session flag
- **Shift overlap:** Interval intersection arithmetic
- **Visualization layer:** Power BI with Azure Maps visual

---

## Repository Structure

```text
facility-movement-shift-analytics/
│
├── README.md
│
├── sql/
│   ├── badge_pathing_points.sql
│   └── badge_activity_sessions.sql
│
└── diagrams/
    ├── erd.md
    └── pipeline_flow.md
```

---

## Skills Demonstrated

- Event sequencing and path reconstruction using window functions
- Activity sessionization with configurable inactivity gap thresholds
- Shift window overlap calculation using interval intersection arithmetic
- SHA-256 identity anonymization applied at the source step
- Pattern-based spatial reference matching for coordinate enrichment
- Data quality flag design for noisy operational telemetry
- Midnight-crossing session logic for accurate overnight shift analysis
- Azure Maps-ready output format with origin and destination point pairs
- Privacy-aware pipeline design with no PII in outputs
