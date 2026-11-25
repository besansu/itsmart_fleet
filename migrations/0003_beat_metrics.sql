-- Live CPU/RAM/disk per heartbeat.
ALTER TABLE beats ADD COLUMN cpu REAL;
ALTER TABLE beats ADD COLUMN mem REAL;
ALTER TABLE beats ADD COLUMN disk REAL;
