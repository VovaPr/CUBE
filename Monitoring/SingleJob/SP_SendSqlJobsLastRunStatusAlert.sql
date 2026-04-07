USE [DBA_DB]
GO

CREATE OR ALTER PROCEDURE dbo.SP_SendSqlJobsLastRunStatusAlert
    @MailProfile NVARCHAR(256) = N'SQLAlerts',
    @Recipients  NVARCHAR(MAX) = N'sqlalerts@cube.global',
    @Subject     NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Subject IS NULL
        SET @Subject = CAST(@@SERVERNAME AS NVARCHAR(128)) + N' SQL Jobs Last Run Status Alert';

    DROP TABLE IF EXISTS #Result;

    CREATE TABLE #Result
    (
         Id             INT IDENTITY(1,1) PRIMARY KEY
        ,JobName        NVARCHAR(200)
        ,StepId         NVARCHAR(10)
        ,StepName       NVARCHAR(200)
        ,RunDateAndTime NVARCHAR(30)
        ,Duration       NVARCHAR(50)
        ,RunStatus      NVARCHAR(20)
        ,[Message]      NVARCHAR(MAX)
        ,[Status]       NVARCHAR(200)
    );

    -- Check if any enabled non-replication job's last run ended with Failed or Canceled.
    -- Only the job-level outcome record (step_id = 0) is evaluated per job.
    IF EXISTS (
        SELECT TOP (1) 1
        FROM msdb.dbo.sysjobs sj
        LEFT JOIN msdb.dbo.syscategories sc
            ON sj.category_id = sc.category_id
           AND sc.category_class = 1
        JOIN (
            SELECT
                 job_id
                ,step_id
                ,run_date
                ,run_time
                ,run_duration
                ,run_status
                ,[message]
                ,ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY instance_id DESC) AS rn
            FROM msdb.dbo.sysjobhistory
            WHERE step_id = 0
        ) AS lr ON sj.job_id = lr.job_id AND lr.rn = 1
        WHERE sj.enabled = 1
          AND lr.run_status IN (0, 3)
          AND ISNULL(sc.[name], N'') NOT LIKE N'REPL-%'
    )
    BEGIN
        INSERT INTO #Result
        (
             JobName
            ,StepId
            ,StepName
            ,RunDateAndTime
            ,Duration
            ,RunStatus
            ,[Message]
            ,[Status]
        )
        SELECT
             sj.[name] AS JobName
            ,CONVERT(NVARCHAR(10), lr.step_id) AS StepId
            ,N'Job Status' AS StepName
            ,CONVERT(NVARCHAR(30), msdb.dbo.agent_datetime(lr.run_date, lr.run_time), 120) AS RunDateAndTime
            ,STUFF(STUFF(RIGHT('000000' + CAST(lr.run_duration AS VARCHAR(6)), 6), 3, 0, ':'), 6, 0, ':') AS Duration
            ,CASE lr.run_status
                WHEN 0 THEN N'Failed'
                WHEN 3 THEN N'Canceled'
             END AS RunStatus
            ,CONVERT(NVARCHAR(MAX), lr.[message]) AS [Message]
            ,N'Please check the SQL agent job history table for failing job and step.' AS [Status]
        FROM msdb.dbo.sysjobs sj
        LEFT JOIN msdb.dbo.syscategories sc
            ON sj.category_id = sc.category_id
           AND sc.category_class = 1
        JOIN (
            SELECT
                 job_id
                ,step_id
                ,run_date
                ,run_time
                ,run_duration
                ,run_status
                ,[message]
                ,ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY instance_id DESC) AS rn
            FROM msdb.dbo.sysjobhistory
            WHERE step_id = 0
        ) AS lr ON sj.job_id = lr.job_id AND lr.rn = 1
        WHERE sj.enabled = 1
          AND lr.run_status IN (0, 3)
          AND ISNULL(sc.[name], N'') NOT LIKE N'REPL-%'
        ORDER BY sj.[name];
    END;

    -- ============================================================
    -- Section 2: Replication agents (REPL% category)
    -- Continuous agents (Log Reader, Distribution) run indefinitely;
    -- if currently running they are healthy and excluded from alerts.
    -- Alert is raised only when the agent has stopped and its last
    -- completed run ended with Failed (0) or Canceled (3).
    -- ============================================================
    INSERT INTO #Result
    (
         JobName
        ,StepId
        ,StepName
        ,RunDateAndTime
        ,Duration
        ,RunStatus
        ,[Message]
        ,[Status]
    )
    SELECT
         sj.[name] AS JobName
        ,CONVERT(NVARCHAR(10), lr.step_id) AS StepId
        ,N'Job Status' AS StepName
        ,CONVERT(NVARCHAR(30), msdb.dbo.agent_datetime(lr.run_date, lr.run_time), 120) AS RunDateAndTime
        ,STUFF(STUFF(RIGHT('000000' + CAST(lr.run_duration AS VARCHAR(6)), 6), 3, 0, ':'), 6, 0, ':') AS Duration
        ,CASE lr.run_status
            WHEN 0 THEN N'Failed'
            WHEN 3 THEN N'Canceled'
         END AS RunStatus
        ,CONVERT(NVARCHAR(MAX), lr.[message]) AS [Message]
        ,N'Replication agent stopped unexpectedly. Please check the job history for details.' AS [Status]
    FROM msdb.dbo.sysjobs sj
    JOIN msdb.dbo.syscategories sc
        ON sj.category_id = sc.category_id
       AND sc.category_class = 1
       AND sc.[name] LIKE N'REPL-%'
    JOIN (
        SELECT
             job_id
            ,step_id
            ,run_date
            ,run_time
            ,run_duration
            ,run_status
            ,[message]
            ,ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY instance_id DESC) AS rn
        FROM msdb.dbo.sysjobhistory
        WHERE step_id = 0
    ) AS lr ON sj.job_id = lr.job_id AND lr.rn = 1
    -- Exclude agents currently running (healthy for continuous replication agents)
    LEFT JOIN (
        SELECT DISTINCT ja.job_id
        FROM msdb.dbo.sysjobactivity ja
        WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
          AND ja.start_execution_date IS NOT NULL
          AND ja.stop_execution_date IS NULL
    ) AS running ON sj.job_id = running.job_id
    WHERE sj.enabled = 1
      AND running.job_id IS NULL       -- not currently running
      AND lr.run_status IN (0, 3)      -- last completed run was Failed or Canceled
    ORDER BY sj.[name];

    IF NOT EXISTS (SELECT 1 FROM #Result)
        RETURN;

    DECLARE @Xml  NVARCHAR(MAX);
    DECLARE @Body NVARCHAR(MAX);

    SET @Xml = CAST((
        SELECT
             [JobName]        AS 'td'
            ,''
            ,[StepId]         AS 'td'
            ,''
            ,[StepName]       AS 'td'
            ,''
            ,[RunDateAndTime] AS 'td'
            ,''
            ,[Duration]       AS 'td'
            ,''
            ,[RunStatus]      AS 'td'
            ,''
            ,[Message]        AS 'td'
            ,''
            ,[Status]         AS 'td'
        FROM #Result
        ORDER BY Id ASC
        FOR XML PATH('tr'), ELEMENTS
    ) AS NVARCHAR(MAX));

    SET @Body = N'<html><body><H4>' + @Subject + N'</H4>' +
                N'<table border = 1><tr>' +
                N'<th> JobName </th><th> StepId </th><th> StepName </th><th> RunDateAndTime </th>' +
                N'<th> Duration </th><th> RunStatus </th><th> Message </th><th> Status </th></tr>' +
                ISNULL(@Xml, N'') +
                N'</table></body></html>';

    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = @MailProfile,
        @recipients   = @Recipients,
        @subject      = @Subject,
        @body         = @Body,
        @body_format  = 'HTML';
END
GO
