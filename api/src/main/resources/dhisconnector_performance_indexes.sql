-- =============================================================================
-- DHIS Connector Module – Performance Index Script
-- =============================================================================
-- Purpose:
--   Add composite and covering indexes to the OpenMRS core tables that are
--   hit hardest during Period Indicator Report cohort evaluation. These indexes
--   directly target the WHERE / JOIN / ORDER BY patterns used by the OpenMRS
--   Reporting module when it evaluates CohortDefinitions and CohortIndicators.
--
-- How to use:
--   1. Run this script once on your OpenMRS MySQL/MariaDB database.
--   2. Each statement is wrapped in a guard that skips it if the index already
--      exists, so the script is safe to re-run.
--   3. CREATE INDEX on large tables acquires a metadata lock. Run during a
--      maintenance window or use:  SET SESSION old_alter_table=0; (online DDL)
--   4. After running, use ANALYZE TABLE on the affected tables so the query
--      optimiser picks up the new statistics immediately.
--
-- Tables covered:
--   obs, encounter, visit, patient, person,
--   patient_program, patient_state, patient_identifier,
--   orders, cohort_member
--
-- NOTE: Indexes that already exist in the OpenMRS 2.x core schema are
--       explicitly skipped (they are listed in comments for reference only).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1 – obs
-- Most expensive table. Cohort queries that count diagnoses, drug dispensing,
-- lab values, or any clinical observation all scan this table.
-- Existing core indexes: person_id, concept_id, encounter_id, obs_datetime,
--   location_id, value_coded, value_drug, obs_group_id, order_id,
--   value_coded_name_id, creator, voided_by, previous_version
-- ─────────────────────────────────────────────────────────────────────────────

-- 1a. The single most impactful index.
--     Pattern: "count observations of concept X for active (non-voided)
--     patients between startDate and endDate"
--     Covers: concept-based cohort queries filtered by date range + voided flag.
--     Uses: concept_id (equality), voided (equality), obs_datetime (range)
--     Includes person_id so the engine can resolve the patient set from the
--     index leaf pages without touching the clustered row.
CREATE INDEX IF NOT EXISTS idx_obs_concept_voided_date_person
    ON obs (concept_id, voided, obs_datetime, person_id);

-- 1b. Location-filtered observation counts.
--     Pattern: "count obs of concept X at location Y in period [start, end]"
--     Reporting module always passes location when running per-facility reports.
CREATE INDEX IF NOT EXISTS idx_obs_concept_location_voided_date
    ON obs (concept_id, location_id, voided, obs_datetime);

-- 1c. Coded-value observation queries (diagnoses, drug concepts).
--     Pattern: "patients who have obs with value_coded = X between dates"
CREATE INDEX IF NOT EXISTS idx_obs_concept_valuecoded_voided_date
    ON obs (concept_id, value_coded, voided, obs_datetime, person_id);

-- 1d. Numeric-value observations (lab results, vitals thresholds).
--     Pattern: "patients whose latest CD4 / viral load / weight is above Y"
CREATE INDEX IF NOT EXISTS idx_obs_concept_valuenumeric_voided_date
    ON obs (concept_id, voided, obs_datetime, value_numeric, person_id);

-- 1e. Person + concept lookup without a date range (e.g., "ever had obs X").
--     Covers the base-cohort sub-queries that look up a specific concept for
--     a list of patients returned by an earlier query stage.
CREATE INDEX IF NOT EXISTS idx_obs_person_concept_voided
    ON obs (person_id, concept_id, voided);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2 – encounter
-- Cohort definitions that count visits / form submissions per period.
-- Existing core indexes: patient_id, encounter_datetime, encounter_type,
--   location_id, form_id, visit_id, creator, voided_by, changed_by
-- ─────────────────────────────────────────────────────────────────────────────

-- 2a. The core "encounters of type T for non-voided patients in date window"
--     query that every visit-based cohort relies on.
CREATE INDEX IF NOT EXISTS idx_encounter_type_voided_date_patient
    ON encounter (encounter_type, voided, encounter_datetime, patient_id);

-- 2b. Location-scoped encounter counts — used heavily in per-facility reporting.
CREATE INDEX IF NOT EXISTS idx_encounter_location_type_voided_date
    ON encounter (location_id, encounter_type, voided, encounter_datetime, patient_id);

