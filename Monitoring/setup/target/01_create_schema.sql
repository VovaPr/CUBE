-- Target Server Setup - Step 1
-- Create monitoring schema and tables on each target server
-- The dba_db database must already exist

USE dba_db;
GO

-- Create schema for monitoring
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Monitoring')
BEGIN
    EXEC sp_executesql N'CREATE SCHEMA Monitoring';
END
GO

-- Current Job Status Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Jobs' AND schema_id = SCHEMA_ID('Monitoring'))
BEGIN
    CREATE TABLE Monitoring.Jobs (
        JobID INT PRIMARY KEY IDENTITY(1,1),
        ServerName NVARCHAR(256) NOT NULL,
        JobName NVARCHAR(256) NOT NULL,
        SQLJobID UNIQUEIDENTIFIER,
        LastRunStatus INT,
        LastRunDate DATETIME2,
        LastRunDuration INT,
        NextRunDate DATETIME2,
        IsEnabled BIT,
        RecordedDate DATETIME2 DEFAULT GETDATE(),
        UNIQUE (ServerName, JobName)
    );
    PRINT 'Table Monitoring.Jobs created.';
END
ELSE
BEGIN
    PRINT 'Table Monitoring.Jobs already exists.';
END
GO

-- Failed Jobs Alert Log
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'FailedJobsAlerts' AND schema_id = SCHEMA_ID('Monitoring'))
BEGIN
    CREATE TABLE Monitoring.FailedJobsAlerts (
        AlertID INT PRIMARY KEY IDENTITY(1,1),
        ServerName NVARCHAR(256) NOT NULL,
        JobName NVARCHAR(256) NOT NULL,
        FailureCount INT DEFAULT 1,
        FirstFailureTime DATETIME2 DEFAULT GETDATE(),
        LastFailureTime DATETIME2 DEFAULT GETDATE(),
        AlertSentTime DATETIME2,
        IsResolved BIT DEFAULT 0,
        ResolutionTime DATETIME2
    );
    PRINT 'Table Monitoring.FailedJobsAlerts created.';
END
ELSE
BEGIN
    PRINT 'Table Monitoring.FailedJobsAlerts already exists.';
END
GO

-- One aggregated server table updated locally on every target run and pushed to central.
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Servers' AND schema_id = SCHEMA_ID('Monitoring'))
BEGIN
    CREATE TABLE Monitoring.Servers (
        ServerName NVARCHAR(256) NOT NULL PRIMARY KEY,
        CentralServerName NVARCHAR(256) NOT NULL,
        IsActive BIT NOT NULL CONSTRAINT DF_Servers_IsActive DEFAULT (1),
        CreatedAt DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedAt DATETIME2 NOT NULL DEFAULT GETDATE()
    );
    PRINT 'Table Monitoring.Servers created.';
END
ELSE
BEGIN
    PRINT 'Table Monitoring.Servers already exists.';
END

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

-- Create indexes
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Jobs_ServerName')
    CREATE INDEX IX_Jobs_ServerName ON Monitoring.Jobs(ServerName);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Jobs_LastRunDate')
    CREATE INDEX IX_Jobs_LastRunDate ON Monitoring.Jobs(LastRunDate);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FailedJobsAlerts_AlertSentTime')
    CREATE INDEX IX_FailedJobsAlerts_AlertSentTime ON Monitoring.FailedJobsAlerts(AlertSentTime);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Servers_CentralServerName')
    CREATE INDEX IX_Servers_CentralServerName ON Monitoring.Servers(CentralServerName);

PRINT 'Target monitoring schema created successfully on ' + @@SERVERNAME;
