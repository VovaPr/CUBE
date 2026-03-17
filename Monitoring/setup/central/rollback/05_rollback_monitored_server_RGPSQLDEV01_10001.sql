-- Central Server Rollback - Optional Step 05
-- Removes monitored server entry added by:
--   setup/central/05_add_monitored_server_RGPSQLDEV01_10001.sql
--
-- NOTE:
-- Run this script before 04_rollback_schema.sql (which drops Monitoring.MonitoredServers).

USE master;
GO

DECLARE @LinkedServerName SYSNAME = N'LS_RGPSQLDEV01_10001_DBA_DB';

IF EXISTS (
    SELECT 1
    FROM sys.servers
    WHERE name = @LinkedServerName
)
BEGIN
    EXEC master.dbo.sp_dropserver
        @server = @LinkedServerName,
        @droplogins = 'droplogins';

    PRINT 'Dropped linked server: ' + @LinkedServerName;
END
ELSE
BEGIN
    PRINT 'Linked server not found, nothing to drop: ' + @LinkedServerName;
END

USE dba_db;
GO

DECLARE @ServerName SYSNAME = N'RGPSQLDEV01';
DECLARE @Port INT = 10001;
DECLARE @LinkedServerName SYSNAME = N'LS_RGPSQLDEV01_10001_DBA_DB';

IF OBJECT_ID('Monitoring.MonitoredServers', 'U') IS NULL
BEGIN
    PRINT 'Table Monitoring.MonitoredServers does not exist, nothing to rollback.';
    RETURN;
END

IF EXISTS (
    SELECT 1
    FROM Monitoring.MonitoredServers
    WHERE ServerName = @ServerName
      AND Port = @Port
      AND (LinkedServerName = @LinkedServerName OR LinkedServerName IS NULL)
)
BEGIN
    DELETE FROM Monitoring.MonitoredServers
    WHERE ServerName = @ServerName
      AND Port = @Port
      AND (LinkedServerName = @LinkedServerName OR LinkedServerName IS NULL);

    PRINT 'Removed monitored server entry: ' + @ServerName + ':' + CAST(@Port AS NVARCHAR(10));
END
ELSE
BEGIN
    PRINT 'Entry not found, nothing to delete: ' + @ServerName + ':' + CAST(@Port AS NVARCHAR(10));
END
GO

IF OBJECT_ID('Monitoring.MonitoredServers', 'U') IS NOT NULL
BEGIN
    SELECT ServerName, Port, LinkedServerName, IsActive, CreatedAt, UpdatedAt
    FROM Monitoring.MonitoredServers
    WHERE ServerName = N'RGPSQLDEV01';
END
ELSE
BEGIN
    PRINT 'Table Monitoring.MonitoredServers does not exist, final check skipped.';
END

SELECT name, product, provider, data_source, catalog
FROM sys.servers
WHERE name = N'LS_RGPSQLDEV01_10001_DBA_DB';
