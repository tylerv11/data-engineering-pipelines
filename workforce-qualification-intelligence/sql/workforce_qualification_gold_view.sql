/*
================================================================================
Project:  Workforce Qualification Intelligence Platform
File:     workforce_qualification_gold_view.sql

Purpose:
  Creates a curated gold-layer view for workforce qualification and training
  compliance analytics.

  This query combines employee training assignments, certification-linked
  training assignments, training catalog metadata, certification metadata,
  completion status references, label lookup tables, and HR hierarchy data
  into a single reporting-ready dataset.

The final output supports:
  - Qualification status reporting
  - Overdue training monitoring
  - Renewal-based certification tracking
  - Assignment source attribution
  - Manager-level compliance visibility
  - Semantic model consumption (Power BI or equivalent)

Note:
  All table names, column names, system names, and business identifiers have
  been anonymized for portfolio use. Engineering logic and transformation design
  are original work.
================================================================================
*/

CREATE OR REPLACE VIEW analytics.workforce_qualification_gold AS

WITH assignment_union AS (

    /*
    Data modeling note:
    The learning platform stores standalone training assignments and
    certification-linked training assignments in separate source tables with
    slightly different schemas.

    This CTE normalizes both assignment types into a single structure so all
    downstream compliance logic can apply consistently regardless of assignment
    origin.
    */

    SELECT
        employee_id,
        NULL            AS certification_id,
        training_item_type,
        training_item_id,
        revision_date,
        assigned_by_type,
        assigned_by_user,
        NULL            AS renewal_interval,
        assigned_at,
        due_at,
        completion_status_id,
        completed_at,
        updated_at,
        assignment_type,
        NULL            AS root_certification_id
    FROM raw.employee_training_assignment

    UNION ALL

    SELECT
        employee_id,
        certification_id,
        training_item_type,
        training_item_id,
        revision_date,
        assigned_by_type,
        assigned_by_user,
        renewal_interval,
        assigned_at,
        due_at,
        completion_status_id,
        completed_at,
        updated_at,
        assignment_type,
        root_certification_id
    FROM raw.employee_certification_assignment

    /*
    Data quality note:
    Certification assignments are filtered to active records before they enter
    the broader model.

    The source system retains inactive historical rows for audit purposes, but
    those rows must not contribute to current overdue counts or manager-facing
    qualification reporting. Applying this filter at the source CTE prevents
    inactive records from affecting downstream joins, due-date calculations, and
    compliance status derivations.
    */
    WHERE active_flag = 'Y'
),

