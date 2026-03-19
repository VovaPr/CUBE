-- Target Server Setup - Step 2
-- Create/repair Monitoring.Servers table on each target server
-- Safe to run on already configured servers

USE dba_db;
GO

-- Ensure schema exists
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Monitoring')
BEGIN
    EXEC sp_executesql N'CREATE SCHEMA Monitoring';
END
GO

DECLARE @TargetInstanceName NVARCHAR(256) =
    CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
    ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'');
DECLARE @CentralEndpoint NVARCHAR(256) = N'DBMGMT\SQL01,10010';

IF OBJECT_ID('Monitoring.Servers', 'U') IS NOT NULL
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

PRINT 'Table Monitoring.Servers recreated.';

INSERT INTO Monitoring.Servers (ServerName, CentralServerName, IsActive, Central, Target)
VALUES (@CentralEndpoint, @CentralEndpoint, 1, 1, 0);

INSERT INTO Monitoring.Servers (ServerName, CentralServerName, IsActive, Central, Target)
VALUES (@TargetInstanceName, @CentralEndpoint, 1, 0, 1);

PRINT 'Server registration rows added for ' + @CentralEndpoint + ' and ' + @TargetInstanceName;
GO

-- Ensure lookup index exists
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Servers_CentralServerName')
    CREATE INDEX IX_Servers_CentralServerName ON Monitoring.Servers(CentralServerName);
GO

PRINT 'Target setup step 2 complete (Monitoring.Servers recreated) on ' + @@SERVERNAME + '.';
