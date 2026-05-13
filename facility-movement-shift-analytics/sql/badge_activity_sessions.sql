/*
================================================================================
Project:  Facility Movement & Shift Presence Analytics
File:     badge_activity_sessions.sql

Purpose:
  Builds a historical view of badge-based activity sessions using any badge
  swipe as an activity signal.

  Each row in the output represents one continuous activity session for one
  employee. The session model answers:
    - How long was someone active on site?
    - Which shift did their activity most closely align with?
    - Did their activity meaningfully overlap with a secondary shift?
    - Does the session look reliable or should it be flagged for data quality?

Key design decisions:
  - Any badge swipe counts as activity, not just facility entry or exit events.
    Employees in controlled environments may badge into internal zones, gowning
    areas, or restricted rooms without clean facility-level entry or exit pairs.
    Using any swipe makes the session model more complete for historical analysis.
  - Sessions are not anchored to calendar dates. Overnight sessions are allowed
    to cross midnight. Grouping by date would incorrectly split night-shift
    sessions at midnight.
  - Session duration is NULL for records flagged as unreliable. Flagged records
    are retained in the output so downstream consumers can filter or analyze them.

Parameters:
  @MaxHistoryStartDate  - how far back to pull badge events
  @SessionGapHours      - inactivity gap that triggers a new session
  @MaxSessionHours      - hard cap; sessions longer than this are flagged
  @MinSessionSeconds    - sessions shorter than this are flagged as noise

Note:
  All table names, column names, door names, and system identifiers have been
  anonymized for portfolio use.
================================================================================
*/

DECLARE @MaxHistoryStartDate date    = DATEADD(MONTH, -3, CAST(GETDATE() AS date));
DECLARE @SessionGapHours     int     = 10;
DECLARE @MaxSessionHours     int     = 15;
DECLARE @MinSessionSeconds   int     = 60;

WITH BaseEvents AS (

    /*
    Governance note:
    Employee IDs are hashed using SHA-256 immediately after trimming and
    uppercasing. This produces a stable, repeatable anonymized key for
    session tracking without retaining raw employee identifiers in any
    downstream CTE or output.

    Records without an employee ID are excluded so guest or unregistered badges
    do not collapse into the empty-string hash and inflate session counts.
    */

    SELECT
        ah.swipe_timestamp,
        ah.card_number,
        ah.door_name,
        CONVERT(
            varchar(64),
            HASHBYTES(
                'SHA2_256',
                UPPER(LTRIM(RTRIM(CAST(ah.employee_id AS varchar(50)))))
            ),
            2
        ) AS anon_employee_key
    FROM raw.badge_access_event ah
    WHERE ah.swipe_timestamp >= @MaxHistoryStartDate
      AND ah.employee_id IS NOT NULL
      AND LTRIM(RTRIM(CAST(ah.employee_id AS varchar(50)))) <> ''
),

SessionGaps AS (

    /*
    Session boundary note:
    LAG() looks back at the prior swipe for the same anonymized employee.
    A new session is flagged when:
      - This is the employee's first swipe in the dataset, or
      - The inactivity gap since the prior swipe exceeds the configured threshold.

    The gap is calculated in minutes to allow sub-hour precision in the threshold
    comparison.
    */

    SELECT
        be.*,
        LAG(be.swipe_timestamp) OVER (
            PARTITION BY be.anon_employee_key
            ORDER BY be.swipe_timestamp
        ) AS prior_swipe_time,

        DATEDIFF(MINUTE,
            LAG(be.swipe_timestamp) OVER (
                PARTITION BY be.anon_employee_key
                ORDER BY be.swipe_timestamp
            ),
            be.swipe_timestamp
        ) AS minutes_since_last_swipe,

        CASE
            WHEN LAG(be.swipe_timestamp) OVER (
                PARTITION BY be.anon_employee_key
                ORDER BY be.swipe_timestamp
            ) IS NULL
                THEN 1
            WHEN DATEDIFF(MINUTE,
                LAG(be.swipe_timestamp) OVER (
                    PARTITION BY be.anon_employee_key
                    ORDER BY be.swipe_timestamp
                ),
                be.swipe_timestamp
            ) >= (@SessionGapHours * 60)
                THEN 1
            ELSE 0
        END AS new_session_flag

    FROM BaseEvents be
),

