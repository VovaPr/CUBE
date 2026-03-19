-- Central Server Setup - Step 2
-- Create monitoring stored procedures on DBMGMT.cubecloud.local\SQL01,10010

USE dba_db;
GO

IF OBJECT_ID('Monitoring.SP_CollectJobs', 'P') IS NOT NULL
    DROP PROCEDURE Monitoring.SP_CollectJobs;
GO

IF OBJECT_ID('Monitoring.SP_RefreshFailedJobsAlerts', 'P') IS NOT NULL
    DROP PROCEDURE Monitoring.SP_RefreshFailedJobsAlerts;
GO

IF OBJECT_ID('Monitoring.SP_PullTargetFailedJobsAlerts', 'P') IS NOT NULL
    DROP PROCEDURE Monitoring.SP_PullTargetFailedJobsAlerts;
GO

CREATE PROCEDURE Monitoring.SP_CollectJobs
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ServerName NVARCHAR(256) = N'DBMGMT\SQL01,10010';

    MERGE INTO Monitoring.Jobs j
    USING (
        SELECT
            @ServerName AS ServerName,
            sj.name AS JobName,
            sj.job_id AS SQLJobID,
            sjh.run_status AS LastRunStatus,
            sjh.LastRunDate AS LastRunDate,
            sjh.run_duration AS LastRunDuration,
            nr.NextRunDate AS NextRunDate,
            sj.enabled AS IsEnabled
        FROM msdb.dbo.sysjobs sj
        LEFT JOIN (
            SELECT
                job_id,
                run_status,
                run_duration,
                msdb.dbo.agent_datetime(run_date, run_time) AS LastRunDate,
                ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY instance_id DESC) AS rn
            FROM msdb.dbo.sysjobhistory
            WHERE step_id = 0
        ) sjh ON sj.job_id = sjh.job_id AND sjh.rn = 1
        OUTER APPLY (
            SELECT TOP (1)
                CASE
                    WHEN sjs.next_run_date > 0
                        THEN msdb.dbo.agent_datetime(sjs.next_run_date, sjs.next_run_time)
                    ELSE NULL
                END AS NextRunDate
            FROM msdb.dbo.sysjobschedules sjs
            WHERE sjs.job_id = sj.job_id
            ORDER BY sjs.next_run_date, sjs.next_run_time
        ) nr
    ) src
        ON j.ServerName = src.ServerName AND j.JobName = src.JobName
    WHEN MATCHED THEN
        UPDATE SET
            LastRunStatus = src.LastRunStatus,
            LastRunDate = src.LastRunDate,
            LastRunDuration = src.LastRunDuration,
            NextRunDate = src.NextRunDate,
            IsEnabled = src.IsEnabled,
            RecordedDate = GETDATE()
    WHEN NOT MATCHED THEN
        INSERT (ServerName, JobName, SQLJobID, LastRunStatus, LastRunDate, LastRunDuration, NextRunDate, IsEnabled, RecordedDate)
        VALUES (src.ServerName, src.JobName, src.SQLJobID, src.LastRunStatus, src.LastRunDate, src.LastRunDuration, src.NextRunDate, src.IsEnabled, GETDATE());

    PRINT 'Job status collection completed successfully on ' + @ServerName;
END
GO

CREATE PROCEDURE Monitoring.SP_RefreshFailedJobsAlerts
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ServerName NVARCHAR(256) = N'DBMGMT\SQL01,10010';

    WITH FailedJobs AS (
        SELECT
            ServerName,
            JobName,
            COUNT(*) AS FailureCount,
            MAX(RecordedDate) AS LastFailureTime
        FROM Monitoring.Jobs
        WHERE ServerName = @ServerName
          AND LastRunStatus = 0
          AND LastRunDate >= DATEADD(HOUR, -1, GETDATE())
        GROUP BY ServerName, JobName
    )
    MERGE INTO Monitoring.FailedJobsAlerts fa
    USING FailedJobs fj
        ON fa.ServerName = fj.ServerName
       AND fa.JobName = fj.JobName
       AND fa.IsResolved = 0
    WHEN MATCHED THEN
        UPDATE SET
            FailureCount = fa.FailureCount + fj.FailureCount,
            LastFailureTime = fj.LastFailureTime
    WHEN NOT MATCHED THEN
        INSERT (ServerName, JobName, FailureCount, FirstFailureTime, LastFailureTime)
        VALUES (fj.ServerName, fj.JobName, fj.FailureCount, fj.LastFailureTime, fj.LastFailureTime);

    UPDATE Monitoring.FailedJobsAlerts
    SET IsResolved = 1,
        ResolutionTime = GETDATE()
    WHERE IsResolved = 0
      AND ServerName = @ServerName
      AND NOT EXISTS (
            SELECT 1
            FROM Monitoring.Jobs js
            WHERE js.ServerName = Monitoring.FailedJobsAlerts.ServerName
              AND js.JobName = Monitoring.FailedJobsAlerts.JobName
              AND js.LastRunStatus = 0
              AND js.LastRunDate >= DATEADD(HOUR, -1, GETDATE())
      );

    PRINT 'Failed job analysis completed successfully.';
