# Manufacturing Process Event Time Extraction Pipeline

An anonymized data engineering portfolio project that transforms raw manufacturing automation event logs into a structured, analytics-ready batch process-time dataset. The pipeline maps low-level event descriptions and automation action paths to named process milestones, producing one wide record per batch for cycle time dashboards, bottleneck analysis, and operational reporting.

> All database names, table names, batch IDs, equipment names, action paths, event descriptions, operator prompts, and process-specific terminology have been replaced with generic equivalents. The transformation logic, event modeling approach, and analytical design are original work.

---

## Overview

Manufacturing automation systems generate thousands of events per batch. These events are low-level state changes, operator prompts, report emissions, and equipment transitions. They do not arrive pre-labeled with process milestone names. Without transformation, they cannot answer questions like:

- How long did Stage A take for this batch?
- When did Stage C cleaning end and Stage C separation begin?
- Which batch had the longest idle time between Stage B and Stage C?
- How does this batch compare to the historical average for each step?

This pipeline solves that by reading raw event history, identifying which specific events represent the start or end of each named process milestone, and collapsing thousands of events into one clean batch-level record with a structured timestamp for every major step.

In production, this pipeline processes hundreds of manufacturing event steps per batch, collapsing thousands of raw historian events per lot into a single analytical timing record. The downstream semantic model runs a biweekly operations review with six department leads across Manufacturing, Process Engineering, Business Excellence, Reliability, Scheduling, and Quality -- and feeds Engineering's capital investment planning system (SchedulePro) with throughput and critical path estimates.

This is event-to-milestone analytical modeling, not transactional OLTP modeling. The source system is a historian/event log, and the gold output is one analytical timing record per batch or lot.

---

## Business Problem

Raw automation event logs present several challenges for analytics:

- Thousands of low-level system events per batch with no inherent milestone structure
- Cryptic action path strings that encode equipment hierarchy and step sequences
- Repeated state-change messages from multiple equipment paths for the same logical step
- Numeric and timestamp values embedded inside event description text strings
- Process version differences over time where the same milestone may be captured by different event patterns
- No existing "start" or "end" column for any manufacturing step

Operations teams need reliable batch-level milestones, not raw event streams. Cycle time analysis, bottleneck identification, and equipment utilization tracking all require structured timestamps that this pipeline produces.

---

## What It Does

1. Filters raw event history to the configured reporting window
2. Groups records by batch ID
3. Applies conditional aggregation to extract process milestones from matching events
4. Uses `MIN()` for start events and earliest observed timestamps
5. Uses `MAX()` for completion events and latest observed timestamps
6. Handles alternate event and action path patterns for the same logical step across process versions
7. Parses embedded values from event description text using string functions
8. Handles double-lot and multi-path batch types by rewriting batch ID variants before aggregation
9. Produces one wide process-time record per batch
10. Feeds downstream cycle time, bottleneck, and operational dashboard models

---

## Architecture

```text
Manufacturing Historian / Event Log
        ↓
Reporting Window Filter
        ↓
Batch / Lot Normalization
        ↓
Event Pattern Classification
        ↓
Conditional Aggregation
        ├─ MIN() for start milestones
        ├─ MAX() for end milestones
        └─ String parsing for embedded values and timestamps
        ↓
Batch Process Times Gold
        ↓
BI Semantic Model / Cycle Time Analytics
```

The model deliberately uses a pipeline flow representation rather than a strict relational ERD because the important design problem is how raw events become named milestones.

---

## Data Model and Downstream Semantic Layer

The gold output table feeds a multi-table semantic model in Power BI. The model is structured as a star schema centered on the process event fact table, with the following key tables:

| Table | Type | Grain |
|---|---|---|
| FracDataModel | Fact | One row per micro step per batch |
| PlasmaMasterTable | Lot master | One row per lot, ISO week |
| FracDurationsTable | Pre-aggregated | Duration rollup for performance |
| LatestBatchPerProcessStep_72h | Calculated | Current active batch per step, 72h window |
| RTMS Delays / JDE Delays | Delay dimensions | One row per delay event per source |
| MicroStepLookup | Dimension | Step type classification |

**LatestBatchPerProcessStep_72h** is a calculated DAX table -- not a SQL query -- that identifies the most current active batch at each process step within a rolling 72-hour window. It uses TREATAS to project float, critical path turnaround, and wait time measures onto the real-time snapshot. This powers the unit op priority and bottleneck scheduling page used by Engineering for capital investment decisions.

**Key semantic layer measures:**
- Throughput: 168 hrs/week ÷ system pitch (avg start-to-start at constraint step) × 52.177 × avg volume per lot
- Float: available buffer before a batch becomes the critical path constraint
- Float Time Taken / Float Time Overspent: how much buffer was consumed vs. available
- Process Step Average: SUMX over micro step types with outlier exclusion (0-150hr window), cleaning step exclusions, and PPT vessel normalization
- Process Step Median: delay-excluded critical path estimate used for MPS delivery schedule and SchedulePro capital planning
- P20/P80 Spread: spread between best regularly achievable and common case -- used to scope improvement projects
- Process Drift Flag: visual flag when a step drifts from its historical baseline (SPC custom visual)