SessionNumbers AS (

    /*
    Session numbering note:
    Session numbers are assigned by cumulatively summing the new_session_flag
    within each employee partition. This produces a monotonically increasing
    integer that increments each time a new session boundary is detected.
    */

    SELECT
        sg.*,
        SUM(sg.new_session_flag) OVER (
            PARTITION BY sg.anon_employee_key
            ORDER BY sg.swipe_timestamp
            ROWS UNBOUNDED PRECEDING
        ) AS session_number
    FROM SessionGaps sg
),

SessionTagged AS (

    /*
    Session bounds note:
    ROW_NUMBER() is applied twice per session: ascending to identify the first
    swipe and descending to identify the last swipe. These are used in the next
    CTE to extract begin and end context for each session.
    */

    SELECT
        sn.*,
        ROW_NUMBER() OVER (
            PARTITION BY sn.anon_employee_key, sn.session_number
            ORDER BY sn.swipe_timestamp ASC
        ) AS rn_asc,
        ROW_NUMBER() OVER (
            PARTITION BY sn.anon_employee_key, sn.session_number
            ORDER BY sn.swipe_timestamp DESC
        ) AS rn_desc
    FROM SessionNumbers sn
),

SessionSummary AS (

    /*
    Session aggregation note:
    Each session is collapsed to one row per employee and session number.
    Conditional MAX() extracts the begin and end timestamps and door names
    from the first and last swipe rows identified by the row number flags above.
    */

    SELECT
        st.anon_employee_key,
        st.session_number,
        MAX(CASE WHEN st.rn_asc  = 1 THEN st.swipe_timestamp END) AS begin_session_time,
        MAX(CASE WHEN st.rn_asc  = 1 THEN st.door_name END)       AS begin_session_door_name,
        MAX(CASE WHEN st.rn_desc = 1 THEN st.swipe_timestamp END) AS end_session_time,
        MAX(CASE WHEN st.rn_desc = 1 THEN st.door_name END)       AS end_session_door_name,
        COUNT(*) AS swipe_count
    FROM SessionTagged st
    GROUP BY
        st.anon_employee_key,
        st.session_number
),

SessionDurations AS (

    /*
    Data quality note:
    Three flag conditions mark a session as unreliable:

      is_micro_session_flag    - duration below minimum threshold; likely a reader
                                 duplicate or near-simultaneous badge events
      exceeds_max_duration_flag - duration above maximum threshold; likely caused
                                 by stitched days or missing badge events
      data_quality_flag        - composite flag set when any condition applies,
                                 including single-swipe sessions

    When a session is flagged, session_duration_hours is set to NULL so the record
    does not silently distort duration aggregations downstream. The record itself
    is retained so consumers can analyze flagged sessions separately.

    The anchor date is derived from begin_session_time and is used to anchor shift
    window calculations. This avoids grouping by calendar date, which would split
    overnight sessions incorrectly.
    */

    SELECT
        ss.*,
        DATEDIFF(SECOND, ss.begin_session_time, ss.end_session_time)         AS raw_duration_seconds,
        DATEDIFF(SECOND, ss.begin_session_time, ss.end_session_time) / 3600.0 AS raw_session_duration_hours,

        CASE
            WHEN DATEDIFF(SECOND, ss.begin_session_time, ss.end_session_time) < @MinSessionSeconds THEN 1
            ELSE 0
        END AS is_micro_session_flag,

        CASE
            WHEN DATEDIFF(SECOND, ss.begin_session_time, ss.end_session_time) / 3600.0 > @MaxSessionHours THEN 1
            ELSE 0
        END AS exceeds_max_duration_flag,

        CASE
            WHEN DATEDIFF(SECOND, ss.begin_session_time, ss.end_session_time) < @MinSessionSeconds          THEN NULL
            WHEN DATEDIFF(SECOND, ss.begin_session_time, ss.end_session_time) / 3600.0 > @MaxSessionHours   THEN NULL
            ELSE DATEDIFF(SECOND, ss.begin_session_time, ss.end_session_time) / 3600.0
        END AS session_duration_hours,

        CAST(ss.begin_session_time AS date) AS anchor_date

    FROM SessionSummary ss
),

