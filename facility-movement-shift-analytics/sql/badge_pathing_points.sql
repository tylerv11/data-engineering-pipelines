/*
================================================================================
Project:  Facility Movement & Shift Presence Analytics
File:     badge_pathing_points.sql

Purpose:
  Reconstructs employee movement paths from badge access events.

  Each badge swipe is treated as an origin point. The next badge swipe
  by the same employee and card is treated as the destination point.
  The time between origin and destination is calculated as duration.

  The output is formatted for map visualization. Each movement segment
  produces two rows: one origin point and one destination point.

Design notes:
  - Employee identifiers are hashed with SHA-256 before any downstream use.
  - Door names are matched to coordinate reference records using pattern matching.
  - Segments longer than 12 hours are excluded as unrealistic.
  - Access points without coordinate matches pass through with NULL coordinates
    and are flagged with has_coordinates = 0.

Note:
  All table names, column names, door names, coordinates, and system identifiers
  have been anonymized for portfolio use.
================================================================================
*/

DECLARE @NowLocal   datetime = GETDATE();
DECLARE @StartLocal datetime = DATEADD(DAY, -10, @NowLocal);

WITH DoorLocationReference AS (

    /*
    Reference note:
    This table maps door name patterns to known facility coordinates.
    Patterns use SQL LIKE syntax so a single reference entry can match
    multiple related access points.

    In a production environment this would typically be managed as a
    governed reference table rather than an inline CTE.
    */

    SELECT 'FACILITY_A-MAIN-ENTRY-%'              AS door_name_pattern,
           CAST(0.000001 AS float)                AS latitude,
           CAST(0.000001 AS float)                AS longitude
    UNION ALL
    SELECT 'FACILITY_A-MAIN-EXIT-%',               0.000001, 0.000002
    UNION ALL
    SELECT 'FACILITY_A-PARKING-ENTRY-%',           0.000001, 0.000003
    UNION ALL
    SELECT 'FACILITY_A-PARKING-EXIT-%',            0.000001, 0.000004
    UNION ALL
    SELECT 'FACILITY_A-GATE-ARM-%',                0.000002, 0.000001
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_1-LOBBY-%',        0.000002, 0.000002
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_2-PRODUCTION-%',   0.000003, 0.000001
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_2-GOWNING-%',      0.000003, 0.000002
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_2-DEGOWNING-%',    0.000003, 0.000003
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_2-AIRLOCK-%',      0.000003, 0.000004
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_2-REAR-EXIT-%',    0.000003, 0.000005
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_3-RECEIVING-%',    0.000004, 0.000001
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_3-MAINTENANCE-%',  0.000004, 0.000002
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_3-NORTH-ENTRY-%',  0.000004, 0.000003
    UNION ALL
    SELECT 'FACILITY_A-WAREHOUSE-ROLLUP-%',        0.000005, 0.000001
    UNION ALL
    SELECT 'FACILITY_A-WAREHOUSE-TEARDOWN-%',      0.000005, 0.000002
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_4-OFFICE-ENTRY-%', 0.000006, 0.000001
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_4-LOBBY-EXTERIOR-%', 0.000006, 0.000002
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_5-FITNESS-%',      0.000007, 0.000001
    UNION ALL
    SELECT 'FACILITY_A-BUILDING_5-REAR-ENTRY-%',   0.000007, 0.000002
    UNION ALL
    SELECT 'FACILITY_A-LOCKER-ROOM-%',             0.000008, 0.000001
    UNION ALL
    SELECT 'FACILITY_A-BUFFER-PREP-GOWN-%',        0.000008, 0.000002
    UNION ALL
    SELECT 'FACILITY_A-BUFFER-PREP-DEGOWN-%',      0.000008, 0.000003
),

BaseEvents AS (

    /*
    Governance note:
    Employee IDs are hashed using SHA-256 immediately after trimming and
    uppercasing. This produces a stable, repeatable anonymized key for
    cross-session and path tracking without retaining raw employee identifiers
    in any downstream CTE or output.

    Records without an employee ID are excluded to prevent guest or unknown
    badges from collapsing into the empty-string hash.
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
    WHERE ah.swipe_timestamp >= @StartLocal
      AND ah.swipe_timestamp <  @NowLocal
      AND ah.employee_id IS NOT NULL
),

BaseEventsWithCoords AS (

    /*
    Spatial enrichment note:
    Each badge event is matched to the best available coordinate reference
    using pattern-based matching. TOP 1 ordered by pattern length descending
    ensures the most specific matching pattern wins when multiple reference
    entries could apply.

    Events that do not match any reference pattern pass through with NULL
    coordinates and will be flagged in the final output.
    */

    SELECT
        b.swipe_timestamp,
        b.card_number,
        b.door_name,
        b.anon_employee_key,
        m.latitude,
        m.longitude
    FROM BaseEvents b
    OUTER APPLY (
        SELECT TOP (1)
            d.latitude,
            d.longitude
        FROM DoorLocationReference d
        WHERE b.door_name LIKE d.door_name_pattern
        ORDER BY LEN(d.door_name_pattern) DESC
    ) m
),

