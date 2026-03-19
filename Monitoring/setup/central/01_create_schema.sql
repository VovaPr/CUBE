-- Central Server Setup - Step 1
-- Create monitoring schema and tables on DBMGMT.cubecloud.local\SQL01,10010
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
END
GO

-- Technical log for central sqlcmd pull orchestration
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'TargetPullLog' AND schema_id = SCHEMA_ID('Monitoring'))
BEGIN
    CREATE TABLE Monitoring.TargetPullLog (
        TargetPullLogID INT IDENTITY(1,1) PRIMARY KEY,
        RunID UNIQUEIDENTIFIER NOT NULL,
        TargetServer NVARCHAR(256) NULL,
        Stage NVARCHAR(64) NOT NULL,
        IsSuccess BIT NULL,
        Message NVARCHAR(4000) NULL,
        CommandText NVARCHAR(4000) NULL,
        LoggedAt DATETIME2 NOT NULL DEFAULT GETDATE()
    );
END
GO

-- Recreate aggregated server state/registration table with the final schema.
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

INSERT INTO Monitoring.Servers (ServerName, CentralServerName, IsActive, Central, Target)
VALUES (@CentralEndpoint, @CentralEndpoint, 1, 1, 0);
GO

-- Create indexes
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Jobs_ServerName')
    CREATE INDEX IX_Jobs_ServerName ON Monitoring.Jobs(ServerName);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Jobs_LastRunDate')
    CREATE INDEX IX_Jobs_LastRunDate ON Monitoring.Jobs(LastRunDate);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FailedJobsAlerts_AlertSentTime')
    CREATE INDEX IX_FailedJobsAlerts_AlertSentTime ON Monitoring.FailedJobsAlerts(AlertSentTime);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_TargetPullLog_LoggedAt')
    CREATE INDEX IX_TargetPullLog_LoggedAt ON Monitoring.TargetPullLog(LoggedAt);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Servers_CentralServerName')
    CREATE INDEX IX_Servers_CentralServerName ON Monitoring.Servers(CentralServerName);

PRINT 'Central monitoring schema created successfully.';