base_training AS (

    /*
    Transformation note:
    This CTE enriches normalized assignment records with employee profile data,
    training item metadata, certification metadata, completion status labels,
    and readable display values.

    The output of this step is the main row-level training record before
    compliance status and renewal logic are derived.
    */

    SELECT
        au.employee_id,
        ep.site_code,
        ep.job_title,

        /* Training item metadata */
        au.training_item_type,
        au.training_item_id,
        tic.revision_number,
        TRY_CAST(tic.revision_number AS DOUBLE) AS revision_number_numeric,
        au.revision_date,
        item_label.label_value               AS training_item_title,

        /* Certification metadata */
        au.certification_id,
        cc.certification_title_key,
        COALESCE(cert_title.label_value, 'Missing') AS certification_title,
        COALESCE(cert_desc.label_value,  'Missing') AS certification_description,

        /* Assignment and completion timing */
        au.assigned_at,

        /*
        Business rule:
        If the assignment is not completed, use the due date from the assignment
        record. If the assignment is completed, use the due date from the
        compliance events table when available, because it reflects the source
        system's finalized completion context.
        */
        CASE
            WHEN au.completed_at IS NULL THEN au.due_at
            ELSE compliance.due_at
        END AS training_due_at,

        au.completed_at,
        status_label.label_value AS completion_status,

        /*
        Governance note:
        Assignment source fields are retained in the curated model so operational
        teams can separate system-assigned, manager-assigned, admin-assigned, and
        self-assigned training in downstream reporting.
        */
        au.assigned_by_type,
        au.assigned_by_user,
        au.updated_at,

        /*
        Business rule:
        Raw assignment source codes are decoded into readable category labels.
        This avoids requiring report consumers to interpret internal system codes
        and makes dashboard filters self-explanatory.
        */
        CASE
            WHEN au.assigned_by_type = 'SYSTEM'
                 AND au.assigned_by_user = 'CONNECTOR'
                THEN 'Connector'

            WHEN au.assigned_by_type = 'SYSTEM'
                 AND au.assigned_by_user = 'ASSIGNMENT_PROFILE'
                THEN 'Assignment Profile'

            WHEN au.assigned_by_type = 'MANAGER'
                 AND INSTR(au.assigned_by_user, ',') = 0
                THEN CONCAT('Manager: ', au.assigned_by_user)

            WHEN au.assigned_by_type = 'MANAGER'
                 AND INSTR(au.assigned_by_user, ',') > 0
                THEN CONCAT('Manager: ', SUBSTRING(au.assigned_by_user, 1, INSTR(au.assigned_by_user, ',') - 1))

            WHEN au.assigned_by_type = 'ADMIN'
                 AND INSTR(au.assigned_by_user, ',') = 0
                THEN CONCAT('Admin: ', au.assigned_by_user)

            WHEN au.assigned_by_type = 'ADMIN'
                 AND INSTR(au.assigned_by_user, ',') > 0
                THEN CONCAT('Admin: ', SUBSTRING(au.assigned_by_user, 1, INSTR(au.assigned_by_user, ',') - 1))

            WHEN au.assigned_by_type = 'USER'
                 AND INSTR(au.assigned_by_user, ',') = 0
                THEN CONCAT('User: ', au.assigned_by_user)

            WHEN au.assigned_by_type = 'USER'
                 AND INSTR(au.assigned_by_user, ',') > 0
                THEN CONCAT('User: ', SUBSTRING(au.assigned_by_user, 1, INSTR(au.assigned_by_user, ',') - 1))

            ELSE 'Assigned - Unknown Source'
        END AS assignment_method,

        /*
        Reporting note:
        A simplified assignment method group is included for slicing, filtering,
        and KPI aggregation in the semantic model without needing to parse the
        full readable label.
        */
        CASE
            WHEN au.assigned_by_type = 'SYSTEM'
                 AND au.assigned_by_user = 'CONNECTOR'       THEN 'CONNECTOR'
            WHEN au.assigned_by_type = 'SYSTEM'
                 AND au.assigned_by_user = 'ASSIGNMENT_PROFILE' THEN 'ASSIGNMENT_PROFILE'
            WHEN au.assigned_by_type = 'MANAGER'             THEN 'MANAGER'
            WHEN au.assigned_by_type = 'ADMIN'               THEN 'ADMIN'
            WHEN au.assigned_by_type = 'USER'                THEN 'USER'
            ELSE 'UNKNOWN'
        END AS assignment_method_group,

        /*
        Business rule:
        Renewal interval is used in the next CTE to calculate certification
        renewal due dates. It is sourced from the certification training map
        because renewal logic is configured at the certification item level,
        not at the individual assignment level.
        */
        ctm.renewal_interval,

        /*
        Reporting note:
        Custom employee attributes are included to support optional reporting
        dimensions such as department, function, employee group, or site-specific
        classification. Attribute numbers correspond to configurable slots in the
        source learning platform.
        */
        attr10.attribute_value AS employee_attribute_10,
        attr20.attribute_value AS employee_attribute_20,
        attr30.attribute_value AS employee_attribute_30,
        attr40.attribute_value AS employee_attribute_40,
        attr50.attribute_value AS employee_attribute_50,
        attr60.attribute_value AS employee_attribute_60,
        attr70.attribute_value AS employee_attribute_70

    FROM assignment_union au

    /*
    Governance note:
    Only non-sensitive reporting attributes are selected from the learning
    platform employee profile. Employee and manager display names are enriched
    later from the governed HRIS reference source.
    */
    INNER JOIN raw.employee_profile ep
        ON au.employee_id = ep.employee_id

    INNER JOIN raw.training_item_catalog tic
        ON  au.training_item_type = tic.training_item_type
        AND au.training_item_id   = tic.training_item_id
        AND au.revision_date      = tic.revision_date

    LEFT JOIN raw.learning_compliance_events compliance
        ON  au.employee_id          = compliance.employee_id
        AND au.training_item_type   = compliance.training_item_type
        AND au.training_item_id     = compliance.training_item_id
        AND au.revision_date        = compliance.revision_date
        AND au.assignment_type      = compliance.assignment_type
        AND au.assigned_at          = compliance.assigned_at
        AND au.completed_at         = compliance.completed_at
        AND au.completion_status_id = compliance.completion_status_id

    LEFT JOIN raw.certification_catalog cc
        ON au.certification_id = cc.certification_id

    LEFT JOIN raw.certification_training_map ctm
        ON  au.certification_id   = ctm.certification_id
        AND au.training_item_type = ctm.training_item_type
        AND au.training_item_id   = ctm.training_item_id
        AND au.revision_date      = ctm.revision_date

    LEFT JOIN raw.training_completion_status tcs
        ON au.completion_status_id = tcs.completion_status_id

    /*
    Label decoding note:
    The learning platform stores display values as internal label keys rather
    than readable strings. The reference label table is joined multiple times
    using separate aliases to decode training item titles, certification titles,
    certification descriptions, and completion status labels independently.
    */
    LEFT JOIN raw.reference_label_lookup item_label
        ON  tic.training_title_key = item_label.label_id
        AND item_label.locale      = 'English'

    LEFT JOIN raw.reference_label_lookup status_label
        ON  tcs.completion_status_key = status_label.label_id
        AND status_label.locale       = 'English'

    LEFT JOIN raw.reference_label_lookup cert_title
        ON  cc.certification_title_key = cert_title.label_id
        AND cert_title.locale          = 'English'

    LEFT JOIN raw.reference_label_lookup cert_desc
        ON  cc.certification_description_key = cert_desc.label_id
        AND cert_desc.locale                 = 'English'

    /*
    Performance note:
    Custom employee attributes are stored as numbered rows rather than named
    columns in the source system. Each attribute number requires a separate
    filtered join to pivot the data into a columnar structure.
    */
    LEFT JOIN raw.employee_custom_attribute attr10
        ON ep.employee_id = attr10.employee_id AND attr10.attribute_number = 10
    LEFT JOIN raw.employee_custom_attribute attr20
        ON ep.employee_id = attr20.employee_id AND attr20.attribute_number = 20
    LEFT JOIN raw.employee_custom_attribute attr30
        ON ep.employee_id = attr30.employee_id AND attr30.attribute_number = 30
    LEFT JOIN raw.employee_custom_attribute attr40
        ON ep.employee_id = attr40.employee_id AND attr40.attribute_number = 40
    LEFT JOIN raw.employee_custom_attribute attr50
        ON ep.employee_id = attr50.employee_id AND attr50.attribute_number = 50
    LEFT JOIN raw.employee_custom_attribute attr60
        ON ep.employee_id = attr60.employee_id AND attr60.attribute_number = 60
    LEFT JOIN raw.employee_custom_attribute attr70
        ON ep.employee_id = attr70.employee_id AND attr70.attribute_number = 70

    /*
    Reporting scope note:
    User self-assigned training is excluded so the model focuses on
    operationally assigned qualifications. Self-assigned training does not
    carry compliance obligations and would distort overdue and qualification
    metrics if included.
    */
    WHERE au.assigned_by_type <> 'USER'
),

