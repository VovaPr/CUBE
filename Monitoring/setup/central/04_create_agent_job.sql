-- Central Server Setup - Step 4
-- Create Agent Jobs on INFRA-MGMT01
-- Job 1: DBA - Collect Job Status       → runs at :01 every hour
-- Job 2: DBA - Common Monitoring Alerts → runs at :05 every hour
--
-- Separation ensures data is collected (4 min window) before alerts fire.

USE msdb;
GO

-- ============================================================
-- Operator
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'DEVMonitoring')
BEGIN
    EXEC msdb.dbo.sp_add_operator
        @name = N'DEVMonitoring',
        @enabled = 1,
        @weekday_pager_start_time = 90000,
        @weekday_pager_end_time = 180000,
        @saturday_pager_start_time = 90000,
        @saturday_pager_end_time = 180000,
        @sunday_pager_start_time = 90000,
        @sunday_pager_end_time = 180000,
        @pager_days = 0,
        @email_address = N'559c4de8.cube.global@emea.teams.ms',
        @category_name = N'[Uncategorized]';
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_operator
        @name = N'DEVMonitoring',
        @enabled = 1,
        @weekday_pager_start_time = 90000,
        @weekday_pager_end_time = 180000,
        @saturday_pager_start_time = 90000,
        @saturday_pager_end_time = 180000,
        @sunday_pager_start_time = 90000,
        @sunday_pager_end_time = 180000,
        @pager_days = 0,
        @email_address = N'559c4de8.cube.global@emea.teams.ms';
END
GO

-- ============================================================
-- JOB 1: DBA - Collect Job Status  (runs at :01 every hour)
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Collect Job Status')
    EXEC sp_delete_job @job_name = 'DBA - Collect Job Status', @delete_unused_schedule = 1;
GO

EXEC sp_add_job
    @job_name = 'DBA - Collect Job Status',
    @enabled = 1,
    @description = 'Collects local job statuses into Monitoring.Jobs and updates FailedJobsAlerts. Runs at :01 every hour.',
    @owner_login_name = 'sa',
    @notify_level_email = 2,
    @notify_email_operator_name = N'DEVMonitoring';
GO

EXEC sp_add_jobstep
    @job_name = 'DBA - Collect Job Status',
    @step_name = 'Collect Job Status and Check Alerts',
    @step_id = 1,
    @subsystem = 'TSQL',
    @command = 'EXEC dba_db.Monitoring.SP_MonitoringJobs',
    @database_name = 'dba_db',
    @retry_attempts = 3,
    @retry_interval = 1,
    @on_success_action = 1,
    @on_fail_action = 2;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Collect Job Status - Hourly at :01')
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Collect Job Status - Hourly at :01';
GO

EXEC sp_add_schedule
    @schedule_name = 'DBA - Collect Job Status - Hourly at :01',
    @freq_type = 4,
    @freq_interval = 1,
    @freq_subday_type = 8,       -- every N hours
    @freq_subday_interval = 1,
    @active_start_time = 000100, -- start at :01
    @active_end_time = 235959;
GO

EXEC sp_attach_schedule
    @job_name = 'DBA - Collect Job Status',
    @schedule_name = 'DBA - Collect Job Status - Hourly at :01';
GO

EXEC sp_add_jobserver
    @job_name = 'DBA - Collect Job Status',
    @server_name = N'(local)';
GO

-- ============================================================
-- JOB 2: DBA - Common Monitoring Alerts  (runs at :05 every hour)
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Common Monitoring Alerts')
    EXEC sp_delete_job @job_name = 'DBA - Common Monitoring Alerts', @delete_unused_schedule = 1;
GO

EXEC sp_add_job
    @job_name = 'DBA - Common Monitoring Alerts',
    @enabled = 1,
    @description = 'Synchronizes unresolved alerts from monitored target servers and sends email notifications. Runs at :05 every hour.',
    @owner_login_name = 'sa',
    @notify_level_email = 2,
    @notify_email_operator_name = N'DEVMonitoring';
GO

EXEC sp_add_jobstep
    @job_name = 'DBA - Common Monitoring Alerts',
    @step_name = 'Sync Target Alerts To Central',
    @step_id = 1,
    @subsystem = 'TSQL',
    @command = '
DECLARE @TargetServer SYSNAME;
DECLARE @TargetPort INT;
DECLARE @LinkedServerName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #RemoteUnresolvedAlerts (
    ServerName NVARCHAR(256) NOT NULL,
    JobName NVARCHAR(256) NOT NULL,
    FailureCount INT NULL,
    FirstFailureTime DATETIME2 NULL,
    LastFailureTime DATETIME2 NULL
);

CREATE TABLE #PolledServers (
    ServerName SYSNAME NOT NULL PRIMARY KEY
);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT ServerName, Port, LinkedServerName
    FROM dba_db.Monitoring.MonitoredServers
    WHERE IsActive = 1;