HoursPerShift AS (

    /*
    Shift overlap note:
    Each session is compared against five shift windows using interval
    intersection arithmetic:

      max(0, min(session_end, shift_end) - max(session_start, shift_start))

    This gives the hours the session overlapped with each shift window.
    Sessions with NULL duration are assigned 0 hours for all shifts and will
    not receive a shift classification.

    The ISO weekday is calculated using DATEPART and @@DATEFIRST to produce
    a consistent 1=Monday through 7=Sunday value regardless of server locale.

    Night and weekend-night windows cross midnight. Two candidate windows are
    evaluated for each (the window starting the previous night and the window
    starting the same night), and MAX() selects the larger overlap.
    */

    SELECT
        sd.*,
        ((DATEPART(WEEKDAY, sd.begin_session_time) + @@DATEFIRST - 2) % 7) + 1 AS iso_weekday,

        /* Weekday Day shift: 06:00 to 14:00, Monday through Friday */
        CASE
            WHEN ((DATEPART(WEEKDAY, sd.begin_session_time) + @@DATEFIRST - 2) % 7) + 1 BETWEEN 1 AND 5
             AND sd.session_duration_hours IS NOT NULL
            THEN
                CASE
                    WHEN DATEDIFF(MINUTE,
                        CASE WHEN sd.begin_session_time > DATEADD(HOUR, 6,  CAST(sd.anchor_date AS datetime))
                             THEN sd.begin_session_time ELSE DATEADD(HOUR, 6,  CAST(sd.anchor_date AS datetime)) END,
                        CASE WHEN sd.end_session_time   < DATEADD(HOUR, 14, CAST(sd.anchor_date AS datetime))
                             THEN sd.end_session_time   ELSE DATEADD(HOUR, 14, CAST(sd.anchor_date AS datetime)) END
                    ) <= 0 THEN 0
                    ELSE DATEDIFF(MINUTE,
                        CASE WHEN sd.begin_session_time > DATEADD(HOUR, 6,  CAST(sd.anchor_date AS datetime))
                             THEN sd.begin_session_time ELSE DATEADD(HOUR, 6,  CAST(sd.anchor_date AS datetime)) END,
                        CASE WHEN sd.end_session_time   < DATEADD(HOUR, 14, CAST(sd.anchor_date AS datetime))
                             THEN sd.end_session_time   ELSE DATEADD(HOUR, 14, CAST(sd.anchor_date AS datetime)) END
                    ) / 60.0
                END
            ELSE 0
        END AS hours_in_day,

        /* Weekday Swing shift: 14:00 to 22:00, Monday through Friday */
        CASE
            WHEN ((DATEPART(WEEKDAY, sd.begin_session_time) + @@DATEFIRST - 2) % 7) + 1 BETWEEN 1 AND 5
             AND sd.session_duration_hours IS NOT NULL
            THEN
                CASE
                    WHEN DATEDIFF(MINUTE,
                        CASE WHEN sd.begin_session_time > DATEADD(HOUR, 14, CAST(sd.anchor_date AS datetime))
                             THEN sd.begin_session_time ELSE DATEADD(HOUR, 14, CAST(sd.anchor_date AS datetime)) END,
                        CASE WHEN sd.end_session_time   < DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime))
                             THEN sd.end_session_time   ELSE DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime)) END
                    ) <= 0 THEN 0
                    ELSE DATEDIFF(MINUTE,
                        CASE WHEN sd.begin_session_time > DATEADD(HOUR, 14, CAST(sd.anchor_date AS datetime))
                             THEN sd.begin_session_time ELSE DATEADD(HOUR, 14, CAST(sd.anchor_date AS datetime)) END,
                        CASE WHEN sd.end_session_time   < DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime))
                             THEN sd.end_session_time   ELSE DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime)) END
                    ) / 60.0
                END
            ELSE 0
        END AS hours_in_swing,

        /*
        Weekday Night shift: 22:00 to 06:00 crossing midnight.
        Two candidate windows are evaluated and MAX() selects the larger overlap.
        This handles sessions that could align with either the previous-night or
        same-night window depending on when the session began.
        */
        CASE
            WHEN sd.session_duration_hours IS NULL THEN 0
            ELSE (
                SELECT MAX(v.overlap_hours)
                FROM (VALUES
                    (
                        CASE
                            WHEN DATEDIFF(MINUTE,
                                CASE WHEN sd.begin_session_time > DATEADD(HOUR, 22, CAST(DATEADD(DAY, -1, sd.anchor_date) AS datetime))
                                     THEN sd.begin_session_time ELSE DATEADD(HOUR, 22, CAST(DATEADD(DAY, -1, sd.anchor_date) AS datetime)) END,
                                CASE WHEN sd.end_session_time   < DATEADD(HOUR, 6,  CAST(sd.anchor_date AS datetime))
                                     THEN sd.end_session_time   ELSE DATEADD(HOUR, 6,  CAST(sd.anchor_date AS datetime)) END
                            ) <= 0 THEN 0
                            ELSE DATEDIFF(MINUTE,
                                CASE WHEN sd.begin_session_time > DATEADD(HOUR, 22, CAST(DATEADD(DAY, -1, sd.anchor_date) AS datetime))
                                     THEN sd.begin_session_time ELSE DATEADD(HOUR, 22, CAST(DATEADD(DAY, -1, sd.anchor_date) AS datetime)) END,
                                CASE WHEN sd.end_session_time   < DATEADD(HOUR, 6,  CAST(sd.anchor_date AS datetime))
                                     THEN sd.end_session_time   ELSE DATEADD(HOUR, 6,  CAST(sd.anchor_date AS datetime)) END
                            ) / 60.0
                        END
                    ),
                    (
                        CASE
                            WHEN DATEDIFF(MINUTE,
                                CASE WHEN sd.begin_session_time > DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime))
                                     THEN sd.begin_session_time ELSE DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime)) END,
                                CASE WHEN sd.end_session_time   < DATEADD(HOUR, 6,  CAST(DATEADD(DAY, 1, sd.anchor_date) AS datetime))
                                     THEN sd.end_session_time   ELSE DATEADD(HOUR, 6,  CAST(DATEADD(DAY, 1, sd.anchor_date) AS datetime)) END
                            ) <= 0 THEN 0
                            ELSE DATEDIFF(MINUTE,
                                CASE WHEN sd.begin_session_time > DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime))
                                     THEN sd.begin_session_time ELSE DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime)) END,
                                CASE WHEN sd.end_session_time   < DATEADD(HOUR, 6,  CAST(DATEADD(DAY, 1, sd.anchor_date) AS datetime))
                                     THEN sd.end_session_time   ELSE DATEADD(HOUR, 6,  CAST(DATEADD(DAY, 1, sd.anchor_date) AS datetime)) END
                            ) / 60.0
                        END
                    )
                ) v(overlap_hours)
            )
        END AS hours_in_night,

        /* Weekend Swing shift: 10:00 to 22:00, Saturday and Sunday */
        CASE
            WHEN ((DATEPART(WEEKDAY, sd.begin_session_time) + @@DATEFIRST - 2) % 7) + 1 IN (6, 7)
             AND sd.session_duration_hours IS NOT NULL
            THEN
                CASE
                    WHEN DATEDIFF(MINUTE,
                        CASE WHEN sd.begin_session_time > DATEADD(HOUR, 10, CAST(sd.anchor_date AS datetime))
                             THEN sd.begin_session_time ELSE DATEADD(HOUR, 10, CAST(sd.anchor_date AS datetime)) END,
                        CASE WHEN sd.end_session_time   < DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime))
                             THEN sd.end_session_time   ELSE DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime)) END
                    ) <= 0 THEN 0
                    ELSE DATEDIFF(MINUTE,
                        CASE WHEN sd.begin_session_time > DATEADD(HOUR, 10, CAST(sd.anchor_date AS datetime))
                             THEN sd.begin_session_time ELSE DATEADD(HOUR, 10, CAST(sd.anchor_date AS datetime)) END,
                        CASE WHEN sd.end_session_time   < DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime))
                             THEN sd.end_session_time   ELSE DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime)) END
                    ) / 60.0
                END
            ELSE 0
        END AS hours_in_weekend_swing,

        /*
        Weekend Night shift: 22:00 to 10:00 crossing midnight, Friday and Saturday nights.
        Two candidate windows are evaluated using the same MAX() pattern as Weekday Night.
        */
        CASE
            WHEN sd.session_duration_hours IS NULL THEN 0
            ELSE (
                SELECT MAX(v.overlap_hours)
                FROM (VALUES
                    (
                        CASE
                            WHEN DATEDIFF(MINUTE,
                                CASE WHEN sd.begin_session_time > DATEADD(HOUR, 22, CAST(DATEADD(DAY, -1, sd.anchor_date) AS datetime))
                                     THEN sd.begin_session_time ELSE DATEADD(HOUR, 22, CAST(DATEADD(DAY, -1, sd.anchor_date) AS datetime)) END,
                                CASE WHEN sd.end_session_time   < DATEADD(HOUR, 10, CAST(sd.anchor_date AS datetime))
                                     THEN sd.end_session_time   ELSE DATEADD(HOUR, 10, CAST(sd.anchor_date AS datetime)) END
                            ) <= 0 THEN 0
                            ELSE DATEDIFF(MINUTE,
                                CASE WHEN sd.begin_session_time > DATEADD(HOUR, 22, CAST(DATEADD(DAY, -1, sd.anchor_date) AS datetime))
                                     THEN sd.begin_session_time ELSE DATEADD(HOUR, 22, CAST(DATEADD(DAY, -1, sd.anchor_date) AS datetime)) END,
                                CASE WHEN sd.end_session_time   < DATEADD(HOUR, 10, CAST(sd.anchor_date AS datetime))
                                     THEN sd.end_session_time   ELSE DATEADD(HOUR, 10, CAST(sd.anchor_date AS datetime)) END
                            ) / 60.0
                        END
                    ),
                    (
                        CASE
                            WHEN DATEDIFF(MINUTE,
                                CASE WHEN sd.begin_session_time > DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime))
                                     THEN sd.begin_session_time ELSE DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime)) END,
                                CASE WHEN sd.end_session_time   < DATEADD(HOUR, 10, CAST(DATEADD(DAY, 1, sd.anchor_date) AS datetime))
                                     THEN sd.end_session_time   ELSE DATEADD(HOUR, 10, CAST(DATEADD(DAY, 1, sd.anchor_date) AS datetime)) END
                            ) <= 0 THEN 0
                            ELSE DATEDIFF(MINUTE,
                                CASE WHEN sd.begin_session_time > DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime))
                                     THEN sd.begin_session_time ELSE DATEADD(HOUR, 22, CAST(sd.anchor_date AS datetime)) END,
                                CASE WHEN sd.end_session_time   < DATEADD(HOUR, 10, CAST(DATEADD(DAY, 1, sd.anchor_date) AS datetime))
                                     THEN sd.end_session_time   ELSE DATEADD(HOUR, 10, CAST(DATEADD(DAY, 1, sd.anchor_date) AS datetime)) END
                            ) / 60.0
                        END
                    )
                ) v(overlap_hours)
            )
        END AS hours_in_weekend_night

    FROM SessionDurations sd
),