status_enrichment AS (

    /*
    Business logic note:
    This CTE calculates renewal due dates and derives a source-style compliance
    status from due and completion dates.

    The source-style status creates a stable baseline that the next CTE uses to
    differentiate between one-time and renewal-based training when producing the
    final normalized qualification statuses.
    */

    SELECT
        bt.*,

        /*
        Renewal date logic:
        The renewal due date is calculated by adding the configured renewal
        interval to the employee's completion date.

        The source system may store renewal intervals in mixed formats:
          - Values below 10 are interpreted as years and converted to days.
          - Values of 10 or greater are interpreted as days directly.

        This allows the model to handle both formats without requiring upstream
        data standardization.

        Examples:
          - renewal_interval = 1 → 365 days
          - renewal_interval = 2 → 730 days
          - renewal_interval = 365 → 365 days
          - renewal_interval = 730 → 730 days
        */
        CASE
            WHEN bt.completed_at IS NULL
                THEN NULL

            WHEN TRY_CAST(bt.renewal_interval AS DOUBLE) IS NULL
              OR TRY_CAST(bt.renewal_interval AS DOUBLE) <= 0
                THEN NULL

            ELSE DATE_ADD(
                bt.completed_at,
                CASE
                    WHEN TRY_CAST(bt.renewal_interval AS DOUBLE) < 10
                        THEN CAST(ROUND(TRY_CAST(bt.renewal_interval AS DOUBLE) * 365) AS INT)
                    ELSE
                        CAST(ROUND(TRY_CAST(bt.renewal_interval AS DOUBLE)) AS INT)
                END
            )
        END AS renewal_due_at,

        /*
        Source-style compliance status:
        This status mirrors the logic the source system would apply based on
        assignment due dates and completion dates.

        It is computed before the final normalized status so the two branches
        (one-time training vs. renewal-based training) can be evaluated cleanly
        in the next CTE without circular logic.
        */
        CASE
            WHEN bt.training_due_at IS NULL
             AND bt.completed_at IS NULL                           THEN 'Assigned'

            WHEN bt.training_due_at > CURRENT_TIMESTAMP
             AND bt.completed_at IS NULL                           THEN 'Assigned'

            WHEN bt.training_due_at IS NULL
             AND bt.completed_at IS NOT NULL                       THEN 'Completed on time'

            WHEN bt.completed_at IS NOT NULL
             AND bt.completed_at > bt.training_due_at              THEN 'Completed Late'

            WHEN bt.completed_at IS NOT NULL
             AND bt.completed_at <= bt.training_due_at             THEN 'Completed on time'

            WHEN bt.completed_at IS NULL
             AND CURRENT_TIMESTAMP > bt.training_due_at            THEN 'Overdue'

            ELSE 'Unknown'
        END AS source_system_compliance_status

    FROM base_training bt
),

