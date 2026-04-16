-- SingleJob Setup - Step 3
-- Resolve recipients by environment and update SQL Agent job step command.
--
-- Prerequisite: Step 2 (02_create_agent_job.sql) must be applied first.
-- This script keeps stored procedure parameter @Recipients = NULL by default
-- and injects environment-specific recipients into the job step command.

USE msdb;
GO

DECLARE @ServerName NVARCHAR(128) = CAST(@@SERVERNAME AS NVARCHAR(128));
DECLARE @Environment NVARCHAR(10);
DECLARE @Recipients NVARCHAR(MAX);
DECLARE @Command NVARCHAR(MAX);

SET @Environment = CASE
    WHEN @ServerName LIKE N'%UAT%' THEN N'UAT'
    WHEN @ServerName LIKE N'%TEST%' OR @ServerName LIKE N'%TST%' THEN N'TEST'
    WHEN @ServerName LIKE N'%DEV%' THEN N'DEV'
    ELSE N'PROD'
END;

DROP TABLE IF EXISTS #AlertRecipientsByEnv;

CREATE TABLE #AlertRecipientsByEnv
(
     EnvironmentName NVARCHAR(10) PRIMARY KEY
    ,Recipients      NVARCHAR(MAX) NOT NULL
);

INSERT INTO #AlertRecipientsByEnv (EnvironmentName, Recipients)
VALUES
     (N'DEV',  N'DEV Monitoring - Database Team <eba2b854.cube.global@emea.teams.ms>')
    ,(N'TEST', N'TEST Monitoring - Database Team <7369ba4a.cube.global@emea.teams.ms>')
    ,(N'UAT',  N'UAT Monitoring - Database Team <145871a8.cube.global@emea.teams.ms>')
    ,(N'PROD', N'Prod - SQL Errors and Long Running Queries - Database Team <61f17278.cube.global@emea.teams.ms>');

SELECT @Recipients = r.Recipients
FROM #AlertRecipientsByEnv r
WHERE r.EnvironmentName = @Environment;

IF @Recipients IS NULL
BEGIN
    RAISERROR(N'No recipients configured for environment %s.', 16, 1, @Environment);
    RETURN;
END;

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysjobs j
    WHERE j.[name] = N'DBA - SQL Jobs Last Run Status Alert'
)
BEGIN
    RAISERROR(N'Job "DBA - SQL Jobs Last Run Status Alert" does not exist. Run 02_create_agent_job.sql first.', 16, 1);
    RETURN;
END;

SET @Command =
    N'EXEC DBA_DB.dbo.SP_SendSqlJobsLastRunStatusAlert ' +
    N'@Recipients = N''' + REPLACE(@Recipients, N'''', N'''''') + N'''';

EXEC msdb.dbo.sp_update_jobstep
    @job_name = N'DBA - SQL Jobs Last Run Status Alert',
    @step_id = 1,
    @command = @Command;

PRINT 'Environment detected: ' + @Environment;
PRINT 'Recipients mapped: ' + @Recipients;
PRINT 'Job step command updated successfully.';
GO
