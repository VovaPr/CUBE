-- SingleJob Setup - Step 2
-- Create Agent Job on the target server.
-- Job: DBA - SQL Jobs Last Run Status Alert -> runs at :01 every hour
--
-- Prerequisite: Step 1 (01_create_stored_procedure.sql) must be applied first.
-- Prerequisite: Monitoring operator must exist (created by central setup or manually).

USE msdb;
GO

-- ============================================================
-- Operator (idempotent - create if not already present)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'Monitoring')
BEGIN
    EXEC msdb.dbo.sp_add_operator
        @name                         = N'Monitoring',
        @enabled                      = 1,
        @weekday_pager_start_time     = 90000,
        @weekday_pager_end_time       = 180000,
        @saturday_pager_start_time    = 90000,
        @saturday_pager_end_time      = 180000,
        @sunday_pager_start_time      = 90000,
        @sunday_pager_end_time        = 180000,
        @pager_days                   = 0,
        @email_address                = N'559c4de8.cube.global@emea.teams.ms',
        @category_name                = N'[Uncategorized]';
    PRINT 'Operator "Monitoring" created.';
END
ELSE
    PRINT 'Operator "Monitoring" already exists, skipping.';
GO

-- ============================================================
-- JOB: DBA - SQL Jobs Last Run Status Alert
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'DBA - SQL Jobs Last Run Status Alert')
BEGIN
    EXEC sp_delete_job
        @job_name                = N'DBA - SQL Jobs Last Run Status Alert',
        @delete_unused_schedule  = 1;
    PRINT 'Existing job "DBA - SQL Jobs Last Run Status Alert" deleted before re-creation.';
END
GO

EXEC sp_add_job
    @job_name                   = N'DBA - SQL Jobs Last Run Status Alert',
    @enabled                    = 1,
    @description                = N'Checks the last run outcome of every enabled SQL Agent job. Sends an HTML email alert if any job last ended with Failed or Canceled.',
    @owner_login_name           = N'sa',
    @notify_level_email         = 2,
    @notify_email_operator_name = N'Monitoring';
PRINT 'Job "DBA - SQL Jobs Last Run Status Alert" created.';
GO

-- Step 1: Send Last Run Status Alert
EXEC sp_add_jobstep
    @job_name        = N'DBA - SQL Jobs Last Run Status Alert',
    @step_name       = N'Send Last Run Status Alert',
    @step_id         = 1,
    @subsystem       = N'TSQL',
    @command         = N'EXEC DBA_DB.dbo.SP_SendSqlJobsLastRunStatusAlert',
    @database_name   = N'DBA_DB',
    @retry_attempts  = 2,
    @retry_interval  = 1,
    @on_success_action = 1,
    @on_fail_action    = 2;
PRINT 'Job step "Send Last Run Status Alert" created.';
GO

-- ============================================================
-- Schedule: every hour at :01
-- ============================================================
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'DBA - SQL Jobs Last Run Status Alert - Hourly at :01')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule
        @schedule_name = N'DBA - SQL Jobs Last Run Status Alert - Hourly at :01',
        @force_delete  = 1;
    PRINT 'Existing schedule "DBA - SQL Jobs Last Run Status Alert - Hourly at :01" deleted before re-creation.';
END
ELSE
    PRINT 'Schedule "DBA - SQL Jobs Last Run Status Alert - Hourly at :01" does not exist, will be created.';
GO

EXEC sp_add_schedule
    @schedule_name      = N'DBA - SQL Jobs Last Run Status Alert - Hourly at :01',
    @freq_type          = 4,
    @freq_interval      = 1,
    @freq_subday_type   = 8,
    @freq_subday_interval = 1,
    @active_start_time  = 000100,
    @active_end_time    = 235959;
PRINT 'Schedule "DBA - SQL Jobs Last Run Status Alert - Hourly at :01" created.';
GO

EXEC sp_attach_schedule
    @job_name      = N'DBA - SQL Jobs Last Run Status Alert',
    @schedule_name = N'DBA - SQL Jobs Last Run Status Alert - Hourly at :01';
PRINT 'Schedule attached to job.';
GO

EXEC sp_add_jobserver
    @job_name    = N'DBA - SQL Jobs Last Run Status Alert',
    @server_name = N'(local)';
PRINT 'Job registered on local server. Setup complete.';
GO
