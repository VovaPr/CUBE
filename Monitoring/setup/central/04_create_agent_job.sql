-- Central Server Setup - Step 4
-- Create Agent Job on DBMGMT.cubecloud.local\SQL01,10010
-- Job: DBA - Monitoring Jobs -> runs at :01 every hour
--
-- Single job orchestration: collect local jobs → refresh alerts → pull from targets → send notifications

USE msdb;
GO

-- ============================================================
-- Operator
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'Monitoring')
BEGIN
    EXEC msdb.dbo.sp_add_operator
        @name = N'Monitoring',
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
        @name = N'Monitoring',
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

-- Remove previous central job names (legacy)
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Collect Job Status')
    EXEC sp_delete_job @job_name = 'DBA - Collect Job Status', @delete_unused_schedule = 1;
GO
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Common Monitoring Alerts')
    EXEC sp_delete_job @job_name = 'DBA - Common Monitoring Alerts', @delete_unused_schedule = 1;
GO
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Central Monitoring Jobs')
    EXEC sp_delete_job @job_name = 'DBA - Central Monitoring Jobs', @delete_unused_schedule = 1;
GO
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Target Monitoring Jobs')
    EXEC sp_delete_job @job_name = 'DBA - Target Monitoring Jobs', @delete_unused_schedule = 1;
GO

-- ============================================================
-- JOB: DBA - Monitoring Jobs  (runs at :01 every hour)
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Monitoring Jobs')
    EXEC sp_delete_job @job_name = 'DBA - Monitoring Jobs', @delete_unused_schedule = 1;
GO

EXEC sp_add_job
    @job_name = 'DBA - Monitoring Jobs',
    @enabled = 1,
    @description = 'Central monitoring orchestration: collect central jobs, refresh alerts, pull from targets via sqlcmd, send email notifications.',
    @owner_login_name = 'sa',
    @notify_level_email = 2,
    @notify_email_operator_name = N'Monitoring';
GO

-- Step 1: Collect Current Jobs
EXEC sp_add_jobstep
    @job_name = 'DBA - Monitoring Jobs',
    @step_name = 'Collect Current Jobs',
    @step_id = 1,
    @subsystem = 'TSQL',
    @command = 'EXEC dba_db.Monitoring.SP_CollectJobs',
    @database_name = 'dba_db',
    @retry_attempts = 3,
    @retry_interval = 1,
    @on_success_action = 3,
    @on_fail_action = 2;
GO

-- Step 2: Refresh Failed Alerts
EXEC sp_add_jobstep
    @job_name = 'DBA - Monitoring Jobs',
    @step_name = 'Refresh Failed Alerts',
    @step_id = 2,
    @subsystem = 'TSQL',
    @command = 'EXEC dba_db.Monitoring.SP_RefreshFailedJobsAlerts',
    @database_name = 'dba_db',
    @retry_attempts = 3,
    @retry_interval = 1,
    @on_success_action = 3,
    @on_fail_action = 2;
GO

-- Step 3: Pull Target Failed Alerts
EXEC sp_add_jobstep
    @job_name = 'DBA - Monitoring Jobs',
    @step_name = 'Pull Target Failed Alerts',
    @step_id = 3,
    @subsystem = 'TSQL',
    @command = 'EXEC dba_db.Monitoring.SP_PullTargetFailedJobsAlerts',
    @database_name = 'dba_db',
    @retry_attempts = 3,
    @retry_interval = 1,
    @on_success_action = 3,
    @on_fail_action = 2;
GO

-- Step 4: Send Email Alerts
EXEC sp_add_jobstep
    @job_name = 'DBA - Monitoring Jobs',
    @step_name = 'Send Email Alerts',
    @step_id = 4,
    @subsystem = 'TSQL',
    @command = 'EXEC dba_db.Monitoring.SP_SendAlerts @OperatorName = ''Monitoring'', @MailProfile = ''SQLAlerts''',
    @database_name = 'dba_db',
    @retry_attempts = 3,
    @retry_interval = 1,
    @on_success_action = 1,
    @on_fail_action = 2;
GO

-- Create schedule and attach
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Collect Job Status - Hourly at :01')
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Collect Job Status - Hourly at :01';
GO
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Central Monitoring Jobs - Hourly at :01')
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Central Monitoring Jobs - Hourly at :01';
GO
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Target Monitoring Jobs - Hourly at :05')
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Target Monitoring Jobs - Hourly at :05';
GO

EXEC sp_add_schedule
    @schedule_name = 'DBA - Monitoring Jobs - Hourly at :01',
    @freq_type = 4,
    @freq_interval = 1,
    @freq_subday_type = 8,
    @freq_subday_interval = 1,
    @active_start_time = 000100,
    @active_end_time = 235959;
GO

EXEC sp_attach_schedule
    @job_name = 'DBA - Monitoring Jobs',
    @schedule_name = 'DBA - Monitoring Jobs - Hourly at :01';
GO

EXEC sp_add_jobserver
    @job_name = 'DBA - Monitoring Jobs',
    @server_name = N'(local)';
GO
