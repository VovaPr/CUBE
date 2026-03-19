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

-- Ensure server registration table exists
IF OBJECT_ID('Monitoring.Servers', 'U') IS NULL
BEGIN
    CREATE TABLE Monitoring.Servers (
        ServerName        NVARCHAR(256) NOT NULL PRIMARY KEY,
        CentralServerName NVARCHAR(256) NOT NULL,
        IsActive          BIT NOT NULL CONSTRAINT DF_Servers_IsActive DEFAULT (1),
        Central           BIT NULL,
        Target            BIT NULL,
        CreatedAt         DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedAt        DATETIME2 NOT NULL DEFAULT GETDATE()
    );

    PRINT 'Table Monitoring.Servers created.';
END
ELSE
BEGIN
    PRINT 'Table Monitoring.Servers already exists.';
END
GO

-- Ensure target registration row is present and points to new central
IF NOT EXISTS (
    SELECT 1
    FROM Monitoring.Servers
    WHERE ServerName = @@SERVERNAME
)
BEGIN
    INSERT INTO Monitoring.Servers (ServerName, CentralServerName, IsActive)
    VALUES (@@SERVERNAME, N'DBMGMT.cubecloud.local\SQL01,10010', 1);

    PRINT 'Server registration row added for ' + @@SERVERNAME;
END
ELSE
BEGIN
    UPDATE Monitoring.Servers
    SET CentralServerName = N'DBMGMT.cubecloud.local\SQL01,10010',
        IsActive = 1,
        ModifiedAt = GETDATE()
    WHERE ServerName = @@SERVERNAME;

    PRINT 'Server registration row updated for ' + @@SERVERNAME;
END
GO

-- Ensure lookup index exists
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Servers_CentralServerName')
    CREATE INDEX IX_Servers_CentralServerName ON Monitoring.Servers(CentralServerName);
GO

PRINT 'Target setup step 2 complete (Monitoring.Servers ensured) on ' + @@SERVERNAME + '.';
