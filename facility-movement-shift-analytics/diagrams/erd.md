# Entity Relationship Diagram

## Facility Movement & Shift Presence Analytics

This diagram describes analytical products derived from access-control badge events. It does not represent GPS tracking, device telemetry, or continuous employee location monitoring. Coordinates are attributes of fixed access points.

```mermaid
erDiagram

    BADGE_ACCESS_EVENT {
        datetime swipe_timestamp
        string   card_number
        string   door_name
        string   raw_employee_id
    }

    DOOR_LOCATION_REFERENCE {
        string door_name_pattern PK
        float  latitude
        float  longitude
        string access_point_type
    }

    ANON_EMPLOYEE_DIM {
        string anon_employee_key PK
    }

    BADGE_PATH_SEGMENT {
        int      path_id
        string   anon_employee_key FK
        string   card_number
        int      segment_order
        string   origin_door_name
        datetime origin_badge_time
        float    origin_latitude
        float    origin_longitude
        string   end_door_name
        datetime end_badge_time
        float    end_latitude
        float    end_longitude
        float    duration_hours
        int      unrealistic_gap_flag
        int      has_coordinates
    }

    BADGE_MAP_POINT {
        int      path_id FK
        string   anon_employee_key FK
        string   card_number
        int      point_sequence
        int      segment_order
        int      point_order
        string   point_type
        datetime point_time
        string   door_name
        float    latitude
        float    longitude
        float    duration_hours
        int      has_coordinates
    }

    BADGE_ACTIVITY_SESSION {
        string   anon_employee_key FK
        int      session_number
        datetime begin_session_time
        string   begin_session_door_name
        datetime end_session_time
        string   end_session_door_name
        int      swipe_count
        float    raw_duration_seconds
        float    raw_session_duration_hours
        float    session_duration_hours
        int      is_micro_session_flag
        int      exceeds_max_duration_flag
        int      data_quality_flag
        float    hours_in_day
        float    hours_in_swing
        float    hours_in_night
        float    hours_in_weekend_swing
        float    hours_in_weekend_night
    }

    SHIFT_WINDOW_REFERENCE {
        string shift_name PK
        string day_type
        time   window_start
        time   window_end
        string crosses_midnight
    }

    SESSION_SHIFT_CLASSIFICATION {
        string anon_employee_key FK
        int    session_number FK
        string primary_shift FK
        string minor_shift
    }

    %% Raw badge events are the source for both analytical pipelines
    BADGE_ACCESS_EVENT       ||--o{ BADGE_PATH_SEGMENT            : "sequenced into"
    BADGE_ACCESS_EVENT       ||--o{ BADGE_ACTIVITY_SESSION         : "sessionized into"

    %% Anonymized employee key connects sessions and paths
    ANON_EMPLOYEE_DIM        ||--o{ BADGE_PATH_SEGMENT            : "tracks movement for"
    ANON_EMPLOYEE_DIM        ||--o{ BADGE_ACTIVITY_SESSION         : "tracks sessions for"

    %% Door reference enriches access points with fixed coordinates
    DOOR_LOCATION_REFERENCE  ||--o{ BADGE_PATH_SEGMENT            : "provides access-point coordinates"

    %% Path segments expand into map-ready point pairs
    BADGE_PATH_SEGMENT       ||--|{ BADGE_MAP_POINT                : "generates origin and end points"

    %% Sessions are classified against shift windows
    BADGE_ACTIVITY_SESSION   ||--o{ SESSION_SHIFT_CLASSIFICATION   : "classified by"
    SHIFT_WINDOW_REFERENCE   ||--o{ SESSION_SHIFT_CLASSIFICATION   : "defines windows for"
```

---

## Notes on Design

**Why BADGE_ACCESS_EVENT feeds two separate outputs:**
The same event source supports two different analytical questions. The pathing pipeline answers where people moved and how long each movement took. The session pipeline answers when people were active and which shift they most likely worked. Both are derived from the same badge history, but with different transformation logic applied.

**Why pathing is modeled as an inference:**
The model orders swipes and pairs each observed access point with the next observed access point. That sequence can support movement visualization, but it is not a complete physical route and should not be described as GPS tracking.

**Why ANON_EMPLOYEE_DIM exists as a separate entity:**
The raw event table contains employee IDs. Those IDs are hashed before any downstream use. The anonymized key is treated as the stable identity anchor across both pipelines, allowing session tracking and path association without retaining or exposing raw employee data.

**Why DOOR_LOCATION_REFERENCE uses pattern matching:**
Access control systems often have door names that follow naming conventions with slight variations. The reference table uses patterns so a single reference entry can match multiple related doors without requiring an exact-string join for every access point.

**Why coordinates belong only to access points:**
Latitude and longitude values are properties of fixed doors, gates, or controlled locations. The anonymized employee key never carries a coordinate attribute.

**Why BADGE_MAP_POINT has two rows per segment:**
Map visualization tools need discrete geographic points to draw lines. Each movement segment generates one origin point and one destination point. The `point_sequence` field combines segment order and point order so the full path can be ordered and rendered correctly in a single sorted dataset.

**Why SHIFT_WINDOW_REFERENCE is modeled separately:**
Shift windows are configuration, not event data. Modeling them as a reference dimension makes the logic explicit and easier to audit, change, or extend. In the SQL implementation, shift windows are evaluated via interval intersection arithmetic rather than a literal join, but the reference model represents the business definition.

**Why data quality flags are part of the output:**
Badge telemetry can include duplicate swipes, missing events, single-swipe sessions, and unrealistic long gaps. Flags allow downstream dashboards to filter questionable records while preserving transparency about what was observed.