ShiftClassification AS (

    /*
    Primary shift note:
    The shift with the greatest overlap is assigned as the primary shift.
    All five shift windows are compared simultaneously. The first WHEN branch
    that evaluates as the overall maximum wins.
    */

    SELECT
        h.*,
        CASE
            WHEN h.hours_in_day >= h.hours_in_swing
             AND h.hours_in_day >= h.hours_in_night
             AND h.hours_in_day >= h.hours_in_weekend_swing
             AND h.hours_in_day >= h.hours_in_weekend_night  THEN 'Day'

            WHEN h.hours_in_swing >= h.hours_in_day
             AND h.hours_in_swing >= h.hours_in_night
             AND h.hours_in_swing >= h.hours_in_weekend_swing
             AND h.hours_in_swing >= h.hours_in_weekend_night THEN 'Swing'

            WHEN h.hours_in_night >= h.hours_in_day
             AND h.hours_in_night >= h.hours_in_swing
             AND h.hours_in_night >= h.hours_in_weekend_swing
             AND h.hours_in_night >= h.hours_in_weekend_night THEN 'Night'

            WHEN h.hours_in_weekend_swing >= h.hours_in_day
             AND h.hours_in_weekend_swing >= h.hours_in_swing
             AND h.hours_in_weekend_swing >= h.hours_in_night
             AND h.hours_in_weekend_swing >= h.hours_in_weekend_night THEN 'Weekend Swing'

            WHEN h.hours_in_weekend_night >= h.hours_in_day
             AND h.hours_in_weekend_night >= h.hours_in_swing
             AND h.hours_in_weekend_night >= h.hours_in_night
             AND h.hours_in_weekend_night >= h.hours_in_weekend_swing THEN 'Weekend Night'

            ELSE NULL
        END AS shift

    FROM HoursPerShift h
)

