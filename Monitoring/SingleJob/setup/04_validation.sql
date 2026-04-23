-- SingleJob Setup - Step 4
-- Validation: create an intentionally failing test job, run alert job, then cleanup.
--
-- Prerequisite: Steps 1-3 must be applied first.
-- Outcome:
--   1) Test job "DBA - Monitoring Alerts (TEST Failed job)" is created.
--   2) Test job is executed and expected to fail.
--   3) Main alert job "DBA - SQL Jobs Last Run Status Alert" is executed.
--   4) Database Mail is checked to confirm the alert email was sent.
--   5) Test job is removed.

USE [msdb];
GO

DECLARE @TestJobName SYSNAME = N'DBA - Monitoring Alerts (TEST Failed job)';
DECLARE @AlertJobName SYSNAME = N'DBA - SQL Jobs Last Run Status Alert';
DECLARE @PollDelay NVARCHAR(12) = N'00:00:02';
DECLARE @MaxPolls INT = 120; -- ~4 minutes
DECLARE @CleanupTestJob BIT = 1; -- Set to 0 for troubleshooting to keep test job and its history visible.

DECLARE @CurrentSessionId INT;
DECLARE @TestJobId UNIQUEIDENTIFIER;
DECLARE @AlertJobId UNIQUEIDENTIFIER;
DECLARE @PollCounter INT;
DECLARE @IsRunning INT;
DECLARE @LastRunStatus INT;
DECLARE @HistoryInstanceId INT;
DECLARE @ExpectedSubject NVARCHAR(256) = CAST(@@SERVERNAME AS NVARCHAR(128)) + N' SQL Jobs Last Run Status Alert';
DECLARE @MailBaselineId INT;
DECLARE @MailItemId INT;
DECLARE @MailSentStatus NVARCHAR(20);

-- Keep script idempotent when re-run.
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @TestJobName)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = @TestJobName,
        @delete_unused_schedule = 1;
    PRINT N'Existing test job removed before validation re-run.';
END;

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.syscategories
    WHERE [name] = N'[Uncategorized (Local)]'
      AND category_class = 1
)
BEGIN
    EXEC msdb.dbo.sp_add_category
        @class = N'JOB',
        @type = N'LOCAL',
        @name = N'[Uncategorized (Local)]';
END;

EXEC msdb.dbo.sp_add_job
    @job_name = @TestJobName,
    @enabled = 1,
    @notify_level_eventlog = 2,
    @notify_level_email = 0,
    @notify_level_netsend = 0,
    @notify_level_page = 0,
    @delete_level = 0,
    @description = N'Validation-only test job. Expected to fail.',
    @category_name = N'[Uncategorized (Local)]',
    @owner_login_name = N'sa';

SET @TestJobId = (SELECT job_id FROM msdb.dbo.sysjobs WHERE [name] = @TestJobName);

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @TestJobId,
    @step_name = N'Collect Job Status and Check Alerts',
    @step_id = 1,
    @cmdexec_success_code = 0,
    @on_success_action = 1,
    @on_success_step_id = 0,
    @on_fail_action = 2,
    @on_fail_step_id = 0,
    @retry_attempts = 0,
    @retry_interval = 1,
    @os_run_priority = 0,
    @subsystem = N'TSQL',
    @command = N'EXEC dba_db.Monitoring.SP_RefreshFailedJobsAlerts',
    @database_name = N'dba_db',
    @flags = 0;

EXEC msdb.dbo.sp_update_job
    @job_id = @TestJobId,
    @start_step_id = 1;

EXEC msdb.dbo.sp_add_jobserver
    @job_id = @TestJobId,
    @server_name = N'(local)';

PRINT N'Test job created: ' + @TestJobName;

SELECT @HistoryInstanceId = ISNULL(MAX(h.instance_id), 0)
FROM msdb.dbo.sysjobhistory h
WHERE h.job_id = @TestJobId
    AND h.step_id = 0;

-- Run the test job and wait for completion.
EXEC msdb.dbo.sp_start_job @job_name = @TestJobName;
PRINT N'Test job started. Waiting for completion...';

SELECT @CurrentSessionId = MAX(session_id)
FROM msdb.dbo.syssessions;

SET @PollCounter = 0;
WHILE @PollCounter < @MaxPolls
BEGIN
    SELECT @IsRunning = CASE
        WHEN ja.start_execution_date IS NOT NULL
         AND ja.stop_execution_date IS NULL THEN 1
        ELSE 0
    END
    FROM msdb.dbo.sysjobactivity ja
    WHERE ja.session_id = @CurrentSessionId
      AND ja.job_id = @TestJobId;

    IF ISNULL(@IsRunning, 0) = 0
        BREAK;

    SET @PollCounter += 1;
    WAITFOR DELAY @PollDelay;
END;

IF @PollCounter >= @MaxPolls
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = @TestJobName,
        @delete_unused_schedule = 1;
    RAISERROR(N'Validation timeout: test job did not finish in expected time.', 16, 1);
    RETURN;
