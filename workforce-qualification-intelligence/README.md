# Workforce Qualification Intelligence Platform

An anonymized portfolio case study demonstrating how raw learning management and HR data can be transformed into a curated gold-layer dataset for workforce qualification tracking, training compliance reporting, certification renewal monitoring, and manager-level visibility.

> All company names, system names, server names, schema names, site identifiers, and personally identifiable details have been replaced with generic equivalents. The logic, architecture, and engineering approach are original work.

---

## Overview

This project delivers a single, analytics-ready gold-layer view that combines learning platform assignment data, certification and training catalog metadata, completion status references, label decoding lookups, and HRIS hierarchy enrichment into one governed reporting dataset.

The output is designed for direct consumption by a semantic reporting layer such as Power BI, where row-level security, DAX measures, and KPI dashboards sit on top of a trusted, well-documented data foundation.

---

## Business Problem

Enterprise learning platforms store training assignments across multiple source tables, use internal label keys instead of readable display names, and mix one-time training with renewal-based certification requirements. Without transformation, this data produces:

- Inflated overdue counts driven by inactive historical audit rows
- Missing or misleading renewal due dates for certification-linked training
- Inconsistent compliance statuses that differ from what the learning platform UI shows
- No reliable connection between training records and the HR hierarchy needed for manager-level reporting

This pipeline resolves all of these issues in a single, well-documented transformation layer.

---

## What It Does

- Unions standalone training assignments and certification-linked training assignments into one normalized structure
- Filters inactive historical records at the source to prevent phantom overdue counts
- Joins training item metadata, certification metadata, completion status references, and label lookup tables
- Decodes system-generated label keys into readable training titles, certification titles, and status descriptions
- Calculates renewal due dates from employee completion dates and configured retraining intervals
- Derives normalized compliance statuses for both one-time and renewal-based training
- Applies ROW_NUMBER() deduplication to produce one current record per employee, certification, and training item
- Enriches records with employee and manager display names from the governed HRIS source

---

## Architecture

```text
Learning Platform Assignments
        +
Certification Metadata
        +
Training Catalog
        +
Reference Label Lookups
        +
HRIS Worker Hierarchy
        ↓
SQL Transformation Layer  (this project)
        ↓
Gold Qualification View
        ↓
Power BI / Semantic Reporting Layer
```

The transformation is organized as a chain of CTEs, each with a clear responsibility:

| CTE | Purpose |
|---|---|
| `assignment_union` | Normalize standalone and certification-linked assignments into one structure |
| `base_training` | Enrich assignments with catalog metadata, label decoding, and custom attributes |
| `status_enrichment` | Calculate renewal dates and derive source-style compliance statuses |
| `final_status` | Produce normalized statuses, days-until-due, due-date display, and deduplication |
| `worker_clean` | Prepare deduplicated, display-ready employee and manager names from HRIS |

---

## ERD

See [`diagrams/erd.md`](diagrams/erd.md) for the full Mermaid entity-relationship diagram.

**Key relationships at a glance:**

- `EMPLOYEE_PROFILE` is the anchor for all assignment records
- `TRAINING_ITEM_CATALOG` and `CERTIFICATION_CATALOG` provide item and certification metadata
- `CERTIFICATION_TRAINING_MAP` links certifications to their training items and carries renewal interval configuration
- `REFERENCE_LABEL_LOOKUP` translates system label keys into readable values across multiple entity types
- `HRIS_WORKER_PROFILE` is the governed source for employee and manager identity
- `WORKFORCE_QUALIFICATION_GOLD` is the final curated output

---

## Key Business Logic

### Assignment Union

The source learning platform stores standalone training assignments and certification-linked assignments in separate tables with slightly different schemas. This pipeline unions both into a single normalized structure so all downstream compliance logic applies consistently regardless of assignment origin.

### Active Assignment Filtering

Certification-linked assignments are filtered to active records before any downstream joins. The source system retains inactive historical rows for audit purposes, but those rows must not enter the compliance model. Applying this filter at the source CTE prevents inactive records from affecting overdue calculations, due-date derivations, or manager-facing reporting.

### Label Decoding

The learning platform stores display values as internal label keys rather than readable strings. The `REFERENCE_LABEL_LOOKUP` table is joined multiple times using separate aliases to decode training item titles, certification titles, certification descriptions, and completion status labels independently without cross-contamination.

