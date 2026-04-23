-- Target Server Rollback - Step 2
-- Drops monitoring stored procedures from dba_db on the target server

USE dba_db;
GO

IF OBJECT_ID('Monitoring.SP_CollectJobs', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE Monitoring.SP_CollectJobs;
    PRINT 'Procedure Monitoring.SP_CollectJobs dropped.';
END
ELSE
    PRINT 'Procedure Monitoring.SP_CollectJobs does not exist, nothing to drop.';
GO

IF OBJECT_ID('Monitoring.SP_RefreshFailedJobsAlerts', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE Monitoring.SP_RefreshFailedJobsAlerts;
    PRINT 'Procedure Monitoring.SP_RefreshFailedJobsAlerts dropped.';
END
ELSE
    PRINT 'Procedure Monitoring.SP_RefreshFailedJobsAlerts does not exist, nothing to drop.';
GO

IF OBJECT_ID('Monitoring.SP_MonitoringJobs', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE Monitoring.SP_MonitoringJobs;
    PRINT 'Legacy procedure Monitoring.SP_MonitoringJobs dropped.';
END
GO

PRINT 'Target rollback step 2 complete (procedure removed from ' + @@SERVERNAME + ').';