Sequenced AS (

    /*
    Event sequencing note:
    Badge events are ordered by anonymized employee key and card number.
    LEAD() projects the next badge event onto each current row, which
    creates the origin-to-destination pairing needed for path segment generation.
    */

    SELECT
        anon_employee_key,
        card_number,

        door_name          AS origin_door_name,
        swipe_timestamp    AS origin_badge_time,
        latitude           AS origin_latitude,
        longitude          AS origin_longitude,

        LEAD(door_name)         OVER (PARTITION BY anon_employee_key, card_number ORDER BY swipe_timestamp) AS end_door_name,
        LEAD(swipe_timestamp)   OVER (PARTITION BY anon_employee_key, card_number ORDER BY swipe_timestamp) AS end_badge_time,
        LEAD(latitude)          OVER (PARTITION BY anon_employee_key, card_number ORDER BY swipe_timestamp) AS end_latitude,
        LEAD(longitude)         OVER (PARTITION BY anon_employee_key, card_number ORDER BY swipe_timestamp) AS end_longitude,

        ROW_NUMBER() OVER (PARTITION BY anon_employee_key, card_number ORDER BY swipe_timestamp) AS segment_order,

        /*
        Reporting note:
        PathID provides a stable grouping key for map rendering by collapsing
        the anonymized employee key into an integer via CHECKSUM. ABS() prevents
        negative values from SQL Server's CHECKSUM implementation.
        */
        ABS(CHECKSUM(anon_employee_key)) AS path_id
    FROM BaseEventsWithCoords
),

Segments AS (

    /*
    Segment filtering note:
    Segments are filtered to valid, interpretable movement records only.

    Excluded when:
      - No end badge event exists (last event for the employee)
      - End time is not after the origin time
      - Duration exceeds 12 hours, which is treated as an unrealistic
        single-segment movement and likely reflects missing intermediate events
    */

    SELECT
        path_id,
        anon_employee_key,
        card_number,
        segment_order,

        origin_door_name,
        origin_badge_time,
        origin_latitude,
        origin_longitude,

        end_door_name,
        end_badge_time,
        end_latitude,
        end_longitude,

        DATEDIFF(SECOND, origin_badge_time, end_badge_time) / 3600.0 AS duration_hours,

        CASE
            WHEN origin_latitude IS NOT NULL AND origin_longitude IS NOT NULL
             AND end_latitude    IS NOT NULL AND end_longitude    IS NOT NULL
                THEN 1
            ELSE 0
        END AS has_coordinates
    FROM Sequenced
    WHERE end_badge_time IS NOT NULL
      AND end_badge_time > origin_badge_time
      AND end_badge_time <= DATEADD(HOUR, 12, origin_badge_time)
),

MapPoints AS (

    /*
    Output format note:
    Map visualization tools require discrete geographic points to draw
    movement lines. Each segment is expanded into two rows: one origin point
    and one destination point.

    The point_sequence field combines segment_order and point_order so the
    full movement path can be ordered correctly in a single sorted dataset.
    */

    SELECT
        path_id,
        anon_employee_key,
        card_number,
        segment_order,
        1             AS point_order,
        'Origin'      AS point_type,
        origin_badge_time AS point_time,
        origin_door_name  AS door_name,
        origin_latitude   AS latitude,
        origin_longitude  AS longitude,
        duration_hours,
        has_coordinates
    FROM Segments

    UNION ALL

    SELECT
        path_id,
        anon_employee_key,
        card_number,
        segment_order,
        2             AS point_order,
        'End'         AS point_type,
        end_badge_time   AS point_time,
        end_door_name    AS door_name,
        end_latitude     AS latitude,
        end_longitude    AS longitude,
        duration_hours,
        has_coordinates
    FROM Segments
)

SELECT
    path_id,
    anon_employee_key,
    card_number,
    (segment_order * 10) + point_order AS point_sequence,
    segment_order,
    point_order,
    point_type,
    point_time,
    door_name,
    latitude,
    longitude,
    duration_hours,
    has_coordinates
FROM MapPoints
ORDER BY
    anon_employee_key,
    card_number,
    segment_order,
    point_order;