END;

SET @PollCounter = 0;
SET @LastRunStatus = NULL;
WHILE @PollCounter < @MaxPolls
BEGIN
    SELECT TOP (1)
         @LastRunStatus = h.run_status
        ,@HistoryInstanceId = h.instance_id
    FROM msdb.dbo.sysjobhistory h
    WHERE h.job_id = @TestJobId
      AND h.step_id = 0
      AND h.instance_id > ISNULL(@HistoryInstanceId, 0)
    ORDER BY h.instance_id DESC;

    IF @LastRunStatus IS NOT NULL
        BREAK;

    SET @PollCounter += 1;
    WAITFOR DELAY @PollDelay;
END;

IF @LastRunStatus IS NULL
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = @TestJobName,
        @delete_unused_schedule = 1;
    RAISERROR(N'Validation failed: no job-level history row was written for the test job in expected time.', 16, 1);
    RETURN;
END;

IF @LastRunStatus NOT IN (0, 3)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = @TestJobName,
        @delete_unused_schedule = 1;
    RAISERROR(N'Validation failed: test job did not end with Failed/Canceled status.', 16, 1);
    RETURN;
END;

PRINT N'Test job failed as expected (run_status=' + CAST(@LastRunStatus AS NVARCHAR(10)) + N').';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @AlertJobName)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = @TestJobName,
        @delete_unused_schedule = 1;
    RAISERROR(N'Alert job "DBA - SQL Jobs Last Run Status Alert" does not exist. Apply Step 2 first.', 16, 1);
    RETURN;
END;

SELECT @MailBaselineId = ISNULL(MAX(mailitem_id), 0)
FROM msdb.dbo.sysmail_allitems;

EXEC msdb.dbo.sp_start_job @job_name = @AlertJobName;
PRINT N'Alert job started: ' + @AlertJobName;

SET @AlertJobId = (SELECT job_id FROM msdb.dbo.sysjobs WHERE [name] = @AlertJobName);

SET @PollCounter = 0;
WHILE @PollCounter < @MaxPolls
BEGIN
    SELECT @IsRunning = CASE
        WHEN ja.start_execution_date IS NOT NULL
         AND ja.stop_execution_date IS NULL THEN 1
        ELSE 0
    END
    FROM msdb.dbo.sysjobactivity ja
    WHERE ja.session_id = @CurrentSessionId
      AND ja.job_id = @AlertJobId;

    IF ISNULL(@IsRunning, 0) = 0
        BREAK;

    SET @PollCounter += 1;
    WAITFOR DELAY @PollDelay;
END;

SET @PollCounter = 0;
SET @MailItemId = NULL;
SET @MailSentStatus = NULL;
WHILE @PollCounter < @MaxPolls
BEGIN
    SELECT TOP (1)
         @MailItemId = ai.mailitem_id
        ,@MailSentStatus = ai.sent_status
    FROM msdb.dbo.sysmail_allitems ai
    WHERE ai.mailitem_id > ISNULL(@MailBaselineId, 0)
      AND ai.[subject] = @ExpectedSubject
    ORDER BY ai.mailitem_id DESC;

    IF @MailItemId IS NOT NULL AND @MailSentStatus = N'sent'
        BREAK;

    IF @MailItemId IS NOT NULL AND @MailSentStatus = N'failed'
        BREAK;

    SET @PollCounter += 1;
    WAITFOR DELAY @PollDelay;
END;

IF @MailItemId IS NULL
BEGIN
    IF @CleanupTestJob = 1
    BEGIN
        EXEC msdb.dbo.sp_delete_job
            @job_name = @TestJobName,
            @delete_unused_schedule = 1;

        PRINT N'Test job deleted: ' + @TestJobName;
    END
    ELSE
    BEGIN
        PRINT N'Test job preserved for troubleshooting: ' + @TestJobName;
    END;

    RAISERROR(N'Validation failed: no Database Mail item was created for the alert email.', 16, 1);
    RETURN;
END;

IF @MailSentStatus <> N'sent'
BEGIN
    IF @CleanupTestJob = 1
    BEGIN
        EXEC msdb.dbo.sp_delete_job
            @job_name = @TestJobName,
            @delete_unused_schedule = 1;

        PRINT N'Test job deleted: ' + @TestJobName;
    END
    ELSE
    BEGIN
        PRINT N'Test job preserved for troubleshooting: ' + @TestJobName;
    END;

    RAISERROR(N'Validation failed: Database Mail item was created but not sent successfully.', 16, 1);
    RETURN;
END;

PRINT N'Alert email sent successfully. MailItemId=' + CAST(@MailItemId AS NVARCHAR(20));

IF @CleanupTestJob = 1
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = @TestJobName,
        @delete_unused_schedule = 1;

    PRINT N'Test job deleted: ' + @TestJobName;
END
ELSE
BEGIN
    PRINT N'Test job preserved for troubleshooting: ' + @TestJobName;
END;

PRINT N'Validation step completed.';
GO
