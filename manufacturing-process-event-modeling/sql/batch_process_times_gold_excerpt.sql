/*
================================================================================
Project:  Manufacturing Process Event Time Extraction Pipeline
File:     batch_process_times_gold_excerpt.sql

Purpose:
  Condensed and anonymized excerpt showing how raw manufacturing automation
  events are mapped into batch-level process milestones for cycle time
  analytics, bottleneck analysis, and operational dashboards.

  The full production query covers many more process sections and milestone
  columns. This excerpt shows three representative sections to demonstrate
  the complete transformation pattern.

Transformation approach:
  - MIN(CASE WHEN ...) extracts start events (earliest qualifying timestamp)
  - MAX(CASE WHEN ...) extracts end events (latest qualifying timestamp)
  - Alternate action path conditions handle process version changes
  - String functions parse values embedded in event description text
  - Batch ID normalization separates double-lot campaign records before grouping

Note:
  All table names, batch IDs, event descriptions, action paths, equipment
  unit identifiers, and process-specific terminology have been anonymized.
  This file is a portfolio excerpt intended to illustrate the engineering
  pattern, not to be executed against a production system.
================================================================================
*/

DECLARE @start_time DATETIME = '2026-01-01';

WITH normalized_events AS (

    /*
    Batch ID normalization note:
    The automation system tracks double-lot or multi-path batches under a
    shared campaign ID. This CTE rewrites batch IDs into A and B lot variants
    before grouping, so each lot can be analyzed independently.

    Three rewrite rules are applied in order of specificity:
      1. Campaign batch + action path suffix :1-2  → tag as B lot
      2. Campaign batch + action path suffix :1-1  → tag as A lot
      3. A lot ID with specific inter-lot transition prompts → remap to B lot
         to prevent those prompts from contaminating the A lot milestones
    */
    SELECT
        CASE
            WHEN batch_id LIKE 'BATCH_CAMPAIGN_%'
             AND action_path LIKE '%:1-2\%'
                THEN LEFT(batch_id, 8) + 'B' + RIGHT(batch_id, 3)

            WHEN batch_id LIKE 'BATCH_CAMPAIGN_%'
             AND action_path LIKE '%:1-1\%'
                THEN LEFT(batch_id, 8) + 'A' + RIGHT(batch_id, 3)

            WHEN batch_id LIKE 'BATCH_A_%'
             AND action_path LIKE '%PROCESS_FP_HARVEST%'
             AND (
                    event_description LIKE 'PROMPT_INTER_LOT_RINSE_SELECT%'
                 OR event_description LIKE 'PROMPT_PLATFORM_CLEAR_BEFORE_CLOSE%'
             )
                THEN LEFT(batch_id, 8) + 'B' + RIGHT(batch_id, 3)

            ELSE batch_id
        END AS batch_id,
        event_time,
        event_description,
        action_path,
        equipment_unit

    FROM source.manufacturing_event_log

    WHERE event_time >= @start_time
      AND RIGHT(action_path, 2) LIKE '[1-9]\'
      AND LEFT(equipment_unit, 4) <> 'NULL'

    /*
    CIP cross-batch linkage note:
    Clean-in-place operations are often run under a separate CIP batch ID.
    In the full production query, a derived subquery joins CIP batch IDs back
    to their parent process batch using a report field that embeds the
    associated batch ID in the event description text.

    This allows CIP timing milestones to appear on the correct process batch
    row even though they were recorded under a different batch context.
    */
),

raw_events AS (
    SELECT * FROM normalized_events
)

