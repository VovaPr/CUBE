-- Central Server Setup - Step 3
-- Create alert sending procedure on DBMGMT.cubecloud.local\SQL01,10010

USE dba_db;
GO
IF OBJECT_ID('Monitoring.SP_SendAlerts', 'P') IS NOT NULL
    DROP PROCEDURE Monitoring.SP_SendAlerts;
GO

CREATE PROCEDURE Monitoring.SP_SendAlerts
    @OperatorName NVARCHAR(128) = N'Monitoring',
    @EmailRecipient NVARCHAR(256) = NULL,
    @MailProfile NVARCHAR(256) = 'SQLAlerts'
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @FailedJobCount INT;
    DECLARE @AlertBody NVARCHAR(MAX);
    DECLARE @AlertSubject NVARCHAR(256);
    DECLARE @ResolvedEmailRecipient NVARCHAR(256);
    DECLARE @AlertID INT;
    DECLARE @ServerName NVARCHAR(256);
    DECLARE @JobName NVARCHAR(256);
    DECLARE @FailureCount INT;
    DECLARE @FirstFailureTime DATETIME2;
    DECLARE @LastFailureTime DATETIME2;
    
    BEGIN TRY
        SET @ResolvedEmailRecipient = @EmailRecipient;

        IF @ResolvedEmailRecipient IS NULL
        BEGIN
            SELECT @ResolvedEmailRecipient = email_address
            FROM msdb.dbo.sysoperators
            WHERE name = @OperatorName
              AND enabled = 1;
        END;

        IF @ResolvedEmailRecipient IS NULL
        BEGIN
            RAISERROR(N'Unable to resolve email recipient from SQL Agent operator.', 16, 1);
            RETURN;
        END;

        -- Get count of active failed job alerts that haven't been notified in the last 50 minutes
        -- (job runs hourly; 50-min window prevents duplicate emails on manual reruns)
        SELECT @FailedJobCount = COUNT(*)
        FROM Monitoring.FailedJobsAlerts
        WHERE IsResolved = 0
            AND (AlertSentTime IS NULL OR AlertSentTime < DATEADD(MINUTE, -50, GETDATE()));
        
        IF @FailedJobCount > 0
        BEGIN
            DECLARE curFailedAlerts CURSOR LOCAL FAST_FORWARD FOR
                SELECT AlertID, ServerName, JobName, FailureCount, FirstFailureTime, LastFailureTime
                FROM Monitoring.FailedJobsAlerts
                WHERE IsResolved = 0
                  AND (AlertSentTime IS NULL OR AlertSentTime < DATEADD(MINUTE, -50, GETDATE()))
                ORDER BY LastFailureTime DESC;

            OPEN curFailedAlerts;
            FETCH NEXT FROM curFailedAlerts INTO @AlertID, @ServerName, @JobName, @FailureCount, @FirstFailureTime, @LastFailureTime;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @AlertSubject = N'Failed Job ' + ISNULL(@ServerName, N'(unknown server)') + N': ' + ISNULL(@JobName, N'(unknown job)');

                SET @AlertBody =
                    N'The following SQL Server Agent job is currently failing:' + CHAR(10) + CHAR(10) +
                    N'Server: ' + ISNULL(@ServerName, N'') + CHAR(10) + CHAR(10) +
                    N'Job: ' + ISNULL(@JobName, N'') + CHAR(10) + CHAR(10) +
                    N'First Failure: ' + ISNULL(CONVERT(NVARCHAR(19), @FirstFailureTime, 120), N'') + CHAR(10) + CHAR(10) +
                    N'Last Failure: ' + ISNULL(CONVERT(NVARCHAR(19), @LastFailureTime, 120), N'') + CHAR(10) + CHAR(10) +
                    N'Failure Count (last hour): ' + CAST(ISNULL(@FailureCount, 0) AS NVARCHAR(10));

                EXEC msdb.dbo.sp_send_dbmail
                    @profile_name = @MailProfile,
                    @recipients = @ResolvedEmailRecipient,
                    @subject = @AlertSubject,
                    @body = @AlertBody,
                    @body_format = 'TEXT';

                UPDATE Monitoring.FailedJobsAlerts
                SET AlertSentTime = GETDATE()
                WHERE AlertID = @AlertID;

                FETCH NEXT FROM curFailedAlerts INTO @AlertID, @ServerName, @JobName, @FailureCount, @FirstFailureTime, @LastFailureTime;
            END;

            CLOSE curFailedAlerts;
            DEALLOCATE curFailedAlerts;

            PRINT 'Email alerts sent successfully to: ' + @ResolvedEmailRecipient;
        END
        ELSE
        BEGIN
            PRINT 'No failed jobs to alert on.';
        END
        
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(MAX) = ERROR_MESSAGE();
        DECLARE @ErrorNumber INT = ERROR_NUMBER();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();
        
        PRINT 'ERROR in Monitoring.SP_SendAlerts:';
        PRINT 'Error Number: ' + CAST(@ErrorNumber AS NVARCHAR(10));
        PRINT 'Error Message: ' + @ErrorMessage;
        
        RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END
GO

PRINT 'Stored procedure Monitoring.SP_SendAlerts created successfully.';
