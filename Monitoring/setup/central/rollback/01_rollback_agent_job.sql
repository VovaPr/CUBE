-- Central Server Rollback - Step 4
-- Removes both central Agent jobs, their schedules, and the Monitoring operator
-- from DBMGMT.cubecloud.local\SQL01,10010.
--
-- Reverses: 04_create_agent_job.sql
--   Job 1: DBA - Central Monitoring Jobs     (schedule: DBA - Central Monitoring Jobs - Hourly at :01)
--   Job 2: DBA - Target Monitoring Jobs      (schedule: DBA - Target Monitoring Jobs - Hourly at :05)
-- Also removes previous job versions:
--   DBA - Collect Job Status
--   DBA - Common Monitoring Alerts
--   Operator: Monitoring

USE msdb;
GO

-- ============================================================
-- Remove Job 1: DBA - Central Monitoring Jobs
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Central Monitoring Jobs')
BEGIN
    EXEC sp_delete_job
        @job_name = 'DBA - Central Monitoring Jobs',
        @delete_unused_schedule = 1;
    PRINT 'Job "DBA - Central Monitoring Jobs" deleted.';
END
ELSE
    PRINT 'Job "DBA - Central Monitoring Jobs" does not exist, nothing to delete.';
GO

-- Safety: drop orphaned schedule if still present
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Central Monitoring Jobs - Hourly at :01')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule
        @schedule_name = 'DBA - Central Monitoring Jobs - Hourly at :01',
        @force_delete = 1;
    PRINT 'Schedule "DBA - Central Monitoring Jobs - Hourly at :01" deleted.';
END
GO

-- ============================================================
-- Remove Job 2: DBA - Target Monitoring Jobs
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Target Monitoring Jobs')
BEGIN
    EXEC sp_delete_job
        @job_name = 'DBA - Target Monitoring Jobs',
        @delete_unused_schedule = 1;
    PRINT 'Job "DBA - Target Monitoring Jobs" deleted.';
END
ELSE
    PRINT 'Job "DBA - Target Monitoring Jobs" does not exist, nothing to delete.';
GO

-- Safety: drop orphaned schedule if still present
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Target Monitoring Jobs - Hourly at :05')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule
        @schedule_name = 'DBA - Target Monitoring Jobs - Hourly at :05',
        @force_delete = 1;
    PRINT 'Schedule "DBA - Target Monitoring Jobs - Hourly at :05" deleted.';
END
GO

-- Remove previous job versions and schedules
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Collect Job Status')
BEGIN
    EXEC sp_delete_job
        @job_name = 'DBA - Collect Job Status',
        @delete_unused_schedule = 1;
    PRINT 'Legacy job "DBA - Collect Job Status" deleted.';
END
GO

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'DBA - Common Monitoring Alerts')
BEGIN
    EXEC sp_delete_job
        @job_name = 'DBA - Common Monitoring Alerts',
        @delete_unused_schedule = 1;
    PRINT 'Legacy job "DBA - Common Monitoring Alerts" deleted.';
END
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Collect Job Status - Hourly at :01')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule
        @schedule_name = 'DBA - Collect Job Status - Hourly at :01',
        @force_delete = 1;
    PRINT 'Legacy schedule "DBA - Collect Job Status - Hourly at :01" deleted.';
END
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'DBA - Common Monitoring Alerts - Hourly at :05')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule
        @schedule_name = 'DBA - Common Monitoring Alerts - Hourly at :05',
        @force_delete = 1;
    PRINT 'Legacy schedule "DBA - Common Monitoring Alerts - Hourly at :05" deleted.';
END
GO

-- ============================================================
-- Remove Operator: Monitoring
-- NOTE: Only drop if no other jobs still reference this operator.
--       Comment out if the operator is shared with other jobs.
-- ============================================================
IF EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'Monitoring')
BEGIN
    EXEC msdb.dbo.sp_delete_operator @name = N'Monitoring';
    PRINT 'Operator Monitoring deleted.';
END
ELSE
    PRINT 'Operator Monitoring does not exist, nothing to delete.';
GO

PRINT 'Central rollback step 4 complete (jobs and operator removed from ' + @@SERVERNAME + ').';
