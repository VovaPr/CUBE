-- SingleJob Rollback - Step 2
-- Drops SP_SendSqlAgentLastRunStatusReport from DBA_DB.
--
-- Reverses: 01_create_stored_procedure.sql

USE [DBA_DB];
GO

IF OBJECT_ID('dbo.SP_SendSqlAgentLastRunStatusReport', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE dbo.SP_SendSqlAgentLastRunStatusReport;
    PRINT 'Procedure dbo.SP_SendSqlAgentLastRunStatusReport dropped.';
END
ELSE
    PRINT 'Procedure dbo.SP_SendSqlAgentLastRunStatusReport does not exist, nothing to drop.';
GO
