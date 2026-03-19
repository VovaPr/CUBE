-- Target Server Setup - Step 3
-- Create monitoring stored procedure on each target server
-- Collects local job statuses and populates local alert table

USE dba_db;
GO

IF OBJECT_ID('Monitoring.SP_MonitoringJobs', 'P') IS NOT NULL
    DROP PROCEDURE Monitoring.SP_MonitoringJobs;
GO

CREATE PROCEDURE Monitoring.SP_MonitoringJobs
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
        
        -- Step 2: Check for Failed Jobs and Create/Update Alerts
        WITH FailedJobs AS (
            SELECT 
                ServerName,
                JobName,
                COUNT(*) as FailureCount,
                MAX(RecordedDate) as LastFailureTime
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
        
        -- Mark alerts as resolved if jobs are now running successfully
        UPDATE Monitoring.FailedJobsAlerts
        SET IsResolved = 1, ResolutionTime = GETDATE()
        WHERE IsResolved = 0
            AND ServerName = @ServerName
            AND NOT EXISTS (
                SELECT 1 FROM Monitoring.Jobs js
                WHERE js.ServerName = Monitoring.FailedJobsAlerts.ServerName
                    AND js.JobName = Monitoring.FailedJobsAlerts.JobName
                    AND js.LastRunStatus = 0
                    AND js.LastRunDate >= DATEADD(HOUR, -1, GETDATE())
            );
        
        PRINT 'Failed job analysis completed successfully.';
        
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(MAX) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();
        
        PRINT 'ERROR in Monitoring.SP_MonitoringJobs:';
        PRINT 'Error Number: ' + CAST(@ErrorNumber AS NVARCHAR(10));
        PRINT 'Error Message: ' + @ErrorMessage;
        
        RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
GO

PRINT 'Stored procedure Monitoring.SP_MonitoringJobs created on target server.';

IF OBJECT_ID('Monitoring.SP_PushFailedJobsAlertsToCentral', 'P') IS NOT NULL
    DROP PROCEDURE Monitoring.SP_PushFailedJobsAlertsToCentral;
GO

CREATE PROCEDURE Monitoring.SP_PushFailedJobsAlertsToCentral
    @CentralEndpoint NVARCHAR(256) = N'DBMGMT\SQL01,10010'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ServerName NVARCHAR(256);
    DECLARE @JobName NVARCHAR(256);
    DECLARE @FailureCount INT;
    DECLARE @FirstFailureTime DATETIME2;
    DECLARE @LastFailureTime DATETIME2;
    DECLARE @AlertSentTime DATETIME2;
    DECLARE @IsResolved BIT;
    DECLARE @ResolutionTime DATETIME2;

    DECLARE @MergeSql NVARCHAR(MAX);
    DECLARE @RunOnCentralCommand NVARCHAR(MAX);
    DECLARE @xpCmd VARCHAR(8000);
    DECLARE @xpWasEnabled BIT = 0;

    SELECT @xpWasEnabled = CAST(value_in_use AS BIT)
    FROM sys.configurations
    WHERE name = N'xp_cmdshell';

    IF @xpWasEnabled = 0
    BEGIN
        EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
        EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE;
    END;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            ServerName,
            JobName,
            FailureCount,
            FirstFailureTime,
            LastFailureTime,
            AlertSentTime,
            IsResolved,
            ResolutionTime
        FROM Monitoring.FailedJobsAlerts;

    OPEN c;
    FETCH NEXT FROM c INTO @ServerName, @JobName, @FailureCount, @FirstFailureTime, @LastFailureTime, @AlertSentTime, @IsResolved, @ResolutionTime;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @MergeSql =
            N'SET NOCOUNT ON; '
          + N'MERGE dba_db.Monitoring.FailedJobsAlerts AS dst '
          + N'USING (SELECT '
          + N'CAST(N''' + REPLACE(@ServerName, N'''', N'''''') + N''' AS NVARCHAR(256)) AS ServerName, '
          + N'CAST(N''' + REPLACE(@JobName, N'''', N'''''') + N''' AS NVARCHAR(256)) AS JobName, '
          + N'CAST(' + CAST(@FailureCount AS NVARCHAR(20)) + N' AS INT) AS FailureCount, '
          + N'CAST(N''' + CONVERT(NVARCHAR(33), @FirstFailureTime, 126) + N''' AS DATETIME2) AS FirstFailureTime, '
          + N'CAST(N''' + CONVERT(NVARCHAR(33), @LastFailureTime, 126) + N''' AS DATETIME2) AS LastFailureTime, '
          + CASE WHEN @AlertSentTime IS NULL
              THEN N'CAST(NULL AS DATETIME2) AS AlertSentTime, '
              ELSE N'CAST(N''' + CONVERT(NVARCHAR(33), @AlertSentTime, 126) + N''' AS DATETIME2) AS AlertSentTime, '
            END
          + N'CAST(' + CAST(@IsResolved AS NVARCHAR(1)) + N' AS BIT) AS IsResolved, '
          + CASE WHEN @ResolutionTime IS NULL
              THEN N'CAST(NULL AS DATETIME2) AS ResolutionTime '
              ELSE N'CAST(N''' + CONVERT(NVARCHAR(33), @ResolutionTime, 126) + N''' AS DATETIME2) AS ResolutionTime '
            END
          + N') AS src '
          + N'ON dst.ServerName = src.ServerName AND dst.JobName = src.JobName '
          + N'WHEN MATCHED THEN UPDATE SET '
          + N'    dst.FailureCount = src.FailureCount, '
          + N'    dst.FirstFailureTime = src.FirstFailureTime, '
          + N'    dst.LastFailureTime = src.LastFailureTime, '
          + N'    dst.AlertSentTime = src.AlertSentTime, '
          + N'    dst.IsResolved = src.IsResolved, '
          + N'    dst.ResolutionTime = src.ResolutionTime '
          + N'WHEN NOT MATCHED THEN INSERT (ServerName, JobName, FailureCount, FirstFailureTime, LastFailureTime, AlertSentTime, IsResolved, ResolutionTime) '
          + N'VALUES (src.ServerName, src.JobName, src.FailureCount, src.FirstFailureTime, src.LastFailureTime, src.AlertSentTime, src.IsResolved, src.ResolutionTime);';

        SET @RunOnCentralCommand =
            N'sqlcmd -S "' + REPLACE(@CentralEndpoint, N'"', N'""')
          + N'" -d DBA_DB -E -N -C -b -Q "' + REPLACE(@MergeSql, N'"', N'\"') + N'"';

        SET @xpCmd = CAST(@RunOnCentralCommand AS VARCHAR(8000));
        EXEC master..xp_cmdshell @xpCmd, NO_OUTPUT;

        FETCH NEXT FROM c INTO @ServerName, @JobName, @FailureCount, @FirstFailureTime, @LastFailureTime, @AlertSentTime, @IsResolved, @ResolutionTime;
    END;

    CLOSE c;
    DEALLOCATE c;

    IF @xpWasEnabled = 0
    BEGIN
        EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE;
        EXEC sp_configure 'show advanced options', 0; RECONFIGURE;
    END;

    PRINT 'Push to central completed from target via sqlcmd.';
END
GO

PRINT 'Stored procedure Monitoring.SP_PushFailedJobsAlertsToCentral created on target server.';