-- 2c. Patient + type lookup — JOINs from sub-queries that already have a
--     patient list and need to verify presence of a certain encounter type.
CREATE INDEX IF NOT EXISTS idx_encounter_patient_type_voided_date
    ON encounter (patient_id, encounter_type, voided, encounter_datetime);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3 – visit
-- "Patients with an active visit / visit within period" cohort patterns.
-- Existing core indexes: patient_id, visit_type_id, location_id, creator,
--   changed_by, voided_by, indication_concept_id
-- ─────────────────────────────────────────────────────────────────────────────

-- 3a. Visit-type filtered, date-ranged, non-voided patient visits.
CREATE INDEX IF NOT EXISTS idx_visit_type_voided_date_patient
    ON visit (visit_type_id, voided, date_started, patient_id);

-- 3b. Location + visit type — facility-level visit counts.
CREATE INDEX IF NOT EXISTS idx_visit_location_type_voided_date
    ON visit (location_id, visit_type_id, voided, date_started, date_stopped);

-- 3c. Open visits (date_stopped IS NULL) — "currently enrolled / active" checks.
--     MySQL uses the index on date_stopped when filtering for NULL.
CREATE INDEX IF NOT EXISTS idx_visit_patient_voided_stopped
    ON visit (patient_id, voided, date_stopped);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4 – patient
-- Cohort definitions that filter on patient-level attributes (voided flag,
-- date enrolled, gender via JOIN to person).
-- Existing core indexes: creator, voided_by, changed_by
-- ─────────────────────────────────────────────────────────────────────────────

