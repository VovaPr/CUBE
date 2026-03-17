-- Utility script: add or update one monitored server on central server
-- Server: RGPSQLDEV01
-- Port:   10001

USE master;
GO

DECLARE @LinkedServerName SYSNAME      = N'LS_RGPSQLDEV01_10001_DBA_DB';
DECLARE @DataSource      NVARCHAR(256) = N'rgpsqldev01.cubecloud.local,10001';

IF EXISTS (
    SELECT 1
    FROM sys.servers
    WHERE name = @LinkedServerName
)
BEGIN
    EXEC master.dbo.sp_dropserver
        @server = @LinkedServerName,
        @droplogins = 'droplogins';

    PRINT 'Dropped existing linked server: ' + @LinkedServerName;
END

EXEC master.dbo.sp_addlinkedserver
    @server = @LinkedServerName,
    @srvproduct = N'',
    @provider = N'MSOLEDBSQL',
    @datasrc = @DataSource,
    @provstr = N'Encrypt=yes;TrustServerCertificate=Yes;',
    @catalog = N'dba_db';

EXEC master.dbo.sp_serveroption
    @server = @LinkedServerName,
    @optname = N'data access',
    @optvalue = N'true';

-- Use the SQL Agent service account's Windows identity to connect to the remote server.
-- The service account must have a login and SELECT on dba_db.Monitoring.FailedJobsAlerts on the target.
EXEC master.dbo.sp_addlinkedsrvlogin
    @rmtsrvname = @LinkedServerName,
    @useself    = 'TRUE',
    @locallogin = NULL;

PRINT 'Created linked server: ' + @LinkedServerName + ' -> ' + @DataSource + ' (catalog=dba_db)';

USE dba_db;
GO

-- Ensure LinkedServerName column exists (idempotent, safe to run on older deployments)
IF OBJECT_ID('Monitoring.MonitoredServers', 'U') IS NOT NULL
    AND COL_LENGTH('Monitoring.MonitoredServers', 'LinkedServerName') IS NULL
BEGIN
    ALTER TABLE Monitoring.MonitoredServers
        ADD LinkedServerName SYSNAME NULL;
END
GO

DECLARE @ServerName SYSNAME = N'RGPSQLDEV01';
DECLARE @Port INT = 10001;
DECLARE @LinkedServerName SYSNAME = N'LS_RGPSQLDEV01_10001_DBA_DB';

IF EXISTS (
    SELECT 1
    FROM Monitoring.MonitoredServers
    WHERE ServerName = @ServerName
)
BEGIN
    UPDATE Monitoring.MonitoredServers
    SET Port = @Port,
        LinkedServerName = @LinkedServerName,
        IsActive = 1,
        UpdatedAt = GETDATE()
    WHERE ServerName = @ServerName;

    PRINT 'Updated Monitoring.MonitoredServers: ' + @ServerName + ':' + CAST(@Port AS NVARCHAR(10)) + ' (linked server ' + @LinkedServerName + ')';
END
ELSE
BEGIN
    INSERT INTO Monitoring.MonitoredServers (ServerName, Port, LinkedServerName, IsActive)
    VALUES (@ServerName, @Port, @LinkedServerName, 1);

    PRINT 'Inserted Monitoring.MonitoredServers: ' + @ServerName + ':' + CAST(@Port AS NVARCHAR(10)) + ' (linked server ' + @LinkedServerName + ')';
END
GO

SELECT ServerName, Port, LinkedServerName, IsActive, CreatedAt, UpdatedAt
FROM Monitoring.MonitoredServers
WHERE ServerName = N'RGPSQLDEV01';

SELECT name, product, provider, data_source, catalog
FROM sys.servers
WHERE name = N'LS_RGPSQLDEV01_10001_DBA_DB';
