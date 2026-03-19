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

-- Recreate aggregated server table with the final schema and seed local rows.
DECLARE @TcpPort NVARCHAR(256);
DECLARE @TcpDynamicPorts NVARCHAR(256);
DECLARE @ResolvedPort NVARCHAR(256);
DECLARE @TargetServerName NVARCHAR(256);
DECLARE @CentralEndpoint NVARCHAR(256) = N'DBMGMT\SQL01,10010';

EXEC master..xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Tcp\IPAll',
    N'TcpPort',
    @TcpPort OUTPUT;

EXEC master..xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Tcp\IPAll',
    N'TcpDynamicPorts',
    @TcpDynamicPorts OUTPUT;

SET @ResolvedPort = COALESCE(
    NULLIF(@TcpPort, N''),
    NULLIF(@TcpDynamicPorts, N''),
    CAST(CONNECTIONPROPERTY('local_tcp_port') AS NVARCHAR(20))
);

IF @ResolvedPort IS NULL
BEGIN
    RAISERROR(N'Unable to resolve SQL Server TCP port for target instance.', 16, 1);
    RETURN;
END;

SET @TargetServerName =
    CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
    ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'') +
    N',' + @ResolvedPort;

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
VALUES (@TargetServerName, @CentralEndpoint, 1, 0, 1);

PRINT 'Server registration rows added for ' + @CentralEndpoint + ' and ' + @TargetServerName;
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