OPEN cur;
FETCH NEXT FROM cur INTO @TargetServer, @TargetPort, @LinkedServerName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        IF NULLIF(@LinkedServerName, N'''') IS NOT NULL
           AND EXISTS (SELECT 1 FROM sys.servers WHERE name = @LinkedServerName)
        BEGIN
            SET @Sql = N''
                SELECT
                    ServerName,
                    JobName,
                    FailureCount,
                    FirstFailureTime,
                    LastFailureTime
                FROM '' + QUOTENAME(@LinkedServerName) + N''.[dba_db].[Monitoring].[FailedJobsAlerts]
                WHERE IsResolved = 0;'';
        END
        ELSE
        BEGIN
            SET @Sql = N''
                SELECT
                    ServerName,
                    JobName,
                    FailureCount,
                    FirstFailureTime,
                    LastFailureTime
                FROM OPENROWSET(
                    ''''MSOLEDBSQL'''',
                    ''''Server=''+REPLACE(@TargetServer, '''''''', '''''''''''')+'',''+CAST(ISNULL(@TargetPort, 1433) AS NVARCHAR(10))+'';Trusted_Connection=Yes;Encrypt=yes;TrustServerCertificate=Yes;'''',
                    ''''SELECT
                        ServerName,
                        JobName,
                        FailureCount,
                        FirstFailureTime,
                        LastFailureTime
                      FROM dba_db.Monitoring.FailedJobsAlerts
                      WHERE IsResolved = 0''''
                );'';
        END

        INSERT INTO #RemoteUnresolvedAlerts (ServerName, JobName, FailureCount, FirstFailureTime, LastFailureTime)
        EXEC sp_executesql @Sql;

        IF NOT EXISTS (SELECT 1 FROM #PolledServers WHERE ServerName = @TargetServer)
            INSERT INTO #PolledServers (ServerName) VALUES (@TargetServer);

        IF NULLIF(@LinkedServerName, N'''') IS NOT NULL
           AND EXISTS (SELECT 1 FROM sys.servers WHERE name = @LinkedServerName)
        BEGIN
            PRINT ''Synchronized alerts from linked server '' + @LinkedServerName + '' for '' + @TargetServer;
        END
        ELSE
        BEGIN
            PRINT ''Synchronized alerts from '' + @TargetServer + '':'' + CAST(ISNULL(@TargetPort, 1433) AS NVARCHAR(10));
        END
    END TRY
    BEGIN CATCH
        PRINT ''Failed to read alerts from '' + @TargetServer
            + CASE
                WHEN NULLIF(@LinkedServerName, N'''') IS NOT NULL THEN '' (linked server '' + @LinkedServerName + '')''
                ELSE '':'' + CAST(ISNULL(@TargetPort, 1433) AS NVARCHAR(10))
              END
            + '': '' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM cur INTO @TargetServer, @TargetPort, @LinkedServerName;
END

CLOSE cur;
DEALLOCATE cur;

MERGE dba_db.Monitoring.FailedJobsAlerts AS dst
USING #RemoteUnresolvedAlerts AS src
    ON dst.ServerName = src.ServerName
   AND dst.JobName = src.JobName
   AND dst.IsResolved = 0
WHEN MATCHED THEN
    UPDATE SET
        dst.FailureCount = ISNULL(src.FailureCount, dst.FailureCount),
        dst.FirstFailureTime = CASE
            WHEN src.FirstFailureTime IS NULL THEN dst.FirstFailureTime
            WHEN dst.FirstFailureTime IS NULL THEN src.FirstFailureTime
            WHEN src.FirstFailureTime < dst.FirstFailureTime THEN src.FirstFailureTime
            ELSE dst.FirstFailureTime
        END,
        dst.LastFailureTime = ISNULL(src.LastFailureTime, dst.LastFailureTime)
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ServerName, JobName, FailureCount, FirstFailureTime, LastFailureTime, AlertSentTime, IsResolved)
    VALUES (
        src.ServerName,
        src.JobName,
        ISNULL(src.FailureCount, 1),
        ISNULL(src.FirstFailureTime, GETDATE()),
        ISNULL(src.LastFailureTime, GETDATE()),
        NULL,
        0
    );

UPDATE dst
SET dst.IsResolved = 1,
    dst.ResolutionTime = GETDATE()
FROM dba_db.Monitoring.FailedJobsAlerts AS dst
JOIN #PolledServers AS ps
  ON ps.ServerName = dst.ServerName
LEFT JOIN #RemoteUnresolvedAlerts AS src
  ON src.ServerName = dst.ServerName
 AND src.JobName = dst.JobName
WHERE dst.IsResolved = 0
  AND src.JobName IS NULL;

PRINT ''Target alert synchronization completed.'';
',
    @database_name = 'dba_db',
    @retry_attempts = 3,
    @retry_interval = 1,
    @on_success_action = 3,
    @on_success_step_id = 2,
    @on_fail_action = 2;
GO

EXEC sp_add_jobstep
    @job_name = 'DBA - Common Monitoring Alerts',
    @step_name = 'Send Email Alerts',
    @step_id = 2,
    @subsystem = 'TSQL',
    @command = 'EXEC dba_db.Monitoring.SP_SendAlerts @EmailRecipient = ''559c4de8.cube.global@emea.teams.ms'', @MailProfile = ''SQLAlerts''',
    @database_name = 'dba_db',
    @retry_attempts = 3,
    @retry_interval = 1,
    @on_success_action = 1,
    @on_fail_action = 2;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Common Monitoring Alerts - Hourly at :05')
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Common Monitoring Alerts - Hourly at :05';
GO

EXEC sp_add_schedule
    @schedule_name = 'DBA - Common Monitoring Alerts - Hourly at :05',
    @freq_type = 4,
    @freq_interval = 1,
    @freq_subday_type = 8,       -- every N hours
    @freq_subday_interval = 1,
    @active_start_time = 000500, -- start at :05
    @active_end_time = 235959;
GO

EXEC sp_attach_schedule
    @job_name = 'DBA - Common Monitoring Alerts',
    @schedule_name = 'DBA - Common Monitoring Alerts - Hourly at :05';
GO

EXEC sp_add_jobserver
    @job_name = 'DBA - Common Monitoring Alerts',
    @server_name = N'(local)';
GO

PRINT 'Central Agent Jobs created successfully:';
PRINT '  DBA - Collect Job Status       → every hour at :01';
PRINT '  DBA - Common Monitoring Alerts → every hour at :05';
