-- Central Migration Script - Step 92
-- Purpose:
--   Recreate Monitoring.Servers with the correct column order on CENTRAL.
--   Inserts a single central row:
--     ServerName        = MachineName[\InstanceName]  (SERVERPROPERTY, dynamic)
--     CentralServerName = N'DBMGMT\SQL01,10010'       (hardcoded)
--     Central=1, Target=0

USE DBA_DB;
GO
SET NOCOUNT ON;
GO

-- Ensure schema exists
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'Monitoring')
    EXEC sp_executesql N'CREATE SCHEMA Monitoring';
GO

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

-- Insert central row (separate batch: columns resolved fresh after CREATE TABLE)
DECLARE @InstanceName    NVARCHAR(256) =
    CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
    ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'');
DECLARE @CentralEndpoint NVARCHAR(256) = N'DBMGMT\SQL01,10010';

INSERT INTO Monitoring.Servers (ServerName, CentralServerName, IsActive, Central, Target)
VALUES (@InstanceName, @CentralEndpoint, 1, 1, 0);

PRINT 'Central row inserted: ' + @InstanceName;
GO

SELECT * FROM DBA_DB.Monitoring.Servers;
GO
