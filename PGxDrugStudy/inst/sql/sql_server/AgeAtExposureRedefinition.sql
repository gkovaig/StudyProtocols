# query-using-age-at-exposure-excluding-topical--refined-definition-of-incident-use--only-pharmacokinetic-core-list.sql

WITH count_of_distinct_substances_per_person AS (
	WITH filtered_list_of_exposed_persons_and_substances AS (	
		SELECT DISTINCT DRUG_EXPOSURE.person_id AS exposed_person_id, CONCEPT_ANCESTOR.ancestor_concept_id as substance_id
		FROM DRUG_EXPOSURE, CONCEPT_ANCESTOR, CONCEPT_RELATIONSHIP, PERSON
		WHERE DRUG_EXPOSURE.DRUG_CONCEPT_ID = CONCEPT_ANCESTOR.descendant_concept_id
			AND   CONCEPT_ANCESTOR.ancestor_concept_id IN (1436650,19024063,710062,757688,19014878,1337620,1346823,797617,798834,1322184,800878,1201620,716968,738156,715259,715939,904453,1354860,955632,19055982,19059796,1597756,766529,778268,1367268,929887,1307046,725131,19010652,721724,785788,923645,1124957,948078,722031,19035344,740910,1353256,911735,735979,739138,1539403,950637,1436678,19056756,1437379,1502855,742185,1103314,705755,743670,1714277,1310149,19010886) --ids of substances form pharmacokinetic core list
			AND   CONCEPT_RELATIONSHIP.relationship_ID = 4  --relationship points to dosage form concept
			AND   DRUG_EXPOSURE.DRUG_CONCEPT_ID = CONCEPT_RELATIONSHIP.concept_id_1 
			AND   CONCEPT_RELATIONSHIP.concept_id_2 NOT IN (19082224,19082228,19082227,19095973,19082225,19095912,19008697,19082109,19130307,19095972,19082286,19126590,19009068,19016586,19082110,19082108,19102295,19095900,19082226,19057400,19112648,19082222,19095975,40227748,19135439,19135438,19135440,19135446,19082107) --concept ids for topical dosage forms
			AND   DRUG_EXPOSURE.DRUG_EXPOSURE_START_DATE >= DATE '2009-01-01'
			AND   DRUG_EXPOSURE.DRUG_EXPOSURE_START_DATE <= DATE '2012-12-31'
			AND   DRUG_EXPOSURE.person_id = PERSON.person_id 
			AND   (YEAR(DRUG_EXPOSURE.DRUG_EXPOSURE_START_DATE) - PERSON.year_of_birth >= 65)
		MINUS
		SELECT DISTINCT DRUG_EXPOSURE.person_id AS exposed_person_id, CONCEPT_ANCESTOR.ancestor_concept_id -- lists substance exposures BEFORE the selected time window. Those don't 'count' because we want to know about incident use.
		FROM DRUG_EXPOSURE, CONCEPT_ANCESTOR, CONCEPT_RELATIONSHIP
		WHERE DRUG_EXPOSURE.DRUG_CONCEPT_ID = CONCEPT_ANCESTOR.descendant_concept_id
			AND   CONCEPT_ANCESTOR.ancestor_concept_id IN (1436650,19024063,710062,757688,19014878,1337620,1346823,797617,798834,1322184,800878,1201620,716968,738156,715259,715939,904453,1354860,955632,19055982,19059796,1597756,766529,778268,1367268,929887,1307046,725131,19010652,721724,785788,923645,1124957,948078,722031,19035344,740910,1353256,911735,735979,739138,1539403,950637,1436678,19056756,1437379,1502855,742185,1103314,705755,743670,1714277,1310149,19010886) --ids of substances form pharmacokinetic core list
			AND   CONCEPT_RELATIONSHIP.relationship_ID = 4  --relationship points to dosage form concept
			AND   DRUG_EXPOSURE.DRUG_CONCEPT_ID = CONCEPT_RELATIONSHIP.concept_id_1 
			AND   CONCEPT_RELATIONSHIP.concept_id_2 NOT IN (19082224,19082228,19082227,19095973,19082225,19095912,19008697,19082109,19130307,19095972,19082286,19126590,19009068,19016586,19082110,19082108,19102295,19095900,19082226,19057400,19112648,19082222,19095975,40227748,19135439,19135438,19135440,19135446,19082107) --concept ids for topical dosage forms
			AND   DRUG_EXPOSURE.DRUG_EXPOSURE_START_DATE < DATE '2009-01-01'
	)
	SELECT exposed_person_id, COUNT(DISTINCT(substance_id)) AS distinct_substance_count
	FROM filtered_list_of_exposed_persons_and_substances
	GROUP BY exposed_person_id
)
SELECT COUNT(exposed_person_id) AS person_count, distinct_substance_count 
FROM count_of_distinct_substances_per_person
GROUP BY distinct_substance_count
ORDER BY distinct_substance_count
