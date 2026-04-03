-- SingleJob Rollback - Step 2
-- Drops SP_SendSqlJobsLastRunStatusReport from DBA_DB.
--
-- Reverses: 01_create_stored_procedure.sql

USE [DBA_DB];
GO

IF OBJECT_ID('dbo.SP_SendSqlJobsLastRunStatusReport', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE dbo.SP_SendSqlJobsLastRunStatusReport;
    PRINT 'Procedure dbo.SP_SendSqlJobsLastRunStatusReport dropped.';
END
ELSE
    PRINT 'Procedure dbo.SP_SendSqlJobsLastRunStatusReport does not exist, nothing to drop.';
GO
