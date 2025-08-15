CREATE DATABASE IF NOT EXISTS project_db;

CREATE TABLE IF NOT EXISTS project_db.ClimateData (
  record_id INT PRIMARY KEY AUTO_INCREMENT,
  location VARCHAR(100) NOT NULL,
  record_date DATE NOT NULL,
  temperature FLOAT NOT NULL,
  precipitation FLOAT NOT NULL
) ENGINE=InnoDB;
