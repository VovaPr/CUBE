-- Target Server Rollback - Step 1
-- Drops indexes, tables, and Monitoring schema from dba_db on the target server
-- WARNING: All monitoring data will be permanently deleted.

USE dba_db;
GO

-- Drop indexes first
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FailedJobsAlerts_AlertSentTime')
    DROP INDEX IX_FailedJobsAlerts_AlertSentTime ON Monitoring.FailedJobsAlerts;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Servers_CentralServerName')
    DROP INDEX IX_Servers_CentralServerName ON Monitoring.Servers;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Jobs_LastRunDate')
    DROP INDEX IX_Jobs_LastRunDate ON Monitoring.Jobs;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Jobs_ServerName')
    DROP INDEX IX_Jobs_ServerName ON Monitoring.Jobs;
GO

-- Drop tables
IF OBJECT_ID('Monitoring.FailedJobsAlerts', 'U') IS NOT NULL
BEGIN
    DROP TABLE Monitoring.FailedJobsAlerts;
    PRINT 'Table Monitoring.FailedJobsAlerts dropped.';
END

IF OBJECT_ID('Monitoring.Servers', 'U') IS NOT NULL
BEGIN
    DROP TABLE Monitoring.Servers;
    PRINT 'Table Monitoring.Servers dropped.';
END

IF OBJECT_ID('Monitoring.Jobs', 'U') IS NOT NULL
BEGIN
    DROP TABLE Monitoring.Jobs;
    PRINT 'Table Monitoring.Jobs dropped.';
END

-- Drop any remaining objects in Monitoring schema (legacy compatibility)
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = @sql + N'DROP VIEW ' + QUOTENAME(s.name) + N'.' + QUOTENAME(v.name) + N';' + CHAR(10)
FROM sys.views v
JOIN sys.schemas s ON s.schema_id = v.schema_id
WHERE s.name = 'Monitoring';

IF @sql <> N''
BEGIN
    EXEC sp_executesql @sql;
    PRINT 'Remaining views in Monitoring schema dropped.';
END

SET @sql = N'';
SELECT @sql = @sql + N'DROP PROCEDURE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(p.name) + N';' + CHAR(10)
FROM sys.procedures p
JOIN sys.schemas s ON s.schema_id = p.schema_id
WHERE s.name = 'Monitoring';

IF @sql <> N''
BEGIN
    EXEC sp_executesql @sql;
    PRINT 'Remaining procedures in Monitoring schema dropped.';
END

SET @sql = N'';
SELECT @sql = @sql + N'DROP FUNCTION ' + QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) + N';' + CHAR(10)
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = 'Monitoring'
  AND o.type IN ('FN', 'IF', 'TF', 'FS', 'FT');

IF @sql <> N''
BEGIN
    EXEC sp_executesql @sql;
    PRINT 'Remaining functions in Monitoring schema dropped.';
END

SET @sql = N'';
SELECT @sql = @sql + N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
    + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';' + CHAR(10)
FROM sys.foreign_keys fk
JOIN sys.tables t ON t.object_id = fk.parent_object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = 'Monitoring';

IF @sql <> N''
BEGIN
    EXEC sp_executesql @sql;
    PRINT 'Remaining foreign keys in Monitoring schema dropped.';
END

SET @sql = N'';
SELECT @sql = @sql + N'DROP TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N';' + CHAR(10)
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = 'Monitoring';

IF @sql <> N''
BEGIN
    EXEC sp_executesql @sql;
    PRINT 'Remaining tables in Monitoring schema dropped.';
END

SET @sql = N'';
SELECT @sql = @sql + N'DROP SEQUENCE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(seq.name) + N';' + CHAR(10)
FROM sys.sequences seq
JOIN sys.schemas s ON s.schema_id = seq.schema_id
WHERE s.name = 'Monitoring';

IF @sql <> N''
BEGIN
    EXEC sp_executesql @sql;
    PRINT 'Remaining sequences in Monitoring schema dropped.';
END
GO

-- Drop schema (only if no objects remain)
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Monitoring')
BEGIN
    EXEC sp_executesql N'DROP SCHEMA Monitoring';
    PRINT 'Schema Monitoring dropped.';
END
GO

IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Monitoring')
    PRINT 'Target rollback step 1 incomplete: schema Monitoring still exists on ' + @@SERVERNAME + '.';
ELSE
    PRINT 'Target rollback step 1 complete (schema removed from ' + @@SERVERNAME + ').';
