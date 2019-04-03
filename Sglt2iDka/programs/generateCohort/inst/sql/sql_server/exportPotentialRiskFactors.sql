{@i == 1}?{
  IF OBJECT_ID('@target_database_schema.@target_table') IS NOT NULL
    DROP TABLE @target_database_schema.@target_table;

  CREATE TABLE @target_database_schema.@target_table (
    DB                    VARCHAR(10),
    COHORT_DEFINITION_ID  INT,
    COHORT_OF_INTEREST    VARCHAR(500),
    T2DM                  VARCHAR(10),
    CENSOR                INT,
    DKA                   INT,
    STAT_ORDER_NUMBER_1   INT,
    STAT_ORDER_NUMBER_2   INT,
    STAT_TYPE             VARCHAR(150),
    STAT                  INT,
    STAT_PCT              FLOAT,
    STAT_OTHER            VARCHAR(50)
  );
}

IF OBJECT_ID('tempdb..#qualified_events') IS NOT NULL
  DROP TABLE tempdb..#qualified_events;

IF OBJECT_ID('tempdb..#qualified_DKA_prep') IS NOT NULL
  DROP TABLE tempdb..#qualified_DKA_prep;

IF OBJECT_ID('tempdb..#median_DKA') IS NOT NULL
  DROP TABLE tempdb..#median_DKA;

IF OBJECT_ID('tempdb..#precipitating_events') IS NOT NULL
  DROP TABLE tempdb..#median_DKA;

IF OBJECT_ID('tempdb..#qualified_insulin') IS NOT NULL
  DROP TABLE tempdb..#qualified_insulin;

IF OBJECT_ID('tempdb..#temp_results') IS NOT NULL
  DROP TABLE tempdb..#temp_results;



/*******************************************************************************/
/****DATA PREP******************************************************************/
/*******************************************************************************/



/******************************************************************************/
/*COLLECTING DATA WE DON'T ALREADY HAVE ON EXPOSURE COHORTS*/
/******************************************************************************/
/****Find people's age, gender, and observation period*/

--HINT DISTRIBUTE_ON_KEY(person_id)
SELECT 	'@dbID' AS DB,
		c.COHORT_DEFINITION_ID,
		u.COHORT_OF_INTEREST,
		u.T2DM,
		u.CENSOR,
		c.SUBJECT_ID AS PERSON_ID,
		c.COHORT_START_DATE,
		c.COHORT_END_DATE,
		p.GENDER_CONCEPT_ID AS GENDER_CONCEPT_ID,
		YEAR(COHORT_START_DATE) - p.YEAR_OF_BIRTH AS AGE,
		op.OBSERVATION_PERIOD_START_DATE,
		op.OBSERVATION_PERIOD_END_DATE
INTO #qualified_events
FROM @target_database_schema.@cohort_universe u
	JOIN @target_database_schema.@cohort_table c
		ON c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
	JOIN @cdm_database_schema.PERSON p
		ON p.PERSON_ID = c.SUBJECT_ID
	JOIN @cdm_database_schema.OBSERVATION_PERIOD op
		ON op.PERSON_ID = c.SUBJECT_ID
		AND c.COHORT_START_DATE BETWEEN op.OBSERVATION_PERIOD_START_DATE AND op.OBSERVATION_PERIOD_END_DATE
WHERE u.EXPOSURE_COHORT = 1
AND u.FU_STRAT_ITT_PP0DAY = 1;

/****Find people's first DKA after index*/
--HINT DISTRIBUTE_ON_KEY(person_id)
SELECT e.DB, e.COHORT_DEFINITION_ID, e.COHORT_OF_INTEREST, e.T2DM, e.CENSOR, e.PERSON_ID, e.COHORT_START_DATE, e.COHORT_END_DATE, e.GENDER_CONCEPT_ID, e.AGE,
	MAX(CASE WHEN c.COHORT_DEFINITION_ID IS NULL THEN 0 ELSE 1 END) AS DKA,
	MIN(c.COHORT_START_DATE) AS DKA_INDEX_DATE
INTO #qualified_DKA_prep
FROM #qualified_events e
	LEFT OUTER JOIN @target_database_schema.@cohort_table c
		ON c.SUBJECT_ID = e.PERSON_ID
		AND c.COHORT_DEFINITION_ID = 200 /*DKA (IP & ER)*/
		AND c.COHORT_START_DATE > e.COHORT_START_DATE  /*ITT for DKA*/
		AND c.COHORT_START_DATE BETWEEN e.OBSERVATION_PERIOD_START_DATE AND e.OBSERVATION_PERIOD_END_DATE  /*ITT for DKA*/