**Delay integration:** The standard work page unifies delay events from two separate operational systems -- RTMS (real-time manufacturing system) and JDE work orders (via Databricks) -- into a single shift-based analysis view with rolling averages and process drift indicators. This required matching on batch ID and step across systems with different schemas and timing conventions.

---

## Source Data Shape

The raw event log has the following conceptual structure:

| Column | Description |
|---|---|
| `batch_id` | Identifier for the production batch or lot |
| `event_time` | Timestamp when the event occurred |
| `event_description` | Free-text description of the system event or operator action |
| `action_path` | Hierarchical automation path identifying the recipe step that generated the event |
| `equipment_unit` | Equipment identifier associated with the event |

Each batch generates hundreds to thousands of rows in this table across its full run. The pipeline collapses all of them into a single output row.

---

## Transformation Pattern

The core pattern used throughout the pipeline is conditional aggregation:

**Start milestone extraction:**
```sql
MIN(CASE
    WHEN event_description LIKE 'STATE_RUNNING%'
     AND action_path LIKE '%STAGE_A_INIT_PATH%'
    THEN event_time
END) AS stage_a_process_start
```

**End milestone extraction:**
```sql
MAX(CASE
    WHEN event_description LIKE 'STATE_COMPLETE%'
     AND action_path LIKE '%STAGE_A_TRANSFER_PATH%'
    THEN event_time
END) AS stage_a_transfer_end
```

**Alternate path handling** — when the same milestone can be generated by different equipment routes or process versions:
```sql
MIN(CASE
    WHEN event_description LIKE 'STATE_RUNNING%'
     AND (
            action_path LIKE '%STAGE_B_PRIMARY_PATH%'
         OR action_path LIKE '%STAGE_B_ALTERNATE_PATH%'
     )
    THEN event_time
END) AS stage_b_process_start
```

**Embedded value parsing** — when a numeric or timestamp value is encoded inside the event description string:
```sql
MIN(CASE
    WHEN event_description LIKE 'REPORT_BATCH_VOLUME%'
     AND action_path LIKE '%VOLUME_ENTRY_PATH%'
    THEN TRY_CAST(
        SUBSTRING(event_description, CHARINDEX(' ', event_description) + 1, 10)
        AS DECIMAL(18,2)
    )
END) AS batch_volume_liters
```

**Embedded timestamp parsing** — when a start or end datetime is logged inside the event description itself:
```sql
MIN(CASE
    WHEN event_description LIKE 'REPORT_LOAD_CLEAN_START%'
     AND action_path LIKE '%STAGE_C_REASSEMBLY%'
    THEN TRY_CONVERT(DATETIME, SUBSTRING(event_description, 20, 16))
END) AS stage_c_load_clean_start
```

### Milestone Extraction Concept

Each milestone is defined by a business-readable rule: event description pattern, action path pattern, equipment/unit context when needed, and whether the earliest or latest qualifying timestamp is the correct analytical signal. This keeps the transformation auditable even when the source event log remains verbose and system-specific.

---

## Key Design Decisions

**Why `MIN()` for starts and `MAX()` for ends?**
A process step can generate multiple qualifying events if there are multiple equipment units running in parallel or if the automation logs a state change more than once. `MIN()` captures the earliest start signal; `MAX()` captures the latest completion signal.

**Why multiple action path conditions on the same milestone?**
Manufacturing automation recipes evolve over time. A process step that was once controlled by one action path may be re-implemented under a different path after an automation upgrade or process change. Both patterns must be covered to produce a consistent historical time series.

**Why batch ID rewriting before aggregation?**
Double-lot or multi-product batches may be tracked under a single campaign batch ID at the automation level but need to be separated into individual A and B lot records for analytics. The inner subquery rewrites batch IDs before grouping so each lot can be analyzed independently.

Normalization also protects downstream duration calculations from mixing events that belong to adjacent lots, campaign-level prompts, or alternate batch ID formats.

**Why parse values from event text?**
Some manufacturing automation systems do not write discrete numeric fields to the historian. Volume entries, equipment timing, and process parameters may only exist as formatted strings inside event descriptions. String parsing is the only way to extract these values into structured analytics columns.

---

## Analytical Use Cases

- One timing record per batch for cycle time dashboards
- Stage duration and idle-time calculations across sequential process steps
- Batch-to-batch comparison by equipment unit, lot type, and time period
- Bottleneck and float analysis for Lean Six Sigma improvement work
- Common-cause versus special-cause process variation monitoring
- BI semantic model inputs for leadership, engineering, and operations review

---

## Validation Methodology

| Check | Purpose |
|---|---|
| Event sample trace | Manually trace selected batches from raw events to extracted milestones |
| Start/end aggregation review | Confirm starts use earliest valid signal and ends use latest valid signal |
| Alternate path coverage | Test equipment/process variants against the same milestone definition |
| Batch normalization test | Confirm double-lot and alternate batch formats do not contaminate each other |
| Parsed-value validation | Compare parsed numeric/timestamp values to source event text samples |
| Duration sanity checks | Flag negative, null, or unrealistic stage durations before BI consumption |

