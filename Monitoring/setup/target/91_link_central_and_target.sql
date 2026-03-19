-- Utility Script - Step 91 (run on TARGET)
-- Purpose:
-- 1) Ensure TARGET local Monitoring.Servers rows are up to date
--    (one row for CENTRAL and one row for TARGET).
-- 2) Send TARGET server name registration to CENTRAL (DBMGMT\SQL01,10010)
--    through xp_cmdshell + sqlcmd.
-- 3) Verify central row through sqlcmd (no linked servers).

SET NOCOUNT ON;

DECLARE @CentralEndpoint NVARCHAR(256) = N'DBMGMT\SQL01,10010';
DECLARE @TargetInstanceName NVARCHAR(256) =
    CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
    ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'');

USE DBA_DB;

IF OBJECT_ID(N'Monitoring.Servers', N'U') IS NULL
BEGIN
    RAISERROR(N'Monitoring.Servers table is missing on TARGET. Run target setup step 02 first.', 16, 1);
    RETURN;
END;

-- Add Central/Target columns idempotently (may be absent on older installs).
IF COL_LENGTH(N'Monitoring.Servers', N'Central') IS NULL
    ALTER TABLE Monitoring.Servers ADD Central BIT NULL;

IF COL_LENGTH(N'Monitoring.Servers', N'Target') IS NULL
    ALTER TABLE Monitoring.Servers ADD Target BIT NULL;

-- Upsert TARGET row (Central=0, Target=1) and CENTRAL marker row (Central=1, Target=0).
-- Wrapped in sp_executesql to avoid Msg 207 if columns were just added above.
EXEC sp_executesql N'
MERGE Monitoring.Servers AS dst
USING (SELECT @TargetInstanceName AS ServerName, @CentralEndpoint AS CentralServerName,
              CAST(0 AS BIT) AS Central, CAST(1 AS BIT) AS Target, CAST(1 AS BIT) AS IsActive) AS src
ON dst.ServerName = src.ServerName
WHEN MATCHED THEN UPDATE SET
    dst.CentralServerName = src.CentralServerName,
    dst.Central    = src.Central,
    dst.Target     = src.Target,
    dst.IsActive   = src.IsActive,
    dst.ModifiedAt = GETDATE()
WHEN NOT MATCHED THEN INSERT (ServerName, CentralServerName, Central, Target, IsActive)
    VALUES (src.ServerName, src.CentralServerName, src.Central, src.Target, src.IsActive);

MERGE Monitoring.Servers AS dst
USING (SELECT @CentralEndpoint AS ServerName, @CentralEndpoint AS CentralServerName,
              CAST(1 AS BIT) AS Central, CAST(0 AS BIT) AS Target, CAST(1 AS BIT) AS IsActive) AS src
ON dst.ServerName = src.ServerName
WHEN MATCHED THEN UPDATE SET
    dst.CentralServerName = src.CentralServerName,
    dst.Central    = src.Central,
    dst.Target     = src.Target,
    dst.IsActive   = src.IsActive,
    dst.ModifiedAt = GETDATE()
WHEN NOT MATCHED THEN INSERT (ServerName, CentralServerName, Central, Target, IsActive)
    VALUES (src.ServerName, src.CentralServerName, src.Central, src.Target, src.IsActive);
',
N'@TargetInstanceName NVARCHAR(256), @CentralEndpoint NVARCHAR(256)',
@TargetInstanceName = @TargetInstanceName,
@CentralEndpoint    = @CentralEndpoint;

-- Show stored rows with persisted Central/Target flags.
EXEC sp_executesql N'
SELECT
    N''Local Monitoring.Servers'' AS Info,
    s.ServerName,
    s.CentralServerName,
    s.Central,
    s.Target,
    s.IsActive,
    s.ModifiedAt
FROM Monitoring.Servers s
WHERE s.ServerName IN (@CentralEndpoint, @TargetInstanceName)
ORDER BY s.ServerName;
',
N'@TargetInstanceName NVARCHAR(256), @CentralEndpoint NVARCHAR(256)',
@TargetInstanceName = @TargetInstanceName,
@CentralEndpoint    = @CentralEndpoint;

-- Build CENTRAL merge command to run from TARGET via sqlcmd.
-- This sends the TARGET server name to central Monitoring.Servers.
DECLARE @CentralMergeQuery NVARCHAR(MAX) =
    N'SET NOCOUNT ON; '
  + N'MERGE Monitoring.Servers AS dst '
    + N'USING (SELECT CAST(N''' + REPLACE(@TargetInstanceName, N'''', N'''''') + N''' AS NVARCHAR(256)) AS ServerName, '
  + N'CAST(N''' + REPLACE(@CentralEndpoint, N'''', N'''''') + N''' AS NVARCHAR(256)) AS CentralServerName, '
  + N'CAST(0 AS BIT) AS Central, CAST(1 AS BIT) AS Target, CAST(1 AS BIT) AS IsActive) AS src '
  + N'ON dst.ServerName = src.ServerName '
  + N'WHEN MATCHED THEN UPDATE SET dst.CentralServerName = src.CentralServerName, dst.Central = src.Central, dst.Target = src.Target, dst.IsActive = src.IsActive, dst.ModifiedAt = GETDATE() '
  + N'WHEN NOT MATCHED THEN INSERT (ServerName, CentralServerName, Central, Target, IsActive) VALUES (src.ServerName, src.CentralServerName, src.Central, src.Target, src.IsActive); '
    + N'SELECT N''Central Monitoring.Servers'' AS Info, ServerName, CentralServerName, '
    + N'Central, Target, '
    + N'IsActive, ModifiedAt '
    + N'FROM Monitoring.Servers WHERE ServerName = N''' + REPLACE(@TargetInstanceName, N'''', N'''''') + N''';';

DECLARE @RunOnTargetCommand NVARCHAR(MAX) =
    N'sqlcmd -S ' + @CentralEndpoint
  + N' -d DBA_DB -E -N -C -b -Q "' + REPLACE(@CentralMergeQuery, N'"', N'\"') + N'"';

-- Print a ready command for manual run on TARGET.
SELECT
    N'Run on TARGET' AS Info,
    @RunOnTargetCommand AS TargetCommand;

-- Execute immediately on TARGET via xp_cmdshell if available.
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