GROUP BY e.DB, e.COHORT_DEFINITION_ID, e.COHORT_OF_INTEREST, e.T2DM, e.CENSOR, e.PERSON_ID, e.COHORT_START_DATE, e.COHORT_END_DATE, e.GENDER_CONCEPT_ID, e.AGE;

/****Find the position of the DKA on the claims*/

--HINT DISTRIBUTE_ON_KEY(person_id)
SELECT dka.DB, dka.COHORT_DEFINITION_ID, dka.COHORT_OF_INTEREST, dka.T2DM,
	dka.CENSOR, dka.PERSON_ID, dka.COHORT_START_DATE, dka.COHORT_END_DATE, dka.GENDER_CONCEPT_ID, dka.AGE,
	dka.DKA, dka.DKA_INDEX_DATE,
	CASE WHEN dka.DKA_INDEX_DATE IS NULL THEN 0 ELSE DATEDIFF(dd,dka.COHORT_START_DATE,dka.DKA_INDEX_DATE) END AS DAYS_TO_DKA, /*Also used this step to calculate days till DKA*/
	MAX(CASE WHEN co.PERSON_ID IS NULL THEN 0 ELSE 1 END) AS DKA_FIRST_POSITION
INTO #qualified_events_DKA
FROM #qualified_DKA_prep dka
	LEFT OUTER JOIN @cdm_database_schema.CONDITION_OCCURRENCE co
		ON co.PERSON_ID = dka.PERSON_ID
		AND co.CONDITION_CONCEPT_ID IN (
			SELECT CONCEPT_ID FROM @target_database_schema.@code_list WHERE CODE_LIST_NAME = 'DKA'
		)
		AND co.CONDITION_START_DATE = dka.DKA_INDEX_DATE
		AND co.CONDITION_TYPE_CONCEPT_ID IN (
			/*Remember claims can move around, so we use the VISIT_TYPE to filter to IP not the CONDITION_TYPE*/
			38000183,	/*Inpatient detail - primary*/
			38000184,	/*Inpatient detail - 1st position*/
			38000215,	/*Outpatient detail - 1st position*/
			38000230,	/*Outpatient header - 1st position*/
			44786627,	/*Primary Condition*/
			44786628	/*First Position Condition*/
		)
	LEFT OUTER JOIN @cdm_database_schema.VISIT_OCCURRENCE vo
		ON vo.PERSON_ID = co.PERSON_ID
		AND vo.VISIT_OCCURRENCE_ID = co.VISIT_OCCURRENCE_ID
		AND vo.VISIT_TYPE_CONCEPT_ID IN (
			9203, --(ER)
			9201, --(IP)
			262	  --(ERIP)
		)
GROUP BY dka.DB, dka.COHORT_DEFINITION_ID, dka.COHORT_OF_INTEREST, dka.T2DM,
	dka.CENSOR, dka.PERSON_ID, dka.COHORT_START_DATE, dka.COHORT_END_DATE,
	dka.GENDER_CONCEPT_ID, dka.AGE,	dka.DKA, dka.DKA_INDEX_DATE;

/****Calcualte Median days to DKA, in SQL like the #bossLady I am  ^_^ */

--HINT DISTRIBUTE_ON_KEY(COHORT_DEFINITION_ID)
SELECT DB, COHORT_DEFINITION_ID, DKA,
	AVG(DAYS_TO_DKA * 1.0) AS MEDIAN_DKA
INTO #median_DKA
FROM
(
	SELECT	DB,	COHORT_DEFINITION_ID, DKA, DAYS_TO_DKA, PERSON_ID,
		ROW_NUMBER() OVER (
			PARTITION BY DB, COHORT_DEFINITION_ID, DKA
			ORDER BY DAYS_TO_DKA ASC, PERSON_ID) AS RowAsc,
		ROW_NUMBER() OVER (
			PARTITION BY DB, COHORT_DEFINITION_ID, DKA
			ORDER BY DAYS_TO_DKA DESC, PERSON_ID DESC) AS RowDesc
	FROM #qualified_events_DKA
) x
WHERE RowAsc IN (RowDesc, RowDesc - 1, RowDesc + 1)
GROUP BY DB,COHORT_DEFINITION_ID,DKA;

/****Find Precipitating Events*/

