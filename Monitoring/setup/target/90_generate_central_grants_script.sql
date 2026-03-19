-- Target Utility Script - Step 90
-- Generates a ready-to-run central script for granting access
-- to the SQL Server Agent service account of the current target.
--
-- Run this script on TARGET, then copy value from ScriptForCentral
-- result set and run it on CENTRAL.

SET NOCOUNT ON;

DECLARE @ServiceAccount NVARCHAR(256);

SELECT TOP (1)
    @ServiceAccount = service_account
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server Agent (%';

IF @ServiceAccount IS NULL
BEGIN
    RAISERROR('SQL Server Agent service account not found on target.', 16, 1);
    RETURN;
END;

SELECT
    @@SERVERNAME AS TargetServer,
    @ServiceAccount AS ServiceAccount;

DECLARE @ScriptForCentral NVARCHAR(MAX) = N'
/* RUN ON CENTRAL */
SET NOCOUNT ON;

DECLARE @ServiceAccount SYSNAME = N''' + REPLACE(@ServiceAccount, '''', '''''') + N''';

SELECT N''Service account from target'' AS Info, @ServiceAccount AS [Value], @@SERVERNAME AS CentralServer;

USE master;

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @ServiceAccount)
BEGIN
    DECLARE @sqlLogin NVARCHAR(MAX) =
        N''CREATE LOGIN '' + QUOTENAME(@ServiceAccount) + N'' FROM WINDOWS;'';
    EXEC(@sqlLogin);
    SELECT N''LOGIN created'' AS [Status], @ServiceAccount AS [Principal];
END
ELSE
    SELECT N''LOGIN already exists'' AS [Status], @ServiceAccount AS [Principal];

USE DBA_DB;

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @ServiceAccount)
BEGIN
    DECLARE @sqlUser NVARCHAR(MAX) =
        N''CREATE USER '' + QUOTENAME(@ServiceAccount) +
        N'' FOR LOGIN '' + QUOTENAME(@ServiceAccount) + N'';'';
    EXEC(@sqlUser);
    SELECT N''USER created in DBA_DB'' AS [Status], @ServiceAccount AS [Principal];
END
ELSE
    SELECT N''USER already exists in DBA_DB'' AS [Status], @ServiceAccount AS [Principal];

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
    WHERE r.name = N''db_datareader'' AND m.name = @ServiceAccount
)
BEGIN
    DECLARE @sqlReader NVARCHAR(MAX) =
        N''ALTER ROLE [db_datareader] ADD MEMBER '' + QUOTENAME(@ServiceAccount) + N'';'';
    EXEC(@sqlReader);
END

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
    WHERE r.name = N''db_datawriter'' AND m.name = @ServiceAccount
)
BEGIN
    DECLARE @sqlWriter NVARCHAR(MAX) =
        N''ALTER ROLE [db_datawriter] ADD MEMBER '' + QUOTENAME(@ServiceAccount) + N'';'';
    EXEC(@sqlWriter);
END

SELECT
    N''Final membership'' AS Info,
    @ServiceAccount AS Principal,
    r.name AS RoleName
FROM sys.database_role_members drm
JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
WHERE m.name = @ServiceAccount
ORDER BY r.name;
';

SELECT @ScriptForCentral AS ScriptForCentral;
