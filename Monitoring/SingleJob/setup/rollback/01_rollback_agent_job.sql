-- SingleJob Rollback - Step 1
-- Removes the Agent Job and its schedule.
--
-- Reverses: 02_create_agent_job.sql
--   Job:      DBA - SQL Jobs Last Run Status Alert
--   Schedule: DBA - SQL Jobs Last Run Status Alert - Hourly at :01

USE msdb;
GO

-- ============================================================
-- Remove Job
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'DBA - SQL Jobs Last Run Status Alert')
BEGIN
    EXEC sp_delete_job
        @job_name               = N'DBA - SQL Jobs Last Run Status Alert',
        @delete_unused_schedule = 1;
    PRINT 'Job "DBA - SQL Jobs Last Run Status Alert" deleted.';
END
ELSE
    PRINT 'Job "DBA - SQL Jobs Last Run Status Alert" does not exist, nothing to delete.';
GO

-- Safety: drop orphaned schedule if still present after job deletion
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'DBA - SQL Jobs Last Run Status Alert - Hourly at :01')
BEGIN
    EXEC msdb.dbo.sp_delete_schedule
        @schedule_name          = N'DBA - SQL Jobs Last Run Status Alert - Hourly at :01',
        @force_delete           = 1;
    PRINT 'Orphaned schedule "DBA - SQL Jobs Last Run Status Alert - Hourly at :01" deleted.';
END
ELSE
    PRINT 'Schedule "DBA - SQL Jobs Last Run Status Alert - Hourly at :01" does not exist, nothing to delete.';
GO
