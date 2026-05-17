# Pipeline Flow Diagram

## Manufacturing Process Event Time Extraction Pipeline

---

This is a pipeline/system flow diagram rather than a relational ERD because the core modeling challenge is event-to-milestone transformation. The source is an automation historian/event log; the output is one analytical timing record per normalized batch or lot.

## End-to-End Data Flow

```mermaid
flowchart TD
    A([Raw Manufacturing Historian Event Log\nbatch_id or lot_id, event_time,\nevent_description, action_path,\nequipment_unit]) --> B[Filter to Reporting Window\nevent_time >= start_date]

    B --> C[Batch ID Normalization\nRewrite campaign and double-lot\nbatch IDs into A/B lot variants\nbefore grouping]

    C --> D{Event Type}

    D -- State change events --> E[Conditional Aggregation\nMIN for start events\nMAX for completion events]
    D -- Report/prompt events --> F[String Parsing\nSUBSTRING + CHARINDEX\nfor embedded values]
    D -- CIP and cleanup events --> G[Cross-Batch Linkage\nSubquery joins CIP batch IDs\nback to process batch IDs]

    E --> H[Group by batch_id]
    F --> H
    G --> H

    H --> I([Batch Process Times Gold\nOne analytical row per batch or lot\nAll stage timestamps\nand extracted parameters])

    I --> J[Cycle Time Calculations\nstage_duration = end - start\nidle_time = next_start - prior_end]
    J --> K([Power BI Semantic Model\nCycle Time Dashboards\nBottleneck Analysis\nBatch Comparison])
```

---

## Event-to-Milestone Mapping Pattern

```mermaid
flowchart LR
    raw([raw_manufacturing_event_log\nThousands of rows per batch]) --> filter[Filter by\nevent_description pattern\n+ action_path pattern\n+ equipment_unit]

    filter --> agg{MIN or MAX?}

    agg -- Start event --> mn([MIN event_time\n= step_start_time])
    agg -- End event --> mx([MAX event_time\n= step_end_time])
    agg -- Embedded value --> parse([Parse SUBSTRING\n= numeric or timestamp field])
```

Starts use `MIN(event_time)` because the first valid qualifying signal represents the start of a step. Ends use `MAX(event_time)` because the final valid qualifying signal represents completion, especially when repeated state changes or parallel equipment paths are present.

---

## Batch ID Normalization Flow

```mermaid
flowchart TD
    raw([Raw batch_id from event log]) --> check{Batch type?}

    check -- Single lot --> passthrough([Keep batch_id as-is])
    check -- Double-lot, action path suffix 1-2 --> blot([Rewrite to B lot ID])
    check -- Double-lot, action path suffix 1-1 --> alot([Rewrite to A lot ID])
    check -- A lot with inter-lot prompts --> remap([Remap specific prompts\nfrom A lot to B lot\nto prevent milestone contamination])

    passthrough --> group([GROUP BY normalized batch_id])
    blot --> group
    alot --> group
    remap --> group
```

---

## Output to Downstream Analytics

```mermaid
flowchart LR
    gold([batch_process_times_gold\nOne row per batch\nAll milestones as columns]) --> dur[Duration Calculations\nstep_end - step_start]
    gold --> idle[Idle Time Calculations\nnext_start - prior_end]
    gold --> comp[Batch Comparisons\nActual vs historical average]

    dur --> pbi([Power BI Dashboard\nCycle Time by Stage\nBottleneck Heatmap\nBatch Performance Review])
    idle --> pbi
    comp --> pbi
```