---

## Output Dataset

One row per batch. Sample output:

| batch_id | process_start_time | process_unit | batch_volume_liters | stage_a_process_start | stage_a_transfer_end | stage_b_process_start | stage_b_send_end | stage_c_process_end | raw_event_count |
|---|---|---|---:|---|---|---|---|---|---:|
| LOT_001 | 2026-01-03 06:12 | UNIT_A | 4200.0 | 2026-01-03 06:12 | 2026-01-03 11:45 | 2026-01-03 13:10 | 2026-01-03 21:40 | 2026-01-04 02:20 | 481 |
| LOT_002 | 2026-01-04 07:03 | UNIT_B | 3950.0 | 2026-01-04 07:03 | 2026-01-04 12:02 | 2026-01-04 13:44 | 2026-01-04 22:17 | 2026-01-05 01:51 | 506 |
| LOT_003 | 2026-01-05 06:55 | UNIT_A | 4100.0 | 2026-01-05 06:55 | 2026-01-05 11:30 | 2026-01-05 13:02 | 2026-01-05 21:58 | 2026-01-06 03:05 | 493 |

---

## How It Supports Cycle Time Analytics

The wide process-time table feeds downstream models where step durations and idle times can be calculated directly:

```text
stage_a_duration        = stage_a_transfer_end     - stage_a_process_start
stage_b_duration        = stage_b_send_end         - stage_b_process_start
stage_c_duration        = stage_c_process_end      - stage_c_process_start
a_to_b_idle             = stage_b_process_start    - stage_a_post_rinse_end
b_to_c_idle             = stage_c_process_start    - stage_b_send_end
```

This enables:

- Cycle time dashboards per process stage and equipment unit
- Batch-to-batch comparison and trend analysis
- Idle time identification between sequential steps
- Bottleneck detection across the value stream
- Common-cause vs. special-cause process variation analysis
- Equipment utilization reporting by unit and shift
- Step-level drilldown from summary KPIs to individual batch timelines

---

## Privacy and Anonymization Strategy

This portfolio version uses entirely generic table names, event patterns, action paths, and process terminology. No real automation paths, product-specific event descriptions, equipment IDs, operator prompts, or business-identifiable strings appear in this repository.

The transformation logic and event-modeling approach are original work. The specific event patterns and action paths that drive this logic in production were developed through analysis of automation system behavior, process documentation, and iterative validation against observed batch timelines.

Anonymization preserves the architecture and modeling patterns while replacing real operational identifiers with representative placeholders. The README and SQL comments avoid real product names, equipment names, event descriptions, process identifiers, automation paths, and batch IDs.

---

## Governance Considerations

- Keep milestone definitions documented next to the SQL logic so business owners can review assumptions
- Treat parsed event descriptions as source-system dependent and validate after automation changes
- Separate batch/lot normalization from milestone aggregation so identity rules are easy to audit
- Retain raw event counts and completeness indicators in downstream outputs where possible
- Use semantic-layer measures for duration calculations so KPI definitions remain consistent across dashboards

---

## Tech Stack

- **Query language:** Databricks SQL (primary transformation layer) and T-SQL (Microsoft SQL Server source system queries)
- **Storage layer:** Delta lakehouse -- Bronze raw events, Silver normalized milestones, Gold analytical batch-process-times table
- **Source system:** Manufacturing automation event historian (Microsoft SQL Server) + ERP delay data (JDE via Databricks)
- **Transformation pattern:** Conditional aggregation with `MIN(CASE WHEN ...)` and `MAX(CASE WHEN ...)`
- **String parsing:** `SUBSTRING`, `CHARINDEX`, `TRY_CAST`, `TRY_CONVERT`
- **Batch ID normalization:** Inline subquery rewrite before grouping
- **Downstream consumption:** Power BI semantic model, cycle time dashboards

---

## Repository Structure

```text
manufacturing-process-event-modeling/
│
├── README.md
│
├── sql/
│   └── batch_process_times_gold_excerpt.sql
│
└── diagrams/
    └── pipeline_flow.md
```

---

## Skills Demonstrated

- Event-to-milestone mapping from raw automation historian data
- Conditional aggregation for batch-level timestamp extraction
- Alternate path handling for process version changes and equipment variation
- Embedded string parsing for numeric and timestamp values
- Batch ID normalization for multi-path and double-lot processing
- Business rule documentation embedded in transformation code
- BI-ready gold table design for cycle time and bottleneck analytics
- Star schema semantic model design with fact and dimension tables
- Calculated DAX table design using TREATAS for cross-filter measure projection (LatestBatchPerProcessStep_72h scheduling layer)
- Multi-source delay data integration across heterogeneous operational systems
- Medallion architecture (Bronze/Silver/Gold) on Delta lakehouse
- SPC and process drift monitoring with custom visual integration
- Throughput and float modeling for Lean Six Sigma constraint analysis
- End-to-end product ownership through 7+ major versions over 2 years
- Privacy-aware anonymization of production SQL logic