--HINT DISTRIBUTE_ON_KEY(person_id)
SELECT e.DB, e.COHORT_DEFINITION_ID, e.DKA, e.PERSON_ID, e.DKA_INDEX_DATE,
	MAX(CASE WHEN vo.PERSON_ID IS NULL THEN 0 ELSE 1 END) AS HOSPITAL,
	MAX(CASE WHEN po.PERSON_ID IS NULL THEN 0 ELSE 1 END) AS SURGERY_PROC,
	MAX(CASE WHEN o.PERSON_ID IS NULL THEN 0 ELSE 1 END) AS SURGERY_OBS,
	MAX(CASE WHEN co1.PERSON_ID IS NULL THEN 0 ELSE 1 END) AS UTI,
	MAX(CASE WHEN co2.PERSON_ID IS NULL THEN 0 ELSE 1 END) AS URI,
	CASE WHEN MONTH(e.DKA_INDEX_DATE) IN (11,12,1,2) THEN 1 ELSE 0 END AS WINTER_SEASON
INTO #precipitating_events
FROM #qualified_events_DKA e
	/*Hospitalization*/
	LEFT OUTER JOIN @cdm_database_schema.VISIT_OCCURRENCE vo
		ON vo.PERSON_ID = e.PERSON_ID
		AND e.DKA = 1
		AND (
			(vo.VISIT_START_DATE >= DATEADD(dd,-30,e.DKA_INDEX_DATE)
			AND vo.VISIT_START_DATE < e.DKA_INDEX_DATE)
			OR (e.DKA_INDEX_DATE > vo.VISIT_START_DATE
			AND e.DKA_INDEX_DATE <= vo.VISIT_END_DATE)
		)
		AND vo.VISIT_CONCEPT_ID IN (
			9203, --(ER)
			9201, --(IP)
			262	  --(ERIP)
		)
	/*Surgery*/
	LEFT OUTER JOIN @cdm_database_schema.PROCEDURE_OCCURRENCE po
		ON po.PERSON_ID = e.PERSON_ID
		AND e.DKA = 1
		AND po.PROCEDURE_DATE >= DATEADD(dd,-30,e.DKA_INDEX_DATE)
		AND po.PROCEDURE_DATE < e.DKA_INDEX_DATE
		AND po.PROCEDURE_CONCEPT_ID IN (
			SELECT CONCEPT_ID FROM @target_database_schema.@code_list WHERE CODE_LIST_NAME = 'Surgery'
		)
	LEFT OUTER JOIN @cdm_database_schema.OBSERVATION o
		ON o.PERSON_ID = e.PERSON_ID
		AND e.DKA = 1
		AND o.OBSERVATION_DATE >= DATEADD(dd,-30,e.DKA_INDEX_DATE)
		AND o.OBSERVATION_DATE < e.DKA_INDEX_DATE
		AND o.OBSERVATION_CONCEPT_ID IN (
			SELECT CONCEPT_ID FROM @target_database_schema.@code_list WHERE CODE_LIST_NAME = 'Surgery'
		)
	/*UTI*/
	LEFT OUTER JOIN @cdm_database_schema.CONDITION_OCCURRENCE co1
		ON co1.PERSON_ID = e.PERSON_ID
		AND e.DKA = 1
		AND co1.CONDITION_START_DATE >= DATEADD(dd,-30,e.DKA_INDEX_DATE)
		AND co1.CONDITION_START_DATE < e.DKA_INDEX_DATE
		AND co1.CONDITION_CONCEPT_ID IN (
			SELECT CONCEPT_ID FROM @target_database_schema.@code_list WHERE CODE_LIST_NAME = 'UTI'
		)
	/*URI*/
	LEFT OUTER JOIN @cdm_database_schema.CONDITION_OCCURRENCE co2
		ON co2.PERSON_ID = e.PERSON_ID
		AND e.DKA = 1
		AND co2.CONDITION_START_DATE >= DATEADD(dd,-30,e.DKA_INDEX_DATE)
		AND co2.CONDITION_START_DATE < e.DKA_INDEX_DATE
		AND co2.CONDITION_CONCEPT_ID IN (
			SELECT CONCEPT_ID FROM @target_database_schema.@code_list WHERE CODE_LIST_NAME = 'URI'
		)
GROUP BY e.DB, e.COHORT_DEFINITION_ID, e.DKA, e.PERSON_ID, e.DKA_INDEX_DATE;

/******************************************************************************/
/*INSULIN EVENTS*/
/******************************************************************************/

/****Find first insulin*/