END
GO

CREATE PROCEDURE Monitoring.SP_PullTargetFailedJobsAlerts
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CentralEndpoint NVARCHAR(256) = N'DBMGMT\SQL01,10010';
    DECLARE @RunID UNIQUEIDENTIFIER = NEWID();
    DECLARE @TargetServer NVARCHAR(256);
    DECLARE @RunOnTargetQuery NVARCHAR(MAX);
    DECLARE @SqlcmdCommand NVARCHAR(4000);
    DECLARE @xpCmd VARCHAR(8000);
    DECLARE @xpWasEnabled BIT = 0;
    DECLARE @HadError BIT;

    DECLARE @Output TABLE (
        OutputOrder INT IDENTITY(1,1) PRIMARY KEY,
        OutputLine NVARCHAR(4000)
    );

    INSERT INTO Monitoring.TargetPullLog (RunID, TargetServer, Stage, IsSuccess, Message)
    VALUES (@RunID, NULL, N'RUN_START', 1, N'Starting target pull run.');

    SELECT @xpWasEnabled = CAST(value_in_use AS BIT)
    FROM sys.configurations
    WHERE name = N'xp_cmdshell';

    IF @xpWasEnabled = 0
    BEGIN
        EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
        EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE;
    END;

    DECLARE target_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT s.ServerName
        FROM Monitoring.Servers s
        WHERE s.Target = 1
          AND s.IsActive = 1
          AND s.ServerName <> @CentralEndpoint;

    OPEN target_cursor;
    FETCH NEXT FROM target_cursor INTO @TargetServer;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
                        SET @RunOnTargetQuery =
                                N'SET NOCOUNT ON; '
                            + N'PRINT N''__JSON_BEGIN__''; '
                            + N'SELECT '
                            + N'    ServerName, '
                            + N'    JobName, '
                            + N'    FailureCount, '
                            + N'    CONVERT(NVARCHAR(33), FirstFailureTime, 126) AS FirstFailureTime, '
                            + N'    CONVERT(NVARCHAR(33), LastFailureTime, 126) AS LastFailureTime, '
                            + N'    CONVERT(NVARCHAR(33), AlertSentTime, 126) AS AlertSentTime, '
                            + N'    IsResolved, '
                            + N'    CONVERT(NVARCHAR(33), ResolutionTime, 126) AS ResolutionTime '
                            + N'FROM dba_db.Monitoring.FailedJobsAlerts '
                            + N'FOR JSON PATH, INCLUDE_NULL_VALUES; '
                            + N'PRINT N''__JSON_END__'';';

                        SET @SqlcmdCommand =
                                N'sqlcmd -S "' + REPLACE(@TargetServer, N'"', N'""')
                            + N'" -d DBA_DB -E -N -C -b -w 65535 -y 0 -Q "' + REPLACE(@RunOnTargetQuery, N'"', N'\"') + N'"';

            INSERT INTO Monitoring.TargetPullLog (RunID, TargetServer, Stage, IsSuccess, Message, CommandText)
            VALUES (@RunID, @TargetServer, N'COMMAND', 1, N'Reading target FailedJobsAlerts snapshot.', @SqlcmdCommand);

            DELETE FROM @Output;

            SET @xpCmd = CAST(@SqlcmdCommand AS VARCHAR(8000));
            INSERT INTO @Output (OutputLine)
            EXEC master..xp_cmdshell @xpCmd;

            DECLARE @JsonStartLine INT;
            DECLARE @JsonEndLine INT;
            DECLARE @TargetJson NVARCHAR(MAX) = N'';

            SELECT @JsonStartLine = MIN(OutputOrder)
            FROM @Output
            WHERE LTRIM(RTRIM(OutputLine)) = N'__JSON_BEGIN__';

            SELECT @JsonEndLine = MAX(OutputOrder)
            FROM @Output
            WHERE LTRIM(RTRIM(OutputLine)) = N'__JSON_END__';

            IF @JsonStartLine IS NOT NULL
               AND @JsonEndLine IS NOT NULL
               AND @JsonEndLine > @JsonStartLine
            BEGIN
                SELECT @TargetJson = COALESCE(@TargetJson, N'') + LTRIM(RTRIM(OutputLine))
                FROM @Output
                                WHERE OutputOrder > @JsonStartLine
                                    AND OutputOrder < @JsonEndLine
                  AND OutputLine IS NOT NULL
                  AND LTRIM(RTRIM(OutputLine)) <> N''
                                ORDER BY OutputOrder;

                IF ISJSON(@TargetJson) = 1
                BEGIN
                    MERGE Monitoring.FailedJobsAlerts AS dst
                    USING (
                        SELECT
                            ServerName,
                            JobName,
                            FailureCount,
                            TRY_CONVERT(DATETIME2, FirstFailureTime, 126) AS FirstFailureTime,
                            TRY_CONVERT(DATETIME2, LastFailureTime, 126) AS LastFailureTime,
                            TRY_CONVERT(DATETIME2, AlertSentTime, 126) AS AlertSentTime,
                            IsResolved,
                            TRY_CONVERT(DATETIME2, ResolutionTime, 126) AS ResolutionTime
                        FROM OPENJSON(@TargetJson)
                        WITH (
                            ServerName NVARCHAR(256) '$.ServerName',
                            JobName NVARCHAR(256) '$.JobName',
                            FailureCount INT '$.FailureCount',
                            FirstFailureTime NVARCHAR(33) '$.FirstFailureTime',
                            LastFailureTime NVARCHAR(33) '$.LastFailureTime',
                            AlertSentTime NVARCHAR(33) '$.AlertSentTime',
                            IsResolved BIT '$.IsResolved',
                            ResolutionTime NVARCHAR(33) '$.ResolutionTime'
                        )
                    ) AS src
                        ON dst.ServerName = src.ServerName
                       AND dst.JobName = src.JobName
                    WHEN MATCHED THEN
                        UPDATE SET
                            dst.FailureCount = src.FailureCount,
                            dst.FirstFailureTime = src.FirstFailureTime,
                            dst.LastFailureTime = src.LastFailureTime,
                            dst.AlertSentTime = src.AlertSentTime,
                            dst.IsResolved = src.IsResolved,
                            dst.ResolutionTime = src.ResolutionTime
                    WHEN NOT MATCHED THEN
                        INSERT (ServerName, JobName, FailureCount, FirstFailureTime, LastFailureTime, AlertSentTime, IsResolved, ResolutionTime)
                        VALUES (src.ServerName, src.JobName, src.FailureCount, src.FirstFailureTime, src.LastFailureTime, src.AlertSentTime, src.IsResolved, src.ResolutionTime);
                END
                ELSE
                BEGIN
                    INSERT INTO Monitoring.TargetPullLog (RunID, TargetServer, Stage, IsSuccess, Message)
                    VALUES (@RunID, @TargetServer, N'JSON_PARSE', 0, N'Unable to parse JSON payload from target output.');
                END;
            END
            ELSE
            BEGIN
                INSERT INTO Monitoring.TargetPullLog (RunID, TargetServer, Stage, IsSuccess, Message)
                VALUES (@RunID, @TargetServer, N'JSON_PARSE', 0, N'JSON payload markers not found in target output.');
            END;

            SET @HadError = CASE
                WHEN EXISTS (SELECT 1 FROM @Output WHERE OutputLine LIKE N'Sqlcmd: Error:%') THEN 1
                ELSE 0
            END;

            INSERT INTO Monitoring.TargetPullLog (RunID, TargetServer, Stage, IsSuccess, Message)
            SELECT
                @RunID,
                @TargetServer,
                N'TARGET_OUTPUT',
                CASE WHEN @HadError = 1 THEN 0 ELSE 1 END,
                OutputLine
            FROM @Output
            WHERE OutputLine IS NOT NULL;

            INSERT INTO Monitoring.TargetPullLog (RunID, TargetServer, Stage, IsSuccess, Message)
            VALUES (
                @RunID,
                @TargetServer,
                N'TARGET_SUMMARY',
                CASE WHEN @HadError = 1 THEN 0 ELSE 1 END,
                CASE WHEN @HadError = 1 THEN N'Target pull failed.' ELSE N'Target pull completed successfully.' END
            );
        END TRY
        BEGIN CATCH
            INSERT INTO Monitoring.TargetPullLog (RunID, TargetServer, Stage, IsSuccess, Message)
            VALUES (@RunID, @TargetServer, N'TARGET_EXCEPTION', 0, ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM target_cursor INTO @TargetServer;
    END;

    CLOSE target_cursor;
    DEALLOCATE target_cursor;

    IF @xpWasEnabled = 0
    BEGIN
        EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE;
        EXEC sp_configure 'show advanced options', 0; RECONFIGURE;
    END;

    INSERT INTO Monitoring.TargetPullLog (RunID, TargetServer, Stage, IsSuccess, Message)
    VALUES (@RunID, NULL, N'RUN_END', 1, N'Target pull run finished.');
END
GO

PRINT 'Stored procedures created on central server: Monitoring.SP_CollectJobs, Monitoring.SP_RefreshFailedJobsAlerts, Monitoring.SP_PullTargetFailedJobsAlerts.';
