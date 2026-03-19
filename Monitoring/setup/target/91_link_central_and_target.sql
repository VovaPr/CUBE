-- Utility Script - Step 91 (run on TARGET)
-- Purpose:
-- 1) Ensure TARGET local Monitoring.Servers row is up to date.
-- 2) Send TARGET server name registration to CENTRAL (DBMGMT\SQL01,10010)
--    through xp_cmdshell + sqlcmd.
-- 3) Verify central row through sqlcmd (no linked servers).

SET NOCOUNT ON;

DECLARE @CentralEndpoint NVARCHAR(256) = N'DBMGMT\SQL01,10010';
DECLARE @TargetServerName NVARCHAR(256) = CAST(@@SERVERNAME AS NVARCHAR(256));

USE DBA_DB;

IF OBJECT_ID(N'Monitoring.Servers', N'U') IS NULL
BEGIN
    RAISERROR(N'Monitoring.Servers table is missing on TARGET. Run target setup step 02 first.', 16, 1);
    RETURN;
END;

-- Keep local target registration fresh.
MERGE Monitoring.Servers AS dst
USING (
    SELECT
        @TargetServerName AS ServerName,
        @CentralEndpoint AS CentralServerName,
        CAST(1 AS BIT) AS IsActive
) AS src
    ON dst.ServerName = src.ServerName
WHEN MATCHED THEN
    UPDATE SET
        dst.CentralServerName = src.CentralServerName,
        dst.IsActive = src.IsActive,
        dst.ModifiedAt = GETDATE()
WHEN NOT MATCHED THEN
    INSERT (ServerName, CentralServerName, IsActive)
    VALUES (src.ServerName, src.CentralServerName, src.IsActive);

SELECT
    N'Local target registration' AS Info,
    s.ServerName,
    s.CentralServerName,
    s.IsActive,
    s.ModifiedAt
FROM Monitoring.Servers s
WHERE s.ServerName = @TargetServerName;

-- Build CENTRAL merge command to run from TARGET via sqlcmd.
-- This sends the TARGET server name to central Monitoring.Servers.
DECLARE @CentralMergeQuery NVARCHAR(MAX) =
    N'SET NOCOUNT ON; '
  + N'MERGE Monitoring.Servers AS dst '
  + N'USING (SELECT CAST(N''' + REPLACE(@TargetServerName, N'''', N'''''') + N''' AS NVARCHAR(256)) AS ServerName, '
  + N'CAST(N''' + REPLACE(@CentralEndpoint, N'''', N'''''') + N''' AS NVARCHAR(256)) AS CentralServerName, '
  + N'CAST(1 AS BIT) AS IsActive) AS src '
  + N'ON dst.ServerName = src.ServerName '
  + N'WHEN MATCHED THEN UPDATE SET dst.CentralServerName = src.CentralServerName, dst.IsActive = src.IsActive, dst.ModifiedAt = GETDATE() '
  + N'WHEN NOT MATCHED THEN INSERT (ServerName, CentralServerName, IsActive) VALUES (src.ServerName, src.CentralServerName, src.IsActive); '
  + N'SELECT N''Central registration'' AS Info, ServerName, CentralServerName, IsActive, ModifiedAt '
  + N'FROM Monitoring.Servers WHERE ServerName = N''' + REPLACE(@TargetServerName, N'''', N'''''') + N''';';

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