--HINT DISTRIBUTE_ON_KEY(person_id)
SELECT *
INTO #qualified_insulin
FROM (
	SELECT c.DB, c.COHORT_DEFINITION_ID, c.DKA, c.PERSON_ID, c.COHORT_START_DATE, c.COHORT_END_DATE, c.GENDER_CONCEPT_ID, c.AGE,
		de.DRUG_CONCEPT_ID, de.DRUG_ERA_START_DATE AS DRUG_EXPOSURE_START_DATE,
		CASE WHEN de.DRUG_ERA_START_DATE < c.COHORT_START_DATE THEN 1 ELSE 0 END AS INSULIN_BEFORE_INDEX,
		CASE WHEN de.DRUG_ERA_START_DATE > c.COHORT_START_DATE THEN 1 ELSE 0 END AS INSULIN_AFTER_INDEX,
		CASE WHEN de.DRUG_ERA_START_DATE = c.COHORT_START_DATE THEN 1 ELSE 0 END AS INSULIN_ON_INDEX,
		0 AS NO_INSULIN,
		ROW_NUMBER() OVER(PARTITION BY c.DB, c.COHORT_DEFINITION_ID, c.DKA, c.PERSON_ID ORDER BY c.DB, c.COHORT_DEFINITION_ID, c.DKA, c.PERSON_ID, de.DRUG_ERA_START_DATE, de.DRUG_CONCEPT_ID) AS ROW_NUM
	FROM #qualified_events_DKA c
		JOIN @cdm_database_schema.OBSERVATION_PERIOD op
			ON op.PERSON_ID = c.PERSON_ID
			AND c.COHORT_START_DATE BETWEEN op.OBSERVATION_PERIOD_START_DATE AND op.OBSERVATION_PERIOD_END_DATE
		JOIN @cdm_database_schema.DRUG_ERA	de
			ON de.PERSON_ID = c.PERSON_ID
			AND de.DRUG_CONCEPT_ID IN (
				SELECT CONCEPT_ID FROM @target_database_schema.@code_list WHERE CODE_LIST_NAME = 'Insulin'
			)
			AND de.DRUG_ERA_START_DATE BETWEEN op.OBSERVATION_PERIOD_START_DATE AND op.OBSERVATION_PERIOD_END_DATE
) z
WHERE ROW_NUM = 1;

/****Add the people missing insulin, I like to always have everyone to help catch errors*/

INSERT INTO #qualified_insulin
SELECT DISTINCT
  d.DB, d.COHORT_DEFINITION_ID, d.DKA, d.PERSON_ID, d.COHORT_START_DATE,
  d.COHORT_END_DATE, d.GENDER_CONCEPT_ID, d.AGE,
	0 AS DRUG_CONCEPT_ID,
	'01/01/1970' AS DRUG_EXPOSURE_START_DATE,
	0 AS INSULIN_BEFORE_INDEX,
	0 AS INSULIN_AFTER_INDEX,
	0 AS INSULIN_ON_INDEX,
	1 AS NO_INSULIN,
	1 AS ROW_NUM
FROM #qualified_events_DKA d
	LEFT OUTER JOIN #qualified_insulin e
		ON e.DB = d.DB
		AND e.COHORT_DEFINITION_ID = d.COHORT_DEFINITION_ID
		AND e.DKA = d.DKA
		AND e.PERSON_ID = d.PERSON_ID
WHERE e.PERSON_ID IS NULL;



/*******************************************************************************/
/****BEAST MODE ACTIVATED - BUILD TABLE*****************************************/
/*******************************************************************************/



