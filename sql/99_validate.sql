SELECT '== SHOW CREATE TABLE ==' AS info;
SHOW CREATE TABLE project_db.ClimateData;

SELECT '== HUMIDITY COLUMN ==' AS info;
SHOW COLUMNS FROM project_db.ClimateData LIKE 'humidity';

SELECT '== TOTAL ROWS ==' AS info;
SELECT COUNT(*) AS total_rows FROM project_db.ClimateData;

SELECT '== SAMPLE HOT ROWS (temp>20) ==' AS info;
SELECT location, record_date, temperature, humidity
FROM project_db.ClimateData
WHERE temperature > 20
ORDER BY record_date DESC
LIMIT 10;