### Renewal Date Logic

Renewal-based training calculates a future due date by adding the configured renewal interval to the employee's completion date. The source system may store intervals in mixed formats: values below 10 are interpreted as years, while values of 10 or greater are interpreted as days. This allows the model to handle both formats without requiring upstream data cleanup.

### Normalized Compliance Status

The final model collapses raw learning platform statuses into five reporting-friendly categories:

| Status | Meaning |
|---|---|
| `Qualified` | Employee has completed the training and renewal is not approaching |
| `Qualified - Renewal Due Soon` | Qualified but renewal is within 90 days |
| `Assigned - Not Yet Qualified` | Assigned but not yet completed |
| `Overdue` | Past due with no completion |
| `Renewal Overdue` | Previously qualified but renewal window has passed |

### Days Until Due

Days until due is calculated differently depending on training type:

- **Renewal-based training:** Ages against `renewal_due_at`, with fallback to `training_due_at` when no completion exists yet. Negative values indicate overdue records.
- **Completed one-time training:** Returns NULL because no future due date exists.
- **Incomplete one-time training:** Ages against `training_due_at`.

### Deduplication

The source learning data can produce multiple rows per employee, certification, and training item due to revisions, historical updates, or audit records. ROW_NUMBER() is used to keep the single most current row, prioritizing the highest revision number, latest revision date, and latest source update timestamp.

### HRIS Enrichment

The learning platform provides assignment and completion data but is not the governed source for employee identity or organizational hierarchy. Employee and manager display names are joined from the HRIS reference table using the latest active worker record, keeping identity and reporting hierarchy aligned with the organization's master data.

---

## Output Dataset

The gold view produces one row per employee, certification, and training item. A representative sample:

| employee_id | site_code | training_item_id | certification_id | certification_title | normalized_compliance_status | days_until_due | assignment_method | employee_name | manager_name |
|---|---|---|---|---|---:|---|---|---|---|
| EMP001 | SITE_A | TRN-1001 | CERT-2001 | Equipment Safety | Qualified | 184 | Assignment Profile | Alex Morgan | Jordan Lee |
| EMP002 | SITE_A | TRN-1008 | CERT-2003 | Cleanroom Operations | Qualified - Renewal Due Soon | 27 | Connector | Sam Rivera | Jordan Lee |
| EMP003 | SITE_B | TRN-1012 | CERT-2007 | Manufacturing Basics | Overdue | -12 | Manager | Riley Chen | Taylor Brooks |
| EMP004 | SITE_B | TRN-1019 | CERT-2010 | Annual Refresher | Renewal Overdue | -33 | Assignment Profile | Casey Patel | Taylor Brooks |

---

## Governance and Privacy Design

- Employee and manager names are sourced exclusively from the governed HRIS system, not the learning platform, to ensure identity data flows through a single controlled source
- Active-record filtering is applied at the earliest possible stage to prevent audit-only rows from affecting compliance outputs
- No personally identifiable information is selected from unmasked or uncontrolled source fields
- Deduplication is applied before the final SELECT to ensure downstream consumers receive one clean, current record per subject
- Regional and privacy-based scope controls are implemented through a site dimension filter rather than hard-coded business identifiers, making the model easier to maintain and extend

---

## Tech Stack

- **Query language:** SQL (Databricks SQL / Spark SQL compatible)
- **Storage layer:** Cloud lakehouse with raw and analytics schemas
- **Transformation pattern:** CTE-based gold view with documented business rules at each stage
- **Reporting layer:** Power BI semantic model with row-level security
- **Identity enrichment:** HRIS reference table as governed master source

---

## Repository Structure

```text
workforce-qualification-intelligence/
│
├── README.md
│
├── sql/
│   └── workforce_qualification_gold_view.sql
│
└── diagrams/
    └── erd.md
```

---

## Skills Demonstrated

- CTE-based SQL transformation design for a lakehouse gold layer
- Compliance and renewal logic for mixed one-time and cyclical training models
- Multi-alias label decoding from a single reference lookup table
- Deduplication with ROW_NUMBER() across revision and timestamp dimensions
- HRIS enrichment as a governed identity source
- Active-record filtering strategy to prevent audit row contamination
- Semantic model readiness with clean, documented output fields
- Privacy-aware data design with no direct PII exposure from source systems
- Business rule documentation embedded in transformation code
