USE project_db;

-- Add `humidity` only if it doesn't already exist
SET @sql := IF(
  EXISTS(
    SELECT 1
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME   = 'ClimateData'
      AND COLUMN_NAME  = 'humidity'
  ),
  'SELECT "humidity column already present"',
  'ALTER TABLE ClimateData ADD COLUMN humidity FLOAT NOT NULL DEFAULT 50.0'
);

PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;