-- Central Migration Script - Step 92
-- Purpose:
--   1. Add Central BIT and Target BIT columns to Monitoring.Servers (idempotent)
--   2. Clear all existing rows and insert a single fresh central row:
--        ServerName        = SERVERPROPERTY('InstanceName')  (dynamic, current server)
--        CentralServerName = N'DBMGMT\SQL01,10010'           (hardcoded central endpoint)
--   3. Set flags: Central=1, Target=0 for the central row
--
-- NOTE: Column references to Central/Target are wrapped in sp_executesql to
--       avoid Msg 207 batch-compile error (SQL Server resolves names before
--       ALTER TABLE executes within the same batch).

USE DBA_DB;
GO
SET NOCOUNT ON;
GO

-- Guard: table must exist
IF OBJECT_ID(N'Monitoring.Servers', N'U') IS NULL
BEGIN
    RAISERROR(N'Monitoring.Servers does not exist. Run central setup steps first.', 16, 1);
    RETURN;
END
GO

-- 1. Add Central column (idempotent)
IF COL_LENGTH(N'Monitoring.Servers', N'Central') IS NULL
BEGIN
    ALTER TABLE Monitoring.Servers ADD Central BIT NULL;
    PRINT 'Column Central added.';
END
ELSE
    PRINT 'Column Central already exists, skipping.';
GO

-- 2. Add Target column (idempotent)
IF COL_LENGTH(N'Monitoring.Servers', N'Target') IS NULL
BEGIN
    ALTER TABLE Monitoring.Servers ADD Target BIT NULL;
    PRINT 'Column Target added.';
END
ELSE
    PRINT 'Column Target already exists, skipping.';
GO

-- 3. Detect instance name and set hardcoded central endpoint
DECLARE @InstanceName     NVARCHAR(256) =
    CAST(ISNULL(CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'MSSQLSERVER') AS NVARCHAR(256));
DECLARE @CentralEndpoint  NVARCHAR(256) = N'DBMGMT\SQL01,10010';

-- 4. Clear all existing rows and insert fresh central row
TRUNCATE TABLE Monitoring.Servers;
PRINT 'Monitoring.Servers truncated.';

INSERT INTO Monitoring.Servers (ServerName, CentralServerName, IsActive)
VALUES (@InstanceName, @CentralEndpoint, 1);
PRINT 'Central row inserted: ServerName=' + @InstanceName + ', CentralServerName=' + @CentralEndpoint;
GO

-- 5. Set Central/Target flags on the central row
--    Wrapped in sp_executesql to avoid Msg 207 if columns were just added above
EXEC sp_executesql N'
UPDATE Monitoring.Servers
SET Central    = CAST(1 AS BIT),
    Target     = CAST(0 AS BIT),
    ModifiedAt = GETDATE();
PRINT ''Central/Target flags set.'';
';
GO

-- 6. Final verification (sp_executesql so new columns are resolved at runtime)
EXEC sp_executesql N'
SELECT ServerName, CentralServerName, Central, Target, IsActive, ModifiedAt
FROM Monitoring.Servers
ORDER BY Central DESC, ServerName;
';
GO
