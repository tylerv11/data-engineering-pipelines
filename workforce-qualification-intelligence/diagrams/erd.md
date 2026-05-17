# Entity Relationship Diagram

## Workforce Qualification Intelligence Platform

The ERD below shows the source tables that feed the gold-layer view, their relationships, and the final output.

This is an analytical source-to-output model, not an OLTP schema. `WORKFORCE_QUALIFICATION_GOLD` is a derived gold-layer output created from LMS assignment/compliance truth plus HRIS identity enrichment.

```mermaid
erDiagram

    EMPLOYEE_PROFILE {
        string employee_id PK "anonymized LMS worker key"
        string site_code
        string job_title
    }

    EMPLOYEE_TRAINING_ASSIGNMENT {
        string employee_id FK
        string training_item_type
        string training_item_id FK
        date   revision_date FK
        string assigned_by_type
        string assigned_by_user
        date   assigned_at
        date   due_at
        string completion_status_id FK
        date   completed_at
        timestamp updated_at
        string assignment_type
    }

    EMPLOYEE_CERTIFICATION_ASSIGNMENT {
        string employee_id FK
        string certification_id FK
        string training_item_type
        string training_item_id FK
        date   revision_date FK
        string assigned_by_type
        string assigned_by_user
        string renewal_interval
        date   assigned_at
        date   due_at
        string completion_status_id FK
        date   completed_at
        timestamp updated_at
        string assignment_type
        string active_flag
    }

    TRAINING_ITEM_CATALOG {
        string training_item_type PK
        string training_item_id PK
        date   revision_date PK
        string revision_number
        string training_title_key FK
    }

    CERTIFICATION_CATALOG {
        string certification_id PK
        string certification_title_key FK
        string certification_description_key FK
    }

    CERTIFICATION_TRAINING_MAP {
        string certification_id FK
        string training_item_type FK
        string training_item_id FK
        date   revision_date FK
        string renewal_interval
    }

    TRAINING_COMPLETION_STATUS {
        string completion_status_id PK
        string completion_status_key FK
    }

    REFERENCE_LABEL_LOOKUP {
        string label_id PK
        string locale PK
        string label_value
    }

    LEARNING_COMPLIANCE_EVENTS {
        string employee_id FK
        string training_item_type FK
        string training_item_id FK
        date   revision_date FK
        string assignment_type FK
        date   assigned_at FK
        date   completed_at FK
        string completion_status_id FK
        date   due_at
    }

    HRIS_WORKER_PROFILE {
        string employee_id PK "same anonymized worker key used for enrichment"
        string employee_name
        string manager_name
        string active_employee_flag
        timestamp updated_at
        timestamp loaded_at
    }

    WORKFORCE_QUALIFICATION_GOLD {
        string employee_id FK
        string site_code
        string job_title
        string training_item_type
        string training_item_id
        string revision_number
        date   revision_date
        string training_item_title
        string certification_id
        string certification_title
        string certification_description
        date   assigned_at
        date   training_due_at
        date   completed_at
        date   renewal_due_at
        string renewal_due_display
        date   assignment_due_date_display
        string completion_status
        string source_system_compliance_status
        string normalized_compliance_status
        int    days_until_due
        string assignment_method
        string assignment_method_group
        string employee_name
        string manager_name
        string employee_last_name
        string manager_last_name
    }

    %% Assignment relationships
    EMPLOYEE_PROFILE            ||--o{ EMPLOYEE_TRAINING_ASSIGNMENT      : "has many"
    EMPLOYEE_PROFILE            ||--o{ EMPLOYEE_CERTIFICATION_ASSIGNMENT  : "has many"

    %% Training item catalog describes both assignment types
    TRAINING_ITEM_CATALOG       ||--o{ EMPLOYEE_TRAINING_ASSIGNMENT       : "describes"
    TRAINING_ITEM_CATALOG       ||--o{ EMPLOYEE_CERTIFICATION_ASSIGNMENT  : "describes"

    %% Certification catalog groups certification assignments
    CERTIFICATION_CATALOG       ||--o{ EMPLOYEE_CERTIFICATION_ASSIGNMENT  : "groups"

    %% Certification training map links certifications to items and carries renewal logic
    CERTIFICATION_CATALOG       ||--o{ CERTIFICATION_TRAINING_MAP         : "defines items for"
    TRAINING_ITEM_CATALOG       ||--o{ CERTIFICATION_TRAINING_MAP         : "mapped in"

    %% Completion status reference
    TRAINING_COMPLETION_STATUS  ||--o{ EMPLOYEE_TRAINING_ASSIGNMENT       : "classifies"
    TRAINING_COMPLETION_STATUS  ||--o{ EMPLOYEE_CERTIFICATION_ASSIGNMENT  : "classifies"

    %% Label lookup decodes titles, descriptions, and status labels
    REFERENCE_LABEL_LOOKUP      ||--o{ TRAINING_ITEM_CATALOG              : "decodes title"
    REFERENCE_LABEL_LOOKUP      ||--o{ CERTIFICATION_CATALOG              : "decodes title and description"
    REFERENCE_LABEL_LOOKUP      ||--o{ TRAINING_COMPLETION_STATUS         : "decodes status label"

    %% LMS assignments own/generate compliance due-date events
    EMPLOYEE_TRAINING_ASSIGNMENT      ||--o{ LEARNING_COMPLIANCE_EVENTS    : "generates events"
    EMPLOYEE_CERTIFICATION_ASSIGNMENT ||--o{ LEARNING_COMPLIANCE_EVENTS    : "generates events"

    %% HRIS enriches the gold output with identity and hierarchy only
    HRIS_WORKER_PROFILE         ||--o{ WORKFORCE_QUALIFICATION_GOLD       : "enriches identity"

    %% Gold view is a derived analytical output, not a source transaction table
    EMPLOYEE_PROFILE            ||--o{ WORKFORCE_QUALIFICATION_GOLD       : "feeds"
    TRAINING_ITEM_CATALOG       ||--o{ WORKFORCE_QUALIFICATION_GOLD       : "feeds"
    CERTIFICATION_CATALOG       ||--o{ WORKFORCE_QUALIFICATION_GOLD       : "feeds"
    LEARNING_COMPLIANCE_EVENTS  ||--o{ WORKFORCE_QUALIFICATION_GOLD       : "feeds due dates"
```