SELECT
    re.batch_id,

    /*
    ============================================================
    BATCH-LEVEL START AND PROCESS UNIT IDENTIFICATION
    ============================================================
    */

    /*
    Process start:
    The earliest qualifying automation event that represents the beginning
    of the process across multiple valid equipment paths. Multiple OR
    conditions handle different equipment configurations or process versions
    that generate logically equivalent start events.
    */
    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND (
                re.action_path LIKE '%PROCESS_INIT_PATH_A%'
             OR re.action_path LIKE '%PROCESS_INIT_PATH_B%'
             OR re.action_path LIKE '%PROCESS_INIT_PATH_C%'
         )
        THEN re.event_time
        WHEN re.event_description LIKE 'PROMPT_LOT_VERIFY%'
         AND re.action_path LIKE '%PROCESS_INIT_ALTERNATE%'
        THEN re.event_time
    END) AS process_start_time,

    /*
    Process unit:
    The equipment unit associated with the earliest valid process-start event.
    */
    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND (
                re.action_path LIKE '%PROCESS_INIT_PATH_A%'
             OR re.action_path LIKE '%PROCESS_INIT_PATH_B%'
         )
        THEN re.equipment_unit
    END) AS process_unit,

    /*
    Batch volume:
    Volume is not stored as a discrete column in the source system. It is
    parsed from a formatted report event description using string functions.
    The CHARINDEX locates the volume value by finding a known delimiter,
    and SUBSTRING extracts the numeric portion.
    */
    MIN(CASE
        WHEN re.event_description LIKE 'REPORT_BATCH_VOLUME%'
         AND (
                re.action_path LIKE '%VOLUME_ENTRY_PATH_A%'
             OR re.action_path LIKE '%VOLUME_ENTRY_PATH_B%'
         )
        THEN TRY_CAST(
            SUBSTRING(
                re.event_description,
                CHARINDEX(' ', re.event_description, 1) + 1,
                CHARINDEX(' UNITS ', re.event_description, 1)
                    - CHARINDEX(' ', re.event_description, 1) - 1
            ) AS DECIMAL(18,2)
        )
    END) AS batch_volume_liters,

    /*
    ============================================================
    STAGE A: THAW / RECEIVE PROCESS
    Covers: CIP setup, process initialization, material receive,
    thaw filling, transfer, and post-rinse milestones.
    ============================================================
    */

    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND re.action_path LIKE '%STAGE_A_CIP_SKID_SELECT%'
        THEN re.event_time
    END) AS stage_a_cip_init_start,

    MAX(CASE
        WHEN re.event_description LIKE 'PROMPT_BEGIN_CIP%'
         AND re.action_path LIKE '%STAGE_A_CIP_INIT%'
        THEN re.event_time
    END) AS stage_a_cip_cycle_start,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND re.action_path LIKE '%STAGE_A_CIP_CYCLE%'
        THEN re.event_time
    END) AS stage_a_cip_cycle_end,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND re.action_path LIKE '%STAGE_A_CIP_RELEASE%'
        THEN re.event_time
    END) AS stage_a_cip_release_end,

    /*
    Process start:
    The first qualifying event that marks the beginning of Stage A. Alternate
    action paths handle equipment configurations that route through different
    control paths for the same logical step.
    */
    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND (
                re.action_path LIKE '%STAGE_A_PROCESS_PRIMARY%'
             OR re.action_path LIKE '%STAGE_A_PROCESS_ALTERNATE%'
         )
        THEN re.event_time
        WHEN re.event_description LIKE 'PROMPT_LOT_VERIFY_ENTRY%'
         AND re.action_path LIKE '%STAGE_A_INIT_VARIANT%'
        THEN re.event_time
    END) AS stage_a_process_start,

    MAX(CASE
        WHEN (
                re.event_description LIKE 'PROMPT_STAGE_A_INIT_CONFIRM%'
             OR re.event_description LIKE 'STATE_COMPLETE%'
             )
         AND (
                re.action_path LIKE '%STAGE_A_INIT_PRIMARY%'
             OR re.action_path LIKE '%STAGE_A_INIT_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_a_init_end,

    /*
    Thaw fill start:
    Only present for primary lot types. Identifies the moment when
    the process transitions from initialization to active filling.
    */
    MIN(CASE
        WHEN re.event_description LIKE 'PROMPT_STAGE_A_FILL_READY%'
         AND re.action_path LIKE '%STAGE_A_INIT_PRIMARY%'
        THEN re.event_time
    END) AS stage_a_fill_start,

    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND re.action_path LIKE '%STAGE_A_RECEIVE_INIT%'
        THEN re.event_time
    END) AS stage_a_fill_end,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND re.action_path LIKE '%STAGE_A_POST_RINSE%'
        THEN re.event_time
    END) AS stage_a_transfer_end,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND re.action_path LIKE '%STAGE_A_POST_RINSE%'
        THEN re.event_time
    END) AS stage_a_post_rinse_end,

    /*
    ============================================================
    STAGE B: PRECIPITATION / pH ADJUSTMENT PROCESS
    Covers: CIP setup, receive, pH initialization, buffer addition,
    hold time, parameter capture, aging calculation, and send.
    ============================================================
    */

    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND (
                re.action_path LIKE '%STAGE_B_CIP_SELECT_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_CIP_SELECT_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_cip_init_start,

    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND (
                re.action_path LIKE '%STAGE_B_CIP_SELECT_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_CIP_SELECT_ALTERNATE%'
         )
        THEN re.equipment_unit
    END) AS stage_b_cip_unit,

    MAX(CASE
        WHEN re.event_description LIKE 'PROMPT_BEGIN_CIP%'
         AND (
                re.action_path LIKE '%STAGE_B_CIP_INIT_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_CIP_INIT_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_cip_cycle_start,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND (
                re.action_path LIKE '%STAGE_B_CIP_CYCLE_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_CIP_CYCLE_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_cip_cycle_end,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND (
                re.action_path LIKE '%STAGE_B_CIP_RELEASE_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_CIP_RELEASE_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_cip_release_end,

    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND (
                re.action_path LIKE '%STAGE_B_RECEIVE_INIT_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_RECEIVE_INIT_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_process_start,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND (
                re.action_path LIKE '%STAGE_B_RECEIVE_INIT_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_RECEIVE_INIT_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_receive_end,

    /*
    Process parameter extraction:
    Some process configurations capture the recipe variant as an integer
    embedded in the event description. SUBSTRING extracts it for downstream
    filtering and analytics segmentation.
    */
    MAX(CASE
        WHEN re.event_description LIKE 'PROMPT_SELECT_RECIPE_VARIANT%'
         AND (
                re.action_path LIKE '%STAGE_B_PH_INIT_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_PH_INIT_ALTERNATE%'
         )
        THEN SUBSTRING(re.event_description, 96, 2)
    END) AS stage_b_recipe_variant,

    MAX(CASE
        WHEN re.event_description LIKE 'PROMPT_STAGE_B_PH_SAMPLE_CONFIRM%'
         AND (
                re.action_path LIKE '%STAGE_B_PH_PROMPTS_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_PH_PROMPTS_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_ph_init_start,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND (
                re.action_path LIKE '%STAGE_B_PH_INIT_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_PH_INIT_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_ph_init_end,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND (
                re.action_path LIKE '%STAGE_B_BUFFER_ADD_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_BUFFER_ADD_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_buffer_add_end,

    /*
    Aging end calculation:
    The aging hold duration is not recorded as a completion event. Instead,
    it is calculated from the buffer addition completion timestamp plus the
    configured hold period. The hold duration changed at a known date;
    a date-based condition selects the correct interval for each batch.
    */
    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND (
                re.action_path LIKE '%STAGE_B_BUFFER_ADD_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_BUFFER_ADD_ALTERNATE%'
         )
        THEN
            CASE
                WHEN re.event_time > '2024-12-04'
                    THEN DATEADD(MINUTE, 120, re.event_time)
                ELSE
                    DATEADD(MINUTE, 300, re.event_time)
            END
    END) AS stage_b_aging_end,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND (
                re.action_path LIKE '%STAGE_B_SEND_PRIMARY%'
             OR re.action_path LIKE '%STAGE_B_SEND_ALTERNATE%'
         )
        THEN re.event_time
    END) AS stage_b_send_end,

    /*
    ============================================================
    STAGE C: SEPARATION / CENTRIFUGATION PROCESS
    Covers: equipment preparation, CIP, centrifuge initialization,
    pre-cool, centrifugation, deceleration, harvest, and weighing.
    ============================================================
    */

    /*
    Load clean start:
    Equipment preparation timing is sometimes recorded as a structured
    report event with the timestamp embedded inside the event description
    text. TRY_CONVERT extracts the datetime from the known substring offset.
    */
    MIN(CASE
        WHEN re.event_description LIKE 'REPORT_LOAD_CLEAN_START%'
         AND LEN(re.event_description) >= 33
         AND re.action_path LIKE '%STAGE_C_REASSEMBLY%'
        THEN TRY_CONVERT(DATETIME, SUBSTRING(re.event_description, 17, 16))
    END) AS stage_c_load_clean_start,

    MAX(CASE
        WHEN re.event_description LIKE 'REPORT_LOAD_CLEAN_END%'
         AND LEN(re.event_description) >= 33
         AND re.action_path LIKE '%STAGE_C_REASSEMBLY%'
        THEN TRY_CONVERT(DATETIME, SUBSTRING(re.event_description, 17, 16))
    END) AS stage_c_load_clean_end,

    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND re.action_path LIKE '%STAGE_C_CIP_SKID_SELECT%'
        THEN re.event_time
    END) AS stage_c_cip_init_start,

    MIN(CASE
        WHEN re.event_description LIKE 'PROMPT_BEGIN_CIP%'
         AND re.action_path LIKE '%STAGE_C_CIP_INIT%'
        THEN re.event_time
    END) AS stage_c_cip_cycle_start,

    MIN(CASE
        WHEN re.event_description LIKE 'PROMPT_CIP_RELEASE_CONFIRM%'
         AND re.action_path LIKE '%STAGE_C_CIP_RELEASE%'
        THEN re.event_time
    END) AS stage_c_cip_cycle_end,

    MIN(CASE
        WHEN re.event_description LIKE 'PROMPT_REASSEMBLY_INSPECT%'
         AND re.action_path LIKE '%STAGE_C_REASSEMBLY%'
        THEN re.event_time
    END) AS stage_c_cip_reassembly_start,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND re.action_path LIKE '%STAGE_C_REASSEMBLY%'
        THEN re.event_time
    END) AS stage_c_cip_reassembly_end,

    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND re.action_path LIKE '%STAGE_C_CENT_INIT%'
        THEN re.event_time
    END) AS stage_c_separation_start,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND re.action_path LIKE '%STAGE_C_CENT_INIT%'
        THEN re.event_time
    END) AS stage_c_init_end,

    MIN(CASE
        WHEN re.event_description LIKE 'STATE_RUNNING%'
         AND re.action_path LIKE '%STAGE_C_CENTRIFUGATION%'
        THEN re.event_time
    END) AS stage_c_precool_end,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND re.action_path LIKE '%STAGE_C_CENTRIFUGATION%'
        THEN re.event_time
    END) AS stage_c_centrifugation_end,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND re.action_path LIKE '%STAGE_C_DECEL%'
        THEN re.event_time
    END) AS stage_c_decel_end,

    MIN(CASE
        WHEN re.event_description LIKE 'PROMPT_LOCKOUT_CONFIRM_BEFORE_HARVEST%'
         AND re.action_path LIKE '%STAGE_C_HARVEST%'
        THEN re.event_time
    END) AS stage_c_harvest_start,

    MAX(CASE
        WHEN (
                re.event_description LIKE 'PROMPT_DRAIN_CONNECTION_CONFIRM_A%'
             OR re.event_description LIKE 'PROMPT_DRAIN_CONNECTION_CONFIRM_B%'
             )
         AND re.action_path LIKE '%STAGE_C_HARVEST%'
        THEN re.event_time
    END) AS stage_c_harvest_end,

    MAX(CASE
        WHEN re.event_description LIKE 'STATE_COMPLETE%'
         AND re.action_path LIKE '%STAGE_C_HARVEST%'
        THEN re.event_time
    END) AS stage_c_weighing_end,

    /*
    ============================================================
    Additional process sections follow the same event-mapping pattern.
    Each section extracts milestones for:
      - Additional precipitation stages (D, E, F)
      - Downstream separation stages with filter press equipment
      - Suspension and transfer steps
      - Polishing and final process stages
      - Final send and closeout milestones
    These are abbreviated here to keep the portfolio excerpt readable.
    The full pipeline covers dozens of additional milestone columns
    across the complete manufacturing process sequence.
    ============================================================
    */

    COUNT(*) AS raw_event_count

FROM raw_events re

GROUP BY
    re.batch_id;