final_status AS (

    /*
    Transformation note:
    This CTE produces the dashboard-ready compliance status, due-date display
    field, days-until-due metric, and record deduplication rank.

    The goal is one current, reportable row per employee, certification, and
    training item with all derived fields ready for semantic model consumption.
    */

    SELECT
        se.*,

        DATE_FORMAT(se.renewal_due_at, 'MMM dd, yyyy, hh:mm a') AS renewal_due_display,

        /*
        Days until due:
        Calculated differently depending on training type.

          - Renewal-based training ages against renewal_due_at, with fallback to
            training_due_at when no completion exists yet.
          - Completed one-time training returns NULL because no future due date
            exists.
          - Incomplete one-time training ages against training_due_at.
          - Negative values indicate overdue records.
        */
        CASE
            WHEN TRY_CAST(se.renewal_interval AS DOUBLE) IS NOT NULL
             AND TRY_CAST(se.renewal_interval AS DOUBLE) > 0
                THEN DATEDIFF(COALESCE(se.renewal_due_at, se.training_due_at), CURRENT_DATE())

            WHEN (
                    TRY_CAST(se.renewal_interval AS DOUBLE) IS NULL
                    OR TRY_CAST(se.renewal_interval AS DOUBLE) <= 0
                 )
             AND se.source_system_compliance_status IN ('Completed on time', 'Completed Late')
                THEN NULL

            WHEN (
                    TRY_CAST(se.renewal_interval AS DOUBLE) IS NULL
                    OR TRY_CAST(se.renewal_interval AS DOUBLE) <= 0
                 )
             AND se.training_due_at IS NOT NULL
                THEN DATEDIFF(se.training_due_at, CURRENT_DATE())

            ELSE NULL
        END AS days_until_due,

        /*
        Normalized compliance status:
        The source system status is converted into business-friendly reporting
        categories used across all dashboards and KPIs.

        Renewal-based training uses renewal_due_at to determine qualification
        state. One-time training uses the source-style completion status.

        Categories:
          Qualified                     - Current, no action needed
          Qualified - Renewal Due Soon  - Current but renewal within 90 days
          Assigned - Not Yet Qualified  - Assigned but not yet completed
          Overdue                       - Past due with no completion
          Renewal Overdue               - Renewal window has elapsed
        */
        CASE
            WHEN TRY_CAST(se.renewal_interval AS DOUBLE) IS NOT NULL
             AND TRY_CAST(se.renewal_interval AS DOUBLE) > 0
             AND se.completed_at IS NOT NULL
             AND se.renewal_due_at IS NOT NULL
                THEN
                    CASE
                        WHEN CURRENT_DATE() > se.renewal_due_at
                            THEN 'Renewal Overdue'
                        WHEN CURRENT_DATE() >= DATE_SUB(se.renewal_due_at, 90)
                            THEN 'Qualified - Renewal Due Soon'
                        ELSE 'Qualified'
                    END

            ELSE
                CASE
                    WHEN se.source_system_compliance_status IN ('Completed on time', 'Completed Late')
                        THEN 'Qualified'
                    WHEN se.source_system_compliance_status = 'Assigned'
                        THEN 'Assigned - Not Yet Qualified'
                    WHEN se.source_system_compliance_status = 'Overdue'
                        THEN 'Overdue'
                    ELSE NULL
                END
        END AS normalized_compliance_status,

        /*
        Due-date display logic:
        This field is designed for dashboard card and table visuals where showing
        a due date only makes sense when action is needed.

          - Qualified one-time training returns NULL because no action is required.
          - Renewal-based training shows the renewal date when due soon or overdue,
            and returns NULL when the employee is fully qualified with time remaining.
          - All other states show the applicable due date.
        */
        CASE
            WHEN TRY_CAST(se.renewal_interval AS DOUBLE) IS NOT NULL
             AND TRY_CAST(se.renewal_interval AS DOUBLE) > 0
                THEN
                    CASE
                        WHEN CURRENT_DATE() > se.renewal_due_at
                            THEN COALESCE(se.renewal_due_at, se.training_due_at)
                        WHEN CURRENT_DATE() >= DATE_SUB(se.renewal_due_at, 90)
                            THEN se.renewal_due_at
                        ELSE NULL
                    END

            ELSE
                CASE
                    WHEN se.source_system_compliance_status IN ('Completed on time', 'Completed Late')
                        THEN NULL
                    ELSE se.training_due_at
                END
        END AS assignment_due_date_display,

        /*
        Deduplication note:
        Source data may contain multiple rows per employee, certification, and
        training item due to revisions, historical updates, or audit records.

        ROW_NUMBER() keeps the single most current row by prioritizing:
          1. Highest revision number
          2. Latest revision date
          3. Latest source update timestamp

        COALESCE guards against NULL values in the ordering columns to prevent
        those rows from being incorrectly ranked first.
        */
        ROW_NUMBER() OVER (
            PARTITION BY
                se.employee_id,
                se.certification_id,
                se.training_item_id
            ORDER BY
                COALESCE(se.revision_number_numeric,                    -1.0) DESC,
                COALESCE(se.revision_date,   TIMESTAMP '1900-01-01 00:00:00') DESC,
                COALESCE(se.updated_at,      TIMESTAMP '1900-01-01 00:00:00') DESC
        ) AS row_num

    FROM status_enrichment se
),

