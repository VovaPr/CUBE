-- Central Server Rollback - Step 2
-- Drops monitoring procedures from dba_db on DBMGMT.cubecloud.local\SQL01,10010

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

IF OBJECT_ID('Monitoring.SP_PullTargetFailedJobsAlerts', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE Monitoring.SP_PullTargetFailedJobsAlerts;
    PRINT 'Procedure Monitoring.SP_PullTargetFailedJobsAlerts dropped.';
END
ELSE
    PRINT 'Procedure Monitoring.SP_PullTargetFailedJobsAlerts does not exist, nothing to drop.';
GO

PRINT 'Central rollback step 2 complete.';