SELECT
    anon_employee_key,
    session_number,

    begin_session_time,
    begin_session_door_name,
    end_session_time,
    end_session_door_name,

    session_duration_hours,
    raw_session_duration_hours,
    swipe_count,

    is_micro_session_flag,
    exceeds_max_duration_flag,

    CASE
        WHEN is_micro_session_flag = 1    THEN 1
        WHEN exceeds_max_duration_flag = 1 THEN 1
        WHEN swipe_count < 2              THEN 1
        ELSE 0
    END AS data_quality_flag,

    shift,

    hours_in_day,
    hours_in_swing,
    hours_in_night,
    hours_in_weekend_swing,
    hours_in_weekend_night,

    /*
    Minor shift note:
    A secondary shift is assigned when the second-largest overlap is between
    1 and 4 hours. This captures sessions that meaningfully spill into an
    adjacent shift without reclassifying the session entirely.

    The minor shift logic is evaluated separately per primary shift so only
    the remaining four windows are considered as candidates.
    */
    CASE
        WHEN shift = 'Day' THEN
            CASE
                WHEN hours_in_swing >= hours_in_night AND hours_in_swing >= hours_in_weekend_swing AND hours_in_swing >= hours_in_weekend_night
                     AND hours_in_swing BETWEEN 1 AND 4 THEN 'Swing'
                WHEN hours_in_night  > hours_in_swing AND hours_in_night >= hours_in_weekend_swing AND hours_in_night >= hours_in_weekend_night
                     AND hours_in_night BETWEEN 1 AND 4 THEN 'Night'
                WHEN hours_in_weekend_swing > hours_in_swing AND hours_in_weekend_swing > hours_in_night AND hours_in_weekend_swing >= hours_in_weekend_night
                     AND hours_in_weekend_swing BETWEEN 1 AND 4 THEN 'Weekend Swing'
                WHEN hours_in_weekend_night > hours_in_swing AND hours_in_weekend_night > hours_in_night AND hours_in_weekend_night > hours_in_weekend_swing
                     AND hours_in_weekend_night BETWEEN 1 AND 4 THEN 'Weekend Night'
                ELSE NULL
            END

        WHEN shift = 'Swing' THEN
            CASE
                WHEN hours_in_day >= hours_in_night AND hours_in_day >= hours_in_weekend_swing AND hours_in_day >= hours_in_weekend_night
                     AND hours_in_day BETWEEN 1 AND 4 THEN 'Day'
                WHEN hours_in_night > hours_in_day AND hours_in_night >= hours_in_weekend_swing AND hours_in_night >= hours_in_weekend_night
                     AND hours_in_night BETWEEN 1 AND 4 THEN 'Night'
                WHEN hours_in_weekend_swing > hours_in_day AND hours_in_weekend_swing > hours_in_night AND hours_in_weekend_swing >= hours_in_weekend_night
                     AND hours_in_weekend_swing BETWEEN 1 AND 4 THEN 'Weekend Swing'
                WHEN hours_in_weekend_night > hours_in_day AND hours_in_weekend_night > hours_in_night AND hours_in_weekend_night > hours_in_weekend_swing
                     AND hours_in_weekend_night BETWEEN 1 AND 4 THEN 'Weekend Night'
                ELSE NULL
            END

        WHEN shift = 'Night' THEN
            CASE
                WHEN hours_in_swing >= hours_in_day AND hours_in_swing >= hours_in_weekend_swing AND hours_in_swing >= hours_in_weekend_night
                     AND hours_in_swing BETWEEN 1 AND 4 THEN 'Swing'
                WHEN hours_in_day > hours_in_swing AND hours_in_day >= hours_in_weekend_swing AND hours_in_day >= hours_in_weekend_night
                     AND hours_in_day BETWEEN 1 AND 4 THEN 'Day'
                WHEN hours_in_weekend_swing > hours_in_swing AND hours_in_weekend_swing > hours_in_day AND hours_in_weekend_swing >= hours_in_weekend_night
                     AND hours_in_weekend_swing BETWEEN 1 AND 4 THEN 'Weekend Swing'
                WHEN hours_in_weekend_night > hours_in_swing AND hours_in_weekend_night > hours_in_day AND hours_in_weekend_night > hours_in_weekend_swing
                     AND hours_in_weekend_night BETWEEN 1 AND 4 THEN 'Weekend Night'
                ELSE NULL
            END

        WHEN shift = 'Weekend Swing' THEN
            CASE WHEN hours_in_weekend_night BETWEEN 1 AND 4 THEN 'Weekend Night' ELSE NULL END

        WHEN shift = 'Weekend Night' THEN
            CASE WHEN hours_in_weekend_swing BETWEEN 1 AND 4 THEN 'Weekend Swing' ELSE NULL END

        ELSE NULL
    END AS minor_shift

FROM ShiftClassification

/*
Output filter note:
Rows with zero or negative raw duration are excluded. These represent exact
duplicate badge events or system artifacts where begin and end timestamps
are identical.
*/
WHERE raw_duration_seconds > 0

ORDER BY
    data_quality_flag DESC;
