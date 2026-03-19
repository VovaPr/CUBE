-- Target Server Setup - Step 4
-- Create Agent Job on each target server
-- Job: DBA - Monitoring Jobs
-- Schedule: Every 30 minutes (00, 30 of each hour)

USE msdb;
GO

-- Create or update SQL Agent operator for monitoring notifications
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

-- Remove legacy and old job names
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Common Monitoring Alerts')
BEGIN
    EXEC sp_delete_job @job_name = 'DBA - Common Monitoring Alerts', @delete_unused_schedule = 1;
END
GO

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Collect Job Status')
BEGIN
    EXEC sp_delete_job @job_name = 'DBA - Collect Job Status', @delete_unused_schedule = 1;
END
GO

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Central Monitoring Jobs')
BEGIN
    EXEC sp_delete_job @job_name = 'DBA - Central Monitoring Jobs', @delete_unused_schedule = 1;
END
GO

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Target Monitoring Jobs')
BEGIN
    EXEC sp_delete_job @job_name = 'DBA - Target Monitoring Jobs', @delete_unused_schedule = 1;
END
GO

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Monitoring Alerts')
BEGIN
    EXEC sp_delete_job @job_name = 'DBA - Monitoring Alerts', @delete_unused_schedule = 1;
END
GO

-- Cleanup orphaned schedules
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Common Monitoring Alerts - Hourly at :05')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Common Monitoring Alerts - Hourly at :05', @force_delete = 1;
END
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Collect Job Status - Hourly at :01')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Collect Job Status - Hourly at :01', @force_delete = 1;
END
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Central Monitoring Jobs - Hourly at :01')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Central Monitoring Jobs - Hourly at :01', @force_delete = 1;
END
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Target Monitoring Jobs - Hourly at :05')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Target Monitoring Jobs - Hourly at :05', @force_delete = 1;
END
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Monitoring Alerts - Every Hour')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Monitoring Alerts - Every Hour', @force_delete = 1;
END
GO

-- Create target monitoring job with 2 steps
EXEC sp_add_job
    @job_name = 'DBA - Monitoring Jobs',
    @enabled = 1,
    @description = 'Target server monitoring: collect local job statuses and refresh failed alerts.',
    @owner_login_name = 'sa',
    @notify_level_email = 2,
    @notify_email_operator_name = N'Monitoring';
GO

-- Step 1: Collect Jobs
EXEC sp_add_jobstep
    @job_name = 'DBA - Monitoring Jobs',
    @step_name = 'Collect Jobs',
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
    @on_success_action = 1,
    @on_fail_action = 2;
GO

-- Create schedule: every 30 minutes
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Monitoring Jobs - Every 30 Minutes')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = 'DBA - Monitoring Jobs - Every 30 Minutes', @force_delete = 1;
END
GO

EXEC sp_add_schedule
    @schedule_name = 'DBA - Monitoring Jobs - Every 30 Minutes',
    @freq_type = 4,
    @freq_interval = 1,
    @freq_subday_type = 2,
    @freq_subday_interval = 30,
    @active_start_time = 000000,
    @active_end_time = 235959;
GO

-- Attach schedule
EXEC sp_attach_schedule
    @job_name = 'DBA - Monitoring Jobs',
    @schedule_name = 'DBA - Monitoring Jobs - Every 30 Minutes';
GO

-- Assign to local server
EXEC sp_add_jobserver
    @job_name = 'DBA - Monitoring Jobs',
    @server_name = N'(local)';
GO

PRINT 'Target Agent Job "DBA - Monitoring Jobs" created successfully (every 30 minutes) on ' + @@SERVERNAME;