WITH CTE_AGE_BUCKETS AS (
	/*Ensures we see all age buckets for each group - BRUTE FORCE!!!!!!*/
	SELECT 1 AS BUCKET_ORDER, '0-4' AS AGE_GROUPING, 0 AS MIN_AGE, 4 AS MAX_AGE
	UNION ALL
	SELECT 2 AS BUCKET_ORDER, '5-9' AS AGE_GROUPING, 5 AS MIN_AGE, 9 AS MAX_AGE
	UNION ALL
	SELECT 3 AS BUCKET_ORDER, '10-14' AS AGE_GROUPING, 10 AS MIN_AGE, 14 AS MAX_AGE
	UNION ALL
	SELECT 4 AS BUCKET_ORDER, '15-19' AS AGE_GROUPING, 15 AS MIN_AGE, 19 AS MAX_AGE
	UNION ALL
	SELECT 5 AS BUCKET_ORDER, '20-24' AS AGE_GROUPING, 20 AS MIN_AGE, 24 AS MAX_AGE
	UNION ALL
	SELECT 6 AS BUCKET_ORDER, '25-29' AS AGE_GROUPING, 25 AS MIN_AGE, 29 AS MAX_AGE
	UNION ALL
	SELECT 7 AS BUCKET_ORDER, '30-34' AS AGE_GROUPING, 30 AS MIN_AGE, 34 AS MAX_AGE
	UNION ALL
	SELECT 8 AS BUCKET_ORDER, '35-39' AS AGE_GROUPING, 35 AS MIN_AGE, 39 AS MAX_AGE
	UNION ALL
	SELECT 9 AS BUCKET_ORDER, '40-44' AS AGE_GROUPING, 40 AS MIN_AGE, 44 AS MAX_AGE
	UNION ALL
	SELECT 10 AS BUCKET_ORDER, '45-49' AS AGE_GROUPING, 45 AS MIN_AGE, 49 AS MAX_AGE
	UNION ALL
	SELECT 11 AS BUCKET_ORDER, '50-54' AS AGE_GROUPING, 50 AS MIN_AGE, 54 AS MAX_AGE
	UNION ALL
	SELECT 12 AS BUCKET_ORDER, '55-59' AS AGE_GROUPING, 55 AS MIN_AGE, 59 AS MAX_AGE
	UNION ALL
	SELECT 13 AS BUCKET_ORDER, '60-64' AS AGE_GROUPING, 60 AS MIN_AGE, 64 AS MAX_AGE
	UNION ALL
	SELECT 14 AS BUCKET_ORDER, '65-69' AS AGE_GROUPING, 65 AS MIN_AGE, 69 AS MAX_AGE
	UNION ALL
	SELECT 15 AS BUCKET_ORDER, '70-74' AS AGE_GROUPING, 70 AS MIN_AGE, 74 AS MAX_AGE
	UNION ALL
	SELECT 16 AS BUCKET_ORDER, '75-79' AS AGE_GROUPING, 75 AS MIN_AGE, 79 AS MAX_AGE
	UNION ALL
	SELECT 17 AS BUCKET_ORDER, '80-84' AS AGE_GROUPING, 80 AS MIN_AGE, 84 AS MAX_AGE
	UNION ALL
	SELECT 18 AS BUCKET_ORDER, '85-89' AS AGE_GROUPING, 85 AS MIN_AGE, 89 AS MAX_AGE
	UNION ALL
	SELECT 19 AS BUCKET_ORDER, '90-94' AS AGE_GROUPING, 90 AS MIN_AGE, 94 AS MAX_AGE
	UNION ALL
	SELECT 20 AS BUCKET_ORDER, '95-99' AS AGE_GROUPING, 95 AS MIN_AGE, 99 AS MAX_AGE
	UNION ALL
	SELECT 21 AS BUCKET_ORDER, '100+' AS AGE_GROUPING, 100 AS MIN_AGE, 999 AS MAX_AGE
),
CTE_DKA_BUCKETS AS (
	SELECT 1 AS DKA
	UNION ALL
	SELECT 0 AS DKA
),
CTE_ANALYSIS_BUCKETS AS (
	SELECT 1 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'Total Persons' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 2 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'Female' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 3 AS STAT_ORDER_NUMBER_1, 0 AS STAT_ORDER_NUMBER_2, 'Age, mean (SD)' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 3 AS STAT_ORDER_NUMBER_1, BUCKET_ORDER AS STAT_ORDER_NUMBER_2, AGE_GROUPING AS STAT_TYPE, MIN_AGE, MAX_AGE
	FROM CTE_AGE_BUCKETS
	UNION ALL
	SELECT 4 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'T2DM Narrow Definition Met' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 5 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'First Insulin Prescriptions Before (<) but not After' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 5 AS STAT_ORDER_NUMBER_1, 2 AS STAT_ORDER_NUMBER_2, 'First Insulin Prescriptions Neither Before or After (Includes Index)' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 5 AS STAT_ORDER_NUMBER_1, 3 AS STAT_ORDER_NUMBER_2, 'First Insulin Prescriptions After (>) but not Before' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 5 AS STAT_ORDER_NUMBER_1, 4 AS STAT_ORDER_NUMBER_2, 'First Insulin Prescriptions On Index' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 6 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'High-dose SGLT2i at Index' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 7 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'Charlson' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 8 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'CHADS2' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 9 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'DCSI' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 10 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'Index to DKA:  Mean (SD) days' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 10 AS STAT_ORDER_NUMBER_1, 2 AS STAT_ORDER_NUMBER_2, 'Index to DKA:  Median (Min, Max) days' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 11 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'Precipitating Events (w/in 30 days of DKA):  Hospitalization' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 11 AS STAT_ORDER_NUMBER_1, 2 AS STAT_ORDER_NUMBER_2, 'Precipitating Events (w/in 30 days of DKA):  Surgery' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 11 AS STAT_ORDER_NUMBER_1, 3 AS STAT_ORDER_NUMBER_2, 'Precipitating Events (w/in 30 days of DKA):  Urinary Tract Infection' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 11 AS STAT_ORDER_NUMBER_1, 4 AS STAT_ORDER_NUMBER_2, 'Precipitating Events (w/in 30 days of DKA):  Upper Respiratory Infections' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 11 AS STAT_ORDER_NUMBER_1, 5 AS STAT_ORDER_NUMBER_2, 'Precipitating Events (w/in 30 days of DKA):  Winter Season' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
	UNION ALL
	SELECT 12 AS STAT_ORDER_NUMBER_1, 1 AS STAT_ORDER_NUMBER_2, 'DKA listed as First/Primary Diagnosis' AS STAT_TYPE, NULL AS MIN_AGE, NULL AS MAX_AGE
),
CTE_COHORT AS (
	SELECT *
	FROM #qualified_events_DKA
),
CTE_TABLE_UNIVERSE AS (
	/*Table we need to populate*/
	SELECT *
	FROM (
		SELECT DISTINCT DB, COHORT_DEFINITION_ID, COHORT_OF_INTEREST, T2DM, CENSOR
		FROM CTE_COHORT
	) z, CTE_DKA_BUCKETS, CTE_ANALYSIS_BUCKETS
),
CTE_CALCULATE_MEDIAN_DKA AS (
	SELECT *
	FROM #median_DKA
),
CTE_COHORT_TOTALS AS (
	/*Get Denominator*/
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		COUNT(DISTINCT PERSON_ID) AS STAT,
		1.00 AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT c
			ON c.DB = u.DB
			AND c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND c.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 1
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2
),
CTE_COUNT_FEMALES AS (
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		COUNT(DISTINCT PERSON_ID) AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT c
			ON c.DB = u.DB
			AND c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND c.DKA = u.DKA
		JOIN CTE_COHORT_TOTALS t
			ON t.DB = c.DB
			AND t.COHORT_DEFINITION_ID = c.COHORT_DEFINITION_ID
			AND t.DKA = c.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 2
	AND c.GENDER_CONCEPT_ID = 8532
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
),
CTE_COUNT_AGES AS (
	/*AVG Age and SD*/
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		NULL AS STAT,
		NULL AS STAT_PCT,
		CONCAT(
			CAST(CAST(AVG(c.AGE*1.0) AS DECIMAL(6,1)) AS VARCHAR(10)),
			' (',
			CAST(CAST(STDEV(c.AGE*1.0) AS DECIMAL(6,1)) AS VARCHAR(10)),
			')'
		) AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		JOIN CTE_COHORT c
			ON c.DB = u.DB
			AND c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND c.DKA = u.DKA
			AND u.STAT_ORDER_NUMBER_1 = 3
			AND u.STAT_ORDER_NUMBER_2 = 0
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2
	UNION ALL
	/*By Age Buckets*/
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT c
			ON c.DB = u.DB
			AND c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND c.DKA = u.DKA
			AND c.AGE BETWEEN u.MIN_AGE AND u.MAX_AGE
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 3
	AND u.STAT_ORDER_NUMBER_2 != 0
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
),
CTE_COUNT_T2DM_NARROW AS (
	/*How many people also met the narrow definition of T2DM*/
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT c2.PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT c2.PERSON_ID) END AS STAT,
		COUNT(DISTINCT c2.PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT c1
			ON c1.DB = u.DB
			AND c1.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND c1.DKA = u.DKA
		LEFT OUTER JOIN CTE_COHORT c2
			ON c2.DB = c1.DB
			AND c2.COHORT_OF_INTEREST = c1.COHORT_OF_INTEREST
			AND c2.PERSON_ID = c1.PERSON_ID
			AND c2.T2DM = 'NARROW'
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 4
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
),
CTE_COUNT_INSULIN AS (
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN #qualified_insulin e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND INSULIN_BEFORE_INDEX = 1
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 5
	AND u.STAT_ORDER_NUMBER_2 = 1
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN #qualified_insulin e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND NO_INSULIN = 1
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 5
	AND u.STAT_ORDER_NUMBER_2 = 2
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN #qualified_insulin e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND INSULIN_AFTER_INDEX = 1
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 5
	AND u.STAT_ORDER_NUMBER_2 = 3
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN #qualified_insulin e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND INSULIN_ON_INDEX = 1
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 5
	AND u.STAT_ORDER_NUMBER_2 = 4
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
),
CTE_COUNT_HIGH_DOSE AS (
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		COUNT(DISTINCT c.PERSON_ID) AS STAT,
		COUNT(DISTINCT c.PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT c
			ON c.DB = u.DB
			AND c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND c.DKA = u.DKA
		LEFT OUTER JOIN @cdm_database_schema.DRUG_EXPOSURE de
			ON de.PERSON_ID = c.PERSON_ID
			AND de.DRUG_CONCEPT_ID IN (
				SELECT CONCEPT_ID FROM @target_database_schema.@code_list WHERE CODE_LIST_NAME = 'High-Dose SGLT2i'
			)
			AND c.COHORT_START_DATE BETWEEN de.DRUG_EXPOSURE_START_DATE AND de.DRUG_EXPOSURE_END_DATE
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = c.DB
			AND t.COHORT_DEFINITION_ID = c.COHORT_DEFINITION_ID
			AND t.DKA = c.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 6
	AND de.PERSON_ID IS NOT NULL
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
),
CTE_COUNT_SCORES AS (
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		NULL AS STAT,
		NULL AS STAT_PCT,
		CAST(CAST(AVG(c.COVARIATE_VALUE*1.0) AS DECIMAL(6,2)) AS VARCHAR(10)) AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
		LEFT OUTER JOIN @target_database_schema.@study_CHARLSON_@dbID c
			ON c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND c.ROW_ID = e.PERSON_ID
	WHERE u.STAT_ORDER_NUMBER_1 = 7
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		NULL AS STAT,
		NULL AS STAT_PCT,
		CAST(CAST(AVG(c.COVARIATE_VALUE*1.0) AS DECIMAL(6,2)) AS VARCHAR(10)) AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
		LEFT OUTER JOIN @target_database_schema.@study_CHADS2_@dbID c
			ON c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND c.ROW_ID = e.PERSON_ID
	WHERE u.STAT_ORDER_NUMBER_1 = 8
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		NULL AS STAT,
		NULL AS STAT_PCT,
		CAST(CAST(AVG(c.COVARIATE_VALUE*1.0) AS DECIMAL(6,2)) AS VARCHAR(10)) AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
		LEFT OUTER JOIN @target_database_schema.@study_DCSI_@dbID c
			ON c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND c.ROW_ID = e.PERSON_ID
	WHERE u.STAT_ORDER_NUMBER_1 = 9
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2
),
CTE_COUNT_DAYS_TO_DKA AS (
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		NULL AS STAT,
		NULL AS STAT_PCT,
		CASE
			WHEN AVG(e.DAYS_TO_DKA*1.0) IS NULL THEN NULL ELSE
				CONCAT(
					CAST(CAST(AVG(e.DAYS_TO_DKA*1.0) AS DECIMAL(6,1)) AS VARCHAR(10)),
					' (',
					CAST(CAST(STDEV(e.DAYS_TO_DKA*1.0) AS DECIMAL(6,1)) AS VARCHAR(10)),
					')')
			END
		AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 10
	AND u.STAT_ORDER_NUMBER_2 = 1
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		NULL AS STAT,
		NULL AS STAT_PCT,
		CASE
			WHEN m.MEDIAN_DKA IS NULL THEN NULL ELSE
				CONCAT(
					CAST(CAST(MIN(m.MEDIAN_DKA*1.0) AS DECIMAL(6,1)) AS VARCHAR(10)),
					' (',
					CAST(CAST(MIN(e.DAYS_TO_DKA*1.0) AS DECIMAL(6,1)) AS VARCHAR(10)),
					', ',
					CAST(CAST(MAX(e.DAYS_TO_DKA*1.0) AS DECIMAL(6,1)) AS VARCHAR(10)),
					')')
			END
		AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
		LEFT OUTER JOIN CTE_CALCULATE_MEDIAN_DKA m
			ON m.DB = u.DB
			AND m.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND m.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 10
	AND u.STAT_ORDER_NUMBER_2 = 2
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, m.MEDIAN_DKA
),
CTE_COUNT_PRECIPITATING_EVENTS AS (
	/*Precipitating Events:  Hospitalization, Surgeries, UTI, URI, and Winter Season*/
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN #precipitating_events e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND e.HOSPITAL = 1
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 11
	AND u.STAT_ORDER_NUMBER_2 = 1
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN #precipitating_events e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND (e.SURGERY_PROC = 1 OR e.SURGERY_OBS = 1)
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 11
	AND u.STAT_ORDER_NUMBER_2 = 2
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN #precipitating_events e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND e.UTI = 1
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 11
	AND u.STAT_ORDER_NUMBER_2 = 3
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN #precipitating_events e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND e.URI = 1
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 11
	AND u.STAT_ORDER_NUMBER_2 = 4
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
	UNION ALL
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN #precipitating_events e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND e.WINTER_SEASON = 1
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 11
	AND u.STAT_ORDER_NUMBER_2 = 5
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
),
CTE_DKA_FIRST_POSITION AS (
	/*Which DKAs were in the first psoition of their IP / ER Visit*/
	SELECT u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2,
		CASE WHEN COUNT(DISTINCT PERSON_ID) IS NULL THEN 0 ELSE COUNT(DISTINCT PERSON_ID) END AS STAT,
		COUNT(DISTINCT PERSON_ID) *1.0 / t.STAT AS STAT_PCT,
		NULL AS STAT_OTHER
	FROM CTE_TABLE_UNIVERSE u
		LEFT OUTER JOIN CTE_COHORT e
			ON e.DB = u.DB
			AND e.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND e.DKA = u.DKA
			AND e.DKA_FIRST_POSITION = 1
		LEFT OUTER JOIN CTE_COHORT_TOTALS t
			ON t.DB = u.DB
			AND t.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
			AND t.DKA = u.DKA
	WHERE u.STAT_ORDER_NUMBER_1 = 12
	AND u.STAT_ORDER_NUMBER_2 = 1
	GROUP BY u.DB, u.COHORT_DEFINITION_ID, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, t.STAT
),
CTE_UNION AS (
	/*String Everything Together*/
	SELECT *	FROM CTE_COHORT_TOTALS
	UNION ALL
	SELECT *	FROM CTE_COUNT_FEMALES
	UNION ALL
	SELECT *	FROM CTE_COUNT_AGES
	UNION ALL
	SELECT *	FROM CTE_COUNT_T2DM_NARROW
	UNION ALL
	SELECT *	FROM CTE_COUNT_INSULIN
	UNION ALL
	SELECT *	FROM CTE_COUNT_HIGH_DOSE
	UNION ALL
	SELECT *	FROM CTE_COUNT_DAYS_TO_DKA
	UNION ALL
	SELECT *	FROM CTE_COUNT_PRECIPITATING_EVENTS
	UNION ALL
	SELECT *	FROM CTE_DKA_FIRST_POSITION
	UNION ALL
	SELECT *	FROM CTE_COUNT_SCORES
)
/*Some formatting and one final force to make sure we report all results*/
SELECT u.DB, u.COHORT_DEFINITION_ID, u.COHORT_OF_INTEREST, u.T2DM, u.CENSOR, u.DKA, u.STAT_ORDER_NUMBER_1, u.STAT_ORDER_NUMBER_2, u.STAT_TYPE,
	CASE WHEN t.STAT IS NULL THEN 0 ELSE t.STAT END AS STAT,
	CASE WHEN t.STAT_PCT IS NULL THEN 0 ELSE t.STAT_PCT END AS STAT_PCT,
	STAT_OTHER
INTO #temp_results
FROM CTE_TABLE_UNIVERSE u
	LEFT OUTER JOIN CTE_UNION t
		ON u.DB = t.DB
		AND u.COHORT_DEFINITION_ID = t.COHORT_DEFINITION_ID
		AND u.DKA = t.DKA
		AND u.STAT_ORDER_NUMBER_1 = t.STAT_ORDER_NUMBER_1
		AND u.STAT_ORDER_NUMBER_2 = t.STAT_ORDER_NUMBER_2;


INSERT @target_database_schema.@target_table (DB, COHORT_DEFINITION_ID, COHORT_OF_INTEREST, T2DM, CENSOR, DKA, STAT_ORDER_NUMBER_1, STAT_ORDER_NUMBER_2, STAT_TYPE, STAT, STAT_PCT, STAT_OTHER)
SELECT DB, COHORT_DEFINITION_ID, COHORT_OF_INTEREST, T2DM, CENSOR, DKA, STAT_ORDER_NUMBER_1, STAT_ORDER_NUMBER_2, STAT_TYPE, STAT, STAT_PCT, STAT_OTHER
FROM #temp_results;