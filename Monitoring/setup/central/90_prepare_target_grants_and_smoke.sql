-- Central Utility Script - Step 90
-- Purpose:
-- Grant required access in DBA_DB to SQL Server and SQL Agent service logins
-- detected on central server.

SET NOCOUNT ON;

DECLARE @ServiceLogins TABLE (
    Principal SYSNAME PRIMARY KEY
);

INSERT INTO @ServiceLogins (Principal)
SELECT DISTINCT CAST(s.service_account AS SYSNAME)
FROM sys.dm_server_services s
WHERE s.service_account IS NOT NULL
  AND s.service_account NOT IN (N'LocalSystem', N'NT AUTHORITY\\LocalService', N'NT AUTHORITY\\NetworkService')
  AND (
        s.servicename LIKE N'SQL Server (%'
     OR s.servicename LIKE N'SQL Server Agent (%'
  );

IF NOT EXISTS (SELECT 1 FROM @ServiceLogins)
BEGIN
    RAISERROR(N'No eligible SQL service accounts found in sys.dm_server_services on central.', 16, 1);
    RETURN;
END;

-- Ensure server login exists on central
USE master;

DECLARE @Principal SYSNAME;
DECLARE @sql NVARCHAR(MAX);

DECLARE curCreateLogin CURSOR LOCAL FAST_FORWARD FOR
    SELECT Principal
    FROM @ServiceLogins;

OPEN curCreateLogin;
FETCH NEXT FROM curCreateLogin INTO @Principal;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM sys.server_principals
        WHERE name = @Principal
    )
    BEGIN
        SET @sql = N'CREATE LOGIN ' + QUOTENAME(@Principal) + N' FROM WINDOWS;';
        EXEC(@sql);
    END;

    FETCH NEXT FROM curCreateLogin INTO @Principal;
END;

CLOSE curCreateLogin;
DEALLOCATE curCreateLogin;

-- Ensure database user exists in DBA_DB
USE DBA_DB;

DECLARE curDbUser CURSOR LOCAL FAST_FORWARD FOR
    SELECT Principal
    FROM @ServiceLogins;

OPEN curDbUser;
FETCH NEXT FROM curDbUser INTO @Principal;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM sys.database_principals
        WHERE name = @Principal
    )
    BEGIN
        SET @sql =
            N'CREATE USER ' + QUOTENAME(@Principal) +
            N' FOR LOGIN ' + QUOTENAME(@Principal) + N';';
        EXEC(@sql);
    END;

    FETCH NEXT FROM curDbUser INTO @Principal;
END;

CLOSE curDbUser;
DEALLOCATE curDbUser;

-- Add role membership idempotently
DECLARE curRoles CURSOR LOCAL FAST_FORWARD FOR
    SELECT Principal
    FROM @ServiceLogins;

OPEN curRoles;
FETCH NEXT FROM curRoles INTO @Principal;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM sys.database_role_members drm
        JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
        JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
        WHERE r.name = N'db_datareader' AND m.name = @Principal
    )
    BEGIN
        SET @sql = N'ALTER ROLE [db_datareader] ADD MEMBER ' + QUOTENAME(@Principal) + N';';
        EXEC(@sql);
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.database_role_members drm
        JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
        JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
        WHERE r.name = N'db_datawriter' AND m.name = @Principal
    )
    BEGIN
        SET @sql = N'ALTER ROLE [db_datawriter] ADD MEMBER ' + QUOTENAME(@Principal) + N';';
        EXEC(@sql);
    END;

    FETCH NEXT FROM curRoles INTO @Principal;
END;

CLOSE curRoles;
DEALLOCATE curRoles;

-- Selected service accounts on central
SELECT
    N'Selected service account' AS Info,
    l.Principal
FROM @ServiceLogins l
ORDER BY l.Principal;

-- Verification on central
SELECT
    N'Final membership' AS Info,
    m.name AS Principal,
    r.name AS RoleName
FROM sys.database_role_members drm
JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
WHERE m.name IN (SELECT Principal FROM @ServiceLogins)
ORDER BY m.name, r.name;

-- Smoke checks are executed separately from target-side scripts.