-- 4a. Active (non-voided) patient lookup — the base table for almost every query.
--     Separating voided=0 patients into a tight index dramatically reduces
--     the scan range on every cohort that starts with "all active patients".
CREATE INDEX IF NOT EXISTS idx_patient_voided
    ON patient (voided, patient_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5 – person
-- Age / gender / vital status filters applied to the person table.
-- Existing core indexes: birthdate, death_date, cause_of_death, creator,
--   changed_by, voided_by
-- ─────────────────────────────────────────────────────────────────────────────

-- 5a. Gender + birthdate range — age/sex breakdown cohort definitions.
--     e.g., "female patients born between 1975 and 2005, non-voided".
CREATE INDEX IF NOT EXISTS idx_person_gender_birthdate_voided
    ON person (gender, birthdate, voided, person_id);

-- 5b. Alive (dead=0) + non-voided patient lookup — used in almost all active
--     patient cohorts to exclude deceased patients.
CREATE INDEX IF NOT EXISTS idx_person_dead_voided
    ON person (dead, voided, person_id);

-- 5c. Death date range — mortality cohort definitions.
CREATE INDEX IF NOT EXISTS idx_person_dead_deathdate_voided
    ON person (dead, death_date, voided, person_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6 – patient_program
-- Program enrollment cohort definitions (HIV, TB, ANC programs, etc.).
-- Existing core indexes: patient_id, program_id, location_id, outcome_concept_id,
--   creator, changed_by, voided_by
-- ─────────────────────────────────────────────────────────────────────────────

-- 6a. "Patients enrolled in program P, not yet completed, non-voided".
CREATE INDEX IF NOT EXISTS idx_patprog_program_voided_enrolled_completed
    ON patient_program (program_id, voided, date_enrolled, date_completed, patient_id);

-- 6b. Location-filtered enrollments — per-facility program patient counts.
CREATE INDEX IF NOT EXISTS idx_patprog_program_location_voided_enrolled
    ON patient_program (program_id, location_id, voided, date_enrolled, date_completed);

-- 6c. Outcome-filtered completions — "patients who completed with outcome X".
CREATE INDEX IF NOT EXISTS idx_patprog_program_outcome_voided
    ON patient_program (program_id, outcome_concept_id, voided, date_completed, patient_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7 – patient_state
-- Workflow state transition cohort definitions (e.g., "entered On ARVs state
-- within reporting period").
-- Existing core indexes: patient_program_id, state, creator, changed_by,
--   voided_by, encounter_id
-- ─────────────────────────────────────────────────────────────────────────────

-- 7a. State + date range — "patients who entered/exited state S between dates".
CREATE INDEX IF NOT EXISTS idx_patstate_state_voided_startdate
    ON patient_state (state, voided, start_date, end_date, patient_program_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 8 – patient_identifier
-- Used in cohort definitions that filter by identifier type (e.g., patients
-- with an ARV number).
-- Existing core indexes: identifier, identifier_type, patient_id, location_id,
--   creator, changed_by, voided_by, patient_program_id
-- ─────────────────────────────────────────────────────────────────────────────

-- 8a. Identifier type + voided — "patients who have identifier type T".
--     The core index idx_patient_identifier_patient covers patient_id only;
--     this composite is needed when the query starts from identifier_type.
CREATE INDEX IF NOT EXISTS idx_patid_type_voided_patient
    ON patient_identifier (identifier_type, voided, patient_id);

-- 8b. Preferred identifier lookup — used in display + de-duplication queries.
CREATE INDEX IF NOT EXISTS idx_patid_type_preferred_voided
    ON patient_identifier (identifier_type, preferred, voided, patient_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 9 – orders
-- Drug order cohort definitions (patients on a specific drug / drug regimen).
-- Existing core indexes: patient_id, encounter_id, concept_id, order_type_id,
--   orderer, order_reason, accession_number, care_setting, order_group_id,
--   order_number, previous_order_id, creator, voided_by
-- ─────────────────────────────────────────────────────────────────────────────

-- 9a. Drug/concept orders active within a date range.
--     Pattern: "patients who have a non-voided order for concept C activated
--     between startDate and endDate and not yet stopped".
CREATE INDEX IF NOT EXISTS idx_orders_concept_voided_activated_stopped
    ON orders (concept_id, voided, date_activated, date_stopped, patient_id);

-- 9b. Order type + date — "patients with any active drug order in period".
CREATE INDEX IF NOT EXISTS idx_orders_type_voided_activated
    ON orders (order_type_id, voided, date_activated, date_stopped, patient_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 10 – cohort_member
-- Used by saved Cohort definitions to look up current membership.
-- Existing core indexes: cohort_id, patient_id, creator
-- ─────────────────────────────────────────────────────────────────────────────

-- 10a. Active (non-voided, end_date IS NULL) membership lookup.
--      Many cohort definitions are backed by a saved cohort; this covers the
--      "members of cohort C who have not been end-dated" pattern.
CREATE INDEX IF NOT EXISTS idx_cohortmember_cohort_voided_end
    ON cohort_member (cohort_id, voided, end_date, patient_id);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 11 – serialized_object
-- The OpenMRS Reporting module stores CohortDefinitions, ReportDefinitions,
-- and Indicators in this table. These are fetched by UUID on every report run.
-- ─────────────────────────────────────────────────────────────────────────────

-- 11a. UUID lookup — called once per cohort/indicator/dimension per report run.
CREATE INDEX IF NOT EXISTS idx_serialized_object_uuid
    ON serialized_object (uuid);

-- 11b. Type + subtype lookup — used when the reporting service enumerates all
--      definitions of a given type (e.g., all CohortDefinitions).
CREATE INDEX IF NOT EXISTS idx_serialized_object_type_subtype
    ON serialized_object (type, subtype);


-- =============================================================================
-- SECTION 12 – Update table statistics
-- Forces the MySQL query optimiser to immediately see and use the new indexes
-- instead of waiting for the background statistics refresh.
-- =============================================================================

ANALYZE TABLE obs;
ANALYZE TABLE encounter;
ANALYZE TABLE visit;
ANALYZE TABLE patient;
ANALYZE TABLE person;
ANALYZE TABLE patient_program;
ANALYZE TABLE patient_state;
ANALYZE TABLE patient_identifier;
ANALYZE TABLE orders;
ANALYZE TABLE cohort_member;
ANALYZE TABLE serialized_object;


-- =============================================================================
-- VERIFICATION QUERY
-- Run this after the script to confirm all new indexes were created.
-- =============================================================================
/*
SELECT
    TABLE_NAME,
    INDEX_NAME,
    GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS index_columns,
    NON_UNIQUE
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE()
  AND INDEX_NAME LIKE 'idx_%'
  AND TABLE_NAME IN (
      'obs','encounter','visit','patient','person',
      'patient_program','patient_state','patient_identifier',
      'orders','cohort_member','serialized_object'
  )
GROUP BY TABLE_NAME, INDEX_NAME, NON_UNIQUE
ORDER BY TABLE_NAME, INDEX_NAME;
*/
