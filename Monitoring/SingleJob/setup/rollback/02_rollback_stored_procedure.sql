-- SingleJob Rollback - Step 2
-- Drops SP_SendSqlJobsLastRunStatusAlert from DBA_DB.
--
-- Reverses: 01_create_stored_procedure.sql

USE [DBA_DB];
GO

IF OBJECT_ID('dbo.SP_SendSqlJobsLastRunStatusAlert', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE dbo.SP_SendSqlJobsLastRunStatusAlert;
    PRINT 'Procedure dbo.SP_SendSqlJobsLastRunStatusAlert dropped.';
END
ELSE
    PRINT 'Procedure dbo.SP_SendSqlJobsLastRunStatusAlert does not exist, nothing to drop.';
GO
