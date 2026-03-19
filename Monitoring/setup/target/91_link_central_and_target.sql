-- Utility Script - Step 91 (run on TARGET)
-- Purpose:
-- 1) Recreate Monitoring.Servers with correct schema on TARGET.
-- 2) Insert CENTRAL marker row (Central=1, Target=0) and TARGET row (Central=0, Target=1).
-- 3) Show SELECT * FROM DBA_DB.Monitoring.Servers.
-- 4) Push TARGET registration to CENTRAL (DBMGMT\SQL01,10010) via sqlcmd / xp_cmdshell.

SET NOCOUNT ON;

DECLARE @CentralEndpoint    NVARCHAR(256) = N'DBMGMT\SQL01,10010';
DECLARE @TargetInstanceName NVARCHAR(256) =
    CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
    ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'');

USE DBA_DB;

-- Ensure schema exists
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'Monitoring')
    EXEC sp_executesql N'CREATE SCHEMA Monitoring';

-- Drop and recreate Monitoring.Servers with correct column order
IF OBJECT_ID(N'Monitoring.Servers', N'U') IS NOT NULL
    DROP TABLE Monitoring.Servers;

CREATE TABLE Monitoring.Servers (
    ServerName        NVARCHAR(256) NOT NULL PRIMARY KEY,
    CentralServerName NVARCHAR(256) NOT NULL,
    IsActive          BIT           NOT NULL CONSTRAINT DF_Servers_IsActive DEFAULT (1),
    Central           BIT           NULL,
    Target            BIT           NULL,
    CreatedAt         DATETIME2     NOT NULL DEFAULT GETDATE(),
    ModifiedAt        DATETIME2     NOT NULL DEFAULT GETDATE()
);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Servers_CentralServerName')
    CREATE INDEX IX_Servers_CentralServerName ON Monitoring.Servers(CentralServerName);

PRINT 'Monitoring.Servers recreated.';
GO

-- Part 1: insert rows and show local state
-- (separate batch so columns are resolved fresh after CREATE TABLE)
DECLARE @CentralEndpoint    NVARCHAR(256) = N'DBMGMT\SQL01,10010';
DECLARE @TargetInstanceName NVARCHAR(256) =
    CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
    ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'');

INSERT INTO Monitoring.Servers (ServerName, CentralServerName, IsActive, Central, Target)
VALUES (@CentralEndpoint, @CentralEndpoint, 1, 1, 0);

INSERT INTO Monitoring.Servers (ServerName, CentralServerName, IsActive, Central, Target)
VALUES (@TargetInstanceName, @CentralEndpoint, 1, 0, 1);

PRINT 'Rows inserted: ' + @CentralEndpoint + ' (Central), ' + @TargetInstanceName + ' (Target)';
GO

SELECT * FROM DBA_DB.Monitoring.Servers;
GO

-- Part 2: push TARGET registration to CENTRAL
DECLARE @CentralEndpoint    NVARCHAR(256) = N'DBMGMT\SQL01,10010';
DECLARE @TargetInstanceName NVARCHAR(256) =
    CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
    ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'');

DECLARE @CentralMergeQuery NVARCHAR(MAX) =
    N'SET NOCOUNT ON; '
  + N'MERGE Monitoring.Servers AS dst '
  + N'USING (SELECT CAST(N''' + REPLACE(@TargetInstanceName, N'''', N'''''') + N''' AS NVARCHAR(256)) AS ServerName, '
  + N'CAST(N''' + REPLACE(@CentralEndpoint, N'''', N'''''') + N''' AS NVARCHAR(256)) AS CentralServerName, '
  + N'CAST(0 AS BIT) AS Central, CAST(1 AS BIT) AS Target, CAST(1 AS BIT) AS IsActive) AS src '
  + N'ON dst.ServerName = src.ServerName '
  + N'WHEN MATCHED THEN UPDATE SET dst.CentralServerName = src.CentralServerName, dst.Central = src.Central, dst.Target = src.Target, dst.IsActive = src.IsActive, dst.ModifiedAt = GETDATE() '
  + N'WHEN NOT MATCHED THEN INSERT (ServerName, CentralServerName, IsActive, Central, Target) VALUES (src.ServerName, src.CentralServerName, src.IsActive, src.Central, src.Target); '
  + N'SELECT * FROM Monitoring.Servers WHERE ServerName = N''' + REPLACE(@TargetInstanceName, N'''', N'''''') + N''';';

DECLARE @RunOnTargetCommand NVARCHAR(MAX) =
    N'sqlcmd -S ' + @CentralEndpoint
  + N' -d DBA_DB -E -N -C -b -Q "' + REPLACE(@CentralMergeQuery, N'"', N'\"') + N'"';

SELECT
    N'Run on TARGET' AS Info,
    @RunOnTargetCommand AS TargetCommand;

DECLARE @xpCmdShellEnabled BIT = 0;
SELECT @xpCmdShellEnabled = CAST(value_in_use AS BIT)
FROM sys.configurations
WHERE name = N'xp_cmdshell';

IF @xpCmdShellEnabled = 1
BEGIN
    PRINT N'xp_cmdshell is enabled. Executing TARGET -> CENTRAL registration now...';
    EXEC master..xp_cmdshell @RunOnTargetCommand;
END
ELSE
BEGIN
    PRINT N'xp_cmdshell is disabled. Run the command from result set manually on TARGET.';
END;
GO
