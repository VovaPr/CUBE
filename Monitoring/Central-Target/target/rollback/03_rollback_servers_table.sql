-- Target Server Rollback - Step 3
-- Drops Monitoring.Servers table on the target server

USE dba_db;
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Servers_CentralServerName')
    DROP INDEX IX_Servers_CentralServerName ON Monitoring.Servers;
GO

IF OBJECT_ID('Monitoring.Servers', 'U') IS NOT NULL
BEGIN
    DROP TABLE Monitoring.Servers;
    PRINT 'Table Monitoring.Servers dropped.';
END
ELSE
BEGIN
    PRINT 'Table Monitoring.Servers does not exist, nothing to drop.';
END
GO

PRINT 'Target rollback step 3 complete (Monitoring.Servers removed from ' + @@SERVERNAME + ').';
