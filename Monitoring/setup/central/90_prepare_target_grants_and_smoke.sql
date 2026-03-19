-- Central Utility Script - Step 90
-- Purpose:
-- 1) Grant required access in DBA_DB to a target execution login.
-- 2) Output a ready-to-run smoke command for target-side connectivity test.

SET NOCOUNT ON;

DECLARE @TargetExecutionLogin SYSNAME = N'CUBECLOUD\SQLDEV2DBE'; -- set per target
DECLARE @CentralEndpoint NVARCHAR(256) = N'DBMGMT.cubecloud.local\SQL01,10010';

-- Ensure server login exists on central
USE master;

IF NOT EXISTS (
    SELECT 1
    FROM sys.server_principals
    WHERE name = @TargetExecutionLogin
)
BEGIN
    DECLARE @sqlCreateLogin NVARCHAR(MAX) =
        N'CREATE LOGIN ' + QUOTENAME(@TargetExecutionLogin) + N' FROM WINDOWS;';
    EXEC(@sqlCreateLogin);
END;

-- Ensure database user exists in DBA_DB
USE DBA_DB;

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_principals
    WHERE name = @TargetExecutionLogin
)
BEGIN
    DECLARE @sqlCreateUser NVARCHAR(MAX) =
        N'CREATE USER ' + QUOTENAME(@TargetExecutionLogin) +
        N' FOR LOGIN ' + QUOTENAME(@TargetExecutionLogin) + N';';
    EXEC(@sqlCreateUser);
END;

-- Add role membership idempotently
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
    WHERE r.name = N'db_datareader' AND m.name = @TargetExecutionLogin
)
BEGIN
    DECLARE @sqlReader NVARCHAR(MAX) =
        N'ALTER ROLE [db_datareader] ADD MEMBER ' + QUOTENAME(@TargetExecutionLogin) + N';';
    EXEC(@sqlReader);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
    WHERE r.name = N'db_datawriter' AND m.name = @TargetExecutionLogin
)
BEGIN
    DECLARE @sqlWriter NVARCHAR(MAX) =
        N'ALTER ROLE [db_datawriter] ADD MEMBER ' + QUOTENAME(@TargetExecutionLogin) + N';';
    EXEC(@sqlWriter);
END;

-- Verification on central
SELECT
    N'Final membership' AS Info,
    m.name AS Principal,
    r.name AS RoleName
FROM sys.database_role_members drm
JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
WHERE m.name = @TargetExecutionLogin
ORDER BY r.name;

-- Output target-side smoke command (run this on target)
DECLARE @TargetTestCommand NVARCHAR(MAX) =
N'sqlcmd -S ' + @CentralEndpoint +
N' -d DBA_DB -E -N -C -b -Q "SET NOCOUNT ON; SELECT TOP 5 ServerName, CentralServerName, IsActive, ModifiedAt FROM Monitoring.Servers ORDER BY ModifiedAt DESC;"';

SELECT
    N'Run on TARGET' AS Info,
    @TargetTestCommand AS TargetCommand;