---

## Notes on Design

**Why REFERENCE_LABEL_LOOKUP connects to multiple tables:**
The source learning platform stores display values as internal label keys. The same lookup table decodes training item titles, certification titles, certification descriptions, and completion status labels. In the SQL, this is handled by joining the same table multiple times using separate aliases.

**Why HRIS_WORKER_PROFILE is separate from EMPLOYEE_PROFILE:**
The learning platform employee profile provides assignment-relevant attributes like site code and job title. HRIS enriches the final output with employee and manager display names only; it is not treated as the source of assignment, completion, or compliance truth. In this anonymized model, both sources use the same masked `employee_id`. If a production environment uses separate LMS and HRIS identifiers, a governed bridge table should be documented explicitly.

**Why LEARNING_COMPLIANCE_EVENTS is included:**
The learning platform stores finalized due-date context for assignments in a separate compliance event stream. Assignments generate or own many compliance events over time; the event stream does not own the assignment. The pipeline uses the latest relevant event context when available so renewal and due-date logic remains aligned with LMS behavior.

**Why CERTIFICATION_TRAINING_MAP exists:**
Certifications are composed of required training items. `CERTIFICATION_TRAINING_MAP` defines which training item, by composite identity (`training_item_type`, `training_item_id`, `revision_date`), is required for each certification and carries certification-training renewal interval rules.

**Why WORKFORCE_QUALIFICATION_GOLD is shown:**
The gold table is included to show analytical lineage. It is a curated reporting output produced after unioning assignments, decoding labels, applying due-date logic, enriching HRIS names, and deduplicating to the current analytical record.