worker_clean AS (

    /*
    Governance note:
    Employee and manager display names are sourced from the HRIS reference table
    rather than the learning platform. This keeps identity and organizational
    hierarchy reporting centralized through the governed HR master data source.

    The learning platform employee profile provides assignment-relevant fields
    but is not the authoritative source for employee identity.
    */

    SELECT
        employee_network_id,

        /*
        Data quality note:
        Display names are cleaned by stripping generic confidentiality and
        leave-status markers that carry no reporting value and would interfere
        with grouping and sorting in dashboards.
        */
        TRIM(REPLACE(REPLACE(employee_name, '[Confidential]', ''), '(On Leave)', '')) AS employee_name,
        TRIM(REPLACE(REPLACE(manager_name,  '[Confidential]', ''), '(On Leave)', '')) AS manager_name,

        /*
        Deduplication note:
        The HRIS reference table may contain multiple records per employee over
        time. Only the latest active record is used for reporting.
        */
        ROW_NUMBER() OVER (
            PARTITION BY employee_network_id
            ORDER BY COALESCE(updated_at, loaded_at) DESC
        ) AS worker_row_num

    FROM raw.hris_worker_profile

    WHERE active_employee_flag = 'Y'
      AND employee_network_id IS NOT NULL
      AND TRIM(employee_network_id) <> ''
      AND employee_name IS NOT NULL
      AND TRIM(employee_name) <> ''
)

