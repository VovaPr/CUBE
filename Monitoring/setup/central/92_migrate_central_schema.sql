-- Central Migration Script - Step 92
-- Purpose:
--   1. Add Central BIT and Target BIT columns to Monitoring.Servers (idempotent)
--   2. Rename central endpoint from DBMGMT.cubecloud.local\SQL01,10010 → DBMGMT\SQL01,10010
--   3. Set flags: Central=1 for the central row, Target=1 for all other rows
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

-- 3. Rename old central endpoint ServerName (PK) to new short form (idempotent)
--    Case A: old row exists, new row doesn't → rename
IF EXISTS     (SELECT 1 FROM Monitoring.Servers WHERE ServerName = N'DBMGMT.cubecloud.local\SQL01,10010')
   AND NOT EXISTS (SELECT 1 FROM Monitoring.Servers WHERE ServerName = N'DBMGMT\SQL01,10010')
BEGIN
    UPDATE Monitoring.Servers
    SET ServerName        = N'DBMGMT\SQL01,10010',
        CentralServerName = N'DBMGMT\SQL01,10010',
        ModifiedAt        = GETDATE()
    WHERE ServerName = N'DBMGMT.cubecloud.local\SQL01,10010';
    PRINT 'Renamed central endpoint row ServerName.';
END

--    Case B: both old and new rows exist → remove stale old row
IF EXISTS (SELECT 1 FROM Monitoring.Servers WHERE ServerName = N'DBMGMT.cubecloud.local\SQL01,10010')
   AND EXISTS (SELECT 1 FROM Monitoring.Servers WHERE ServerName = N'DBMGMT\SQL01,10010')
BEGIN
    DELETE FROM Monitoring.Servers WHERE ServerName = N'DBMGMT.cubecloud.local\SQL01,10010';
    PRINT 'Removed stale old central endpoint row.';
END

-- 4. Update any remaining rows still pointing to old CentralServerName
UPDATE Monitoring.Servers
SET CentralServerName = N'DBMGMT\SQL01,10010',
    ModifiedAt        = GETDATE()
WHERE CentralServerName = N'DBMGMT.cubecloud.local\SQL01,10010';

IF @@ROWCOUNT > 0
    PRINT 'Updated CentralServerName references to new endpoint.';
GO

-- 5. Ensure central marker row exists
IF NOT EXISTS (SELECT 1 FROM Monitoring.Servers WHERE ServerName = N'DBMGMT\SQL01,10010')
BEGIN
    INSERT INTO Monitoring.Servers (ServerName, CentralServerName, IsActive)
    VALUES (N'DBMGMT\SQL01,10010', N'DBMGMT\SQL01,10010', 1);
    PRINT 'Central marker row inserted.';
END
GO

-- 6. Set Central / Target flags
--    Wrapped in sp_executesql to avoid Msg 207 if columns were just added above
EXEC sp_executesql N'
UPDATE Monitoring.Servers
SET Central    = CASE WHEN ServerName = N''DBMGMT\SQL01,10010'' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END,
    Target     = CASE WHEN ServerName = N''DBMGMT\SQL01,10010'' THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END,
    ModifiedAt = GETDATE();
PRINT ''Central/Target flags updated.'';
';
GO

-- 7. Final verification (sp_executesql so new columns are resolved at runtime)
EXEC sp_executesql N'
SELECT ServerName, CentralServerName, Central, Target, IsActive, ModifiedAt
FROM Monitoring.Servers
ORDER BY Central DESC, ServerName;
';
GO
