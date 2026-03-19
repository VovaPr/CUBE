-- Target Server Setup - Step 3
-- Create monitoring stored procedure on each target server
-- Collects local job statuses and populates local alert table

USE dba_db;
GO

IF OBJECT_ID('Monitoring.SP_MonitoringJobs', 'P') IS NOT NULL
    DROP PROCEDURE Monitoring.SP_MonitoringJobs;
GO

IF OBJECT_ID('Monitoring.SP_CollectJobs', 'P') IS NOT NULL
    DROP PROCEDURE Monitoring.SP_CollectJobs;
GO

IF OBJECT_ID('Monitoring.SP_RefreshFailedJobsAlerts', 'P') IS NOT NULL
    DROP PROCEDURE Monitoring.SP_RefreshFailedJobsAlerts;
GO

CREATE PROCEDURE Monitoring.SP_CollectJobs
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TcpPort NVARCHAR(256);
    DECLARE @TcpDynamicPorts NVARCHAR(256);
    DECLARE @ResolvedPort NVARCHAR(256);
    DECLARE @ServerName NVARCHAR(256);

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
        THROW 50001, 'Unable to resolve SQL Server TCP port for target instance.', 1;

    SET @ServerName =
        CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
        ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'') +
        N',' + @ResolvedPort;
    
    BEGIN TRY
        -- Keep one aggregated server row fresh on target.
        MERGE Monitoring.Servers AS s
        USING (
            SELECT
                CAST(@ServerName AS NVARCHAR(256)) AS ServerName,
                CAST(N'DBMGMT\SQL01,10010' AS NVARCHAR(256)) AS CentralServerName,
                CAST(1 AS BIT) AS IsActive
        ) AS src
            ON s.ServerName = src.ServerName
        WHEN MATCHED THEN
            UPDATE SET
                s.CentralServerName = src.CentralServerName,
                s.IsActive = src.IsActive,
                s.ModifiedAt = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT (ServerName, CentralServerName, IsActive)
            VALUES (src.ServerName, src.CentralServerName, src.IsActive);

        -- Step 1: Collect Job Status from msdb
        MERGE INTO Monitoring.Jobs j
        USING (
            SELECT 
                @ServerName AS ServerName,
                sj.name AS JobName,
                sj.job_id AS SQLJobID,
                sjh.run_status AS LastRunStatus,
                sjh.LastRunDate AS LastRunDate,
                sjh.run_duration AS LastRunDuration,
                nr.NextRunDate AS NextRunDate,
                sj.enabled AS IsEnabled
            FROM msdb.dbo.sysjobs sj
            LEFT JOIN (
                SELECT 
                    job_id,
                    run_status,
                    run_duration,
                    msdb.dbo.agent_datetime(run_date, run_time) AS LastRunDate,
                    ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY instance_id DESC) as rn
                FROM msdb.dbo.sysjobhistory
                WHERE step_id = 0
            ) sjh ON sj.job_id = sjh.job_id AND sjh.rn = 1
            OUTER APPLY (
                SELECT TOP (1)
                    CASE
                        WHEN sjs.next_run_date > 0
                            THEN msdb.dbo.agent_datetime(sjs.next_run_date, sjs.next_run_time)
                        ELSE NULL
                    END AS NextRunDate
                FROM msdb.dbo.sysjobschedules sjs
                WHERE sjs.job_id = sj.job_id
                ORDER BY sjs.next_run_date, sjs.next_run_time
            ) nr
        ) src
            ON j.ServerName = src.ServerName AND j.JobName = src.JobName
        WHEN MATCHED THEN
            UPDATE SET 
                LastRunStatus = src.LastRunStatus,
                LastRunDate = src.LastRunDate,
                LastRunDuration = src.LastRunDuration,
                NextRunDate = src.NextRunDate,
                IsEnabled = src.IsEnabled,
                RecordedDate = GETDATE()
        WHEN NOT MATCHED THEN
            INSERT (ServerName, JobName, SQLJobID, LastRunStatus, LastRunDate, LastRunDuration, NextRunDate, IsEnabled, RecordedDate)
            VALUES (src.ServerName, src.JobName, src.SQLJobID, src.LastRunStatus, src.LastRunDate, src.LastRunDuration, src.NextRunDate, src.IsEnabled, GETDATE());
        
        PRINT 'Job status collection completed successfully on ' + @ServerName;
        
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(MAX) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();
        
        PRINT 'ERROR in Monitoring.SP_CollectJobs:';
        PRINT 'Error Number: ' + CAST(@ErrorNumber AS NVARCHAR(10));
        PRINT 'Error Message: ' + @ErrorMessage;
        
        RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
GO

CREATE PROCEDURE Monitoring.SP_RefreshFailedJobsAlerts
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TcpPort NVARCHAR(256);
    DECLARE @TcpDynamicPorts NVARCHAR(256);
    DECLARE @ResolvedPort NVARCHAR(256);
    DECLARE @ServerName NVARCHAR(256);

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
        THROW 50001, 'Unable to resolve SQL Server TCP port for target instance.', 1;

    SET @ServerName =
        CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
        ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'') +
        N',' + @ResolvedPort;

    BEGIN TRY
        WITH FailedJobs AS (
            SELECT
                ServerName,
                JobName,
                COUNT(*) AS FailureCount,
                MAX(RecordedDate) AS LastFailureTime
            FROM Monitoring.Jobs
            WHERE ServerName = @ServerName
              AND LastRunStatus = 0
              AND LastRunDate >= DATEADD(HOUR, -1, GETDATE())
            GROUP BY ServerName, JobName
        )
        MERGE INTO Monitoring.FailedJobsAlerts fa
        USING FailedJobs fj
            ON fa.ServerName = fj.ServerName
           AND fa.JobName = fj.JobName
           AND fa.IsResolved = 0
        WHEN MATCHED THEN
            UPDATE SET
                FailureCount = fa.FailureCount + fj.FailureCount,
                LastFailureTime = fj.LastFailureTime
        WHEN NOT MATCHED THEN
            INSERT (ServerName, JobName, FailureCount, FirstFailureTime, LastFailureTime)
            VALUES (fj.ServerName, fj.JobName, fj.FailureCount, fj.LastFailureTime, fj.LastFailureTime);

                UPDATE fa
                SET fa.IsResolved = 1,
                        fa.ResolutionTime = GETDATE()
                FROM Monitoring.FailedJobsAlerts fa
                WHERE fa.IsResolved = 0
                    AND fa.ServerName = @ServerName
                    AND EXISTS (
                                SELECT 1
                                FROM Monitoring.Jobs js
                                WHERE js.ServerName = fa.ServerName
                                    AND js.JobName = fa.JobName
                                    AND js.LastRunStatus = 1
                                    AND js.LastRunDate IS NOT NULL
                                    AND js.LastRunDate >= fa.LastFailureTime
                    );

        PRINT 'Failed job analysis completed successfully.';
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(MAX) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();

        PRINT 'ERROR in Monitoring.SP_RefreshFailedJobsAlerts:';
        PRINT 'Error Number: ' + CAST(@ErrorNumber AS NVARCHAR(10));
        PRINT 'Error Message: ' + @ErrorMessage;

        RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
GO

PRINT 'Stored procedures Monitoring.SP_CollectJobs and Monitoring.SP_RefreshFailedJobsAlerts created on target server.';