SELECT
    fs.employee_id,
    fs.site_code,
    fs.job_title,

    fs.training_item_type,
    fs.training_item_id,
    fs.revision_number,
    fs.revision_number_numeric,
    fs.revision_date,
    fs.training_item_title,

    fs.certification_id,
    fs.certification_title_key,
    fs.certification_title,
    fs.certification_description,

    fs.assigned_at,
    fs.training_due_at,
    fs.completed_at,
    fs.renewal_due_at,
    fs.renewal_due_display,
    fs.assignment_due_date_display,

    fs.completion_status,
    fs.source_system_compliance_status,
    fs.normalized_compliance_status,
    fs.days_until_due,

    fs.assigned_by_type,
    fs.assigned_by_user,
    fs.assignment_method,
    fs.assignment_method_group,

    fs.employee_attribute_10,
    fs.employee_attribute_20,
    fs.employee_attribute_30,
    fs.employee_attribute_40,
    fs.employee_attribute_50,
    fs.employee_attribute_60,
    fs.employee_attribute_70,

    /*
    HR enrichment note:
    Missing values are explicitly labeled so dashboard consumers can distinguish
    between true blanks and records where HRIS enrichment was unavailable.
    */
    COALESCE(wc.employee_name, 'Missing') AS employee_name,
    COALESCE(wc.manager_name,  'Missing') AS manager_name,

    /*
    Reporting helper fields:
    Last-name extractions support compact table visuals, alphabetic sort
    behavior, and manager-level grouping without requiring full name parsing
    in the semantic layer.
    */
    ELEMENT_AT(SPLIT(TRIM(COALESCE(wc.employee_name, 'Missing')), ' '), -1) AS employee_last_name,
    TRIM(SPLIT(COALESCE(wc.manager_name, 'Missing'), ',')[0])               AS manager_last_name

FROM final_status fs

LEFT JOIN worker_clean wc
    ON  wc.employee_network_id = fs.employee_id
    AND wc.worker_row_num      = 1

WHERE fs.row_num = 1

/*
Reporting scope note:
Regional and privacy-based scope controls are applied through a site dimension
filter. In a production environment, this is typically managed through a governed
region, legal entity, or access-control dimension rather than hard-coded
operational identifiers.
*/
  AND fs.site_code NOT LIKE 'REGION_EXCLUDED_%';
