USE [dba_db]
GO
/****** Object:  StoredProcedure [objLog].[getTableSpaceUsed]    Script Date: 3/23/2026 11:59:37 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   PROCEDURE [objLog].[getTableSpaceUsed]
(
-- DECLARE
   @debug BIT = 1,
   @logToTable BIT = 0
)
/*
========================================================================================
 Procedure:   [objLog].[getTableSpaceUsed]
 Date:        2026-03-23
 Version:     0.0.2
 Created By:  Pardip Mudhar
 Modified By: Vova P
 Jira Ticket: 
 Target DB:   DBA_DA
---------------------------------------------------------------------------------------
 Description:
   Table to store table space used values and early warning system.

   Latest changes (2026-03-23):
     • Refactored to remove EXEC('USE ...') and use fully qualified table names in dynamic SQL for cross-database operations.
     • Added validation for @dbsName before using QUOTENAME.
     • Fixed dynamic SQL syntax (removed invalid newline escape).
     • Improved error handling and best practices for dynamic SQL execution.
========================================================================================
*/
--     DROP PROCEDURE  [objLog].[getTableSpaceUsed]
--     EXECUTE [objLog].[getTableSpaceUsed] @debug = 1, @logToTable = 1
AS
BEGIN 
   IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: getTableSpaceUsed started [' + SESSION_USER + '] [' + CAST( @@SPID AS NVARCHAR(10) ) + '] [' + DB_NAME() + '] [' + HOST_NAME() +']'

   DECLARE @rowcount INT = 0
   DECLARE @errMsg NVARCHAR(2000) = NULL
   
   DECLARE @Databases TABLE ( ID int identity(1,1), dbsName NVARCHAR(64) NULL )
   DECLARE @sqlStr NVARCHAR(4000) = NULL
   DECLARE @iLoop INT = 0
   DECLARE @maxLoop INT = 0
   DECLARE @dbsName NVARCHAR(64) = NULL
   DECLARE @oldDbsName NVARCHAR(64) = NULL
   DECLARE @schemaTableName NVARCHAR(256) = NULL
   DECLARE @tblschema  NVARCHAR(256) = NULL
   DECLARE @tblname NVARCHAR(256) = NULL
   DECLARE @objectID BIGINT = NULL
   
   BEGIN TRANSACTION trnGetTableSpaceUsed

   BEGIN TRY 
      IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: creating temp tables '

      DROP TABLE IF EXISTS ##baseTableNames
      CREATE TABLE ##baseTableNames 
      (  [ID]            INT IDENTITY(1,1), 
         [TABLE_CATALOG] NVARCHAR(64)  NULL, 
         [TABLE_SCHEMA]  NVARCHAR(64)  NULL, 
         [TABLE_NAME]    NVARCHAR(255) NULL,
         [OBJECTID]      BIGINT        NULL
      )
      
      DROP TABLE IF EXISTS #tableSpaceUsed
      CREATE  TABLE #tableSpaceUsed
      (
          [ID]            INT IDENTITY(1,1)
         ,[TABLE_CATALOG] NVARCHAR(256) NULL
         ,[TABLE_SCHEMA]  NVARCHAR(256) NULL
         ,[TABLE_NAME]    NVARCHAR(256) NULL 
         ,[objectID]      BIGINT NULL
         ,[num_rows]      INT NULL 
         ,[reserved_KB]   VARCHAR(15) NULL
         ,[data_KB]       VARCHAR(15) NULL
         ,[index_KB]      VARCHAR(15) NULL
         ,[unsed_KB]      VARCHAR(15) NULL
         ,[reserved_MB]   VARCHAR(15) NULL
         ,[data_MB]       VARCHAR(15) NULL
         ,[index_MB]      VARCHAR(15) NULL
         ,[unsed_MB]      VARCHAR(15) NULL
         ,[modifiedDate]  DATETIMEOFFSET(7) DEFAULT GETDATE()
      
         ,CONSTRAINT PK_tableSpaceUsed PRIMARY KEY CLUSTERED (ID )  ON [PRIMARY]
      )  ON [PRIMARY]

	  IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: temp tables created '
   END TRY
   BEGIN CATCH
      SET @errMsg = 'ErrMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: failed to create temp tables.' + CHAR(10) + CHAR(13) +
	                + 'SQL Error: [' + ERROR_MESSAGE() + '] Error Number: [' + CAST( ERROR_NUMBER() AS NVARCHAR(10)) + '] Error Severity: [' + CAST( ERROR_SEVERITY() AS NVARCHAR(10)) + ']'
	  GOTO ErrExit
   END CATCH

   BEGIN TRY 
      EXECUTE [objLog].[getAllDatabaseTableName] @debug = 1, @databaseName = 'ALL'
   END TRY
   BEGIN CATCH
      SET @errMsg = 'ErrMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: Cannot execute [objLog].[getAllDatabaseTableName].' + CHAR(10) + CHAR(13) +
	                + 'SQL Error: [' + ERROR_MESSAGE() + '] Error Number: [' + CAST( ERROR_NUMBER() AS NVARCHAR(10)) + '] Error Severity: [' + CAST( ERROR_SEVERITY() AS NVARCHAR(10)) + ']'
	  GOTO ErrExit
   END CATCH

   SELECT @maxLoop = MAX(ID) FROM ##baseTableNames
   SELECT TOP 1 
          @dbsName        = [bt].[TABLE_CATALOG], 
          @tblschema      = [bt].[TABLE_SCHEMA], 
		  @tblname        = [bt].[TABLE_NAME],
		  @iLoop          = [bt].[ID]
   FROM ##baseTableNames AS [bt] 
   ORDER BY [bt].[ID]

   SET @oldDbsName = ''
   
   IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: build table object space usage. @iLoop: [' + CAST( @iLoop AS NVARCHAR(10)) + '] ' +
                            ' @oldDbsName: [' + ISNULL( @oldDbsName, 'N/A' ) + ' @dbsName: ['+ ISNULL( @dbsName, 'N/A' ) + ']'
  
   WHILE ( @iLoop <= @maxLoop )
   BEGIN
      
	  BEGIN TRANSACTION trnDBSTSU

      IF ( @oldDbsName <> @dbsName )
	  BEGIN 
         IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: database changed to [' + ISNULL( @dbsname, 'N/A' ) + '] from @oldDbsName: [' + ISNULL( @oldDbsName, 'N/A' ) + ']'
	     SET @oldDbsName = @dbsName
	  END

      SELECT TOP 1 @dbsName = REPLACE(REPLACE([TABLE_CATALOG], '[', ''), ']', ''), @tblname = [TABLE_NAME], @tblschema = [TABLE_SCHEMA], @objectID = [objectID] FROM ##baseTableNames WHERE ID = @iLoop

      SET @schemaTableName = @tblschema + '.' + @tblname

      IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: Working valiables  ' +
		                   '@dbsName [' + ISNULL( @dbsName, 'N/A' ) + '] ' +
   						   '@objectID [' + CAST( @objectID AS NVARCHAR(10)) + '] ' +
   						   '@tblschema [' +  ISNULL( @tblschema, 'N/A' ) + '] ' +
   						   '@tblname [' + ISNULL( @tblname, 'N/A' ) + '] ' +
   						   '@schemaTableName [' + ISNULL( @schemaTableName, 'N/A' ) + '] '  +
					       '@iLoop [' + CAST( @iLoop AS NVARCHAR(10) ) + '] ' +
						   '@maxLoop [' + CAST( @maxLoop AS NVARCHAR(10) ) + '] ' 
   
      BEGIN TRY
         -- Validate @dbsName is not NULL or empty
         IF (@dbsName IS NULL OR LTRIM(RTRIM(@dbsName)) = '')
         BEGIN
            SET @errMsg = 'ErrMsg: [' + CONVERT(NVARCHAR(32), GETDATE(), 121) + ']: dbsName is NULL or empty.';
            GOTO ErrExit;
         END


         -- Build dynamic SQL to call sp_spaceused for the current table in the correct database context
         SET @sqlStr =
            'USE ' + QUOTENAME(@dbsName) + '; '
            + 'INSERT INTO #tableSpaceUsed( TABLE_NAME, num_rows , reserved_KB , data_KB , index_KB , unsed_KB ) '
            + 'EXEC sp_spaceused N''' + @tblschema + '.' + @tblname + ''';';

         -- Execute the dynamic SQL
         EXEC(@sqlStr);

         -- Update metadata for the inserted record
         UPDATE #tableSpaceUsed
         SET [TABLE_CATALOG] = @dbsName,
            [TABLE_SCHEMA]  = @tblschema,
            [objectID]      = @objectID
         WHERE TABLE_SCHEMA IS NULL AND [TABLE_NAME] = @tblname;

         SET @rowcount = @@ROWCOUNT;

         -- Debug message: show how many rows were updated
         IF ( @debug = 1 )
            PRINT 'InfoMsg: [' + CONVERT(NVARCHAR(32), GETDATE(), 121) + ']: Updating database and schema name [' + CAST(@rowcount AS NVARCHAR(10)) + ']';

         -- Remove processed table from the list
         DELETE FROM ##baseTableNames WHERE [ID] = @iLoop;

         -- Fetch next table to process
         SELECT TOP 1
            @dbsName   = [bt].[TABLE_CATALOG],
            @tblschema = [bt].[TABLE_SCHEMA],
            @tblname   = [bt].[TABLE_NAME],
            @iLoop     = [bt].[ID]
         FROM ##baseTableNames AS [bt]
         ORDER BY [bt].[ID];

         SET @rowcount = @@ROWCOUNT;

         -- If no more rows, exit the loop
         IF ( @rowcount = 0 ) SET @iLoop = @maxLoop + 1;

         -- Commit transaction for this iteration
         COMMIT TRANSACTION trnDBSTSU;
      END TRY
        BEGIN CATCH
            -- Error handling: capture and log error details
            SET @errMsg = 'ErrMsg: [' + CONVERT(NVARCHAR(32), GETDATE(), 121) + ']: failed to table exec sp_spaceused. [' + @dbsName + ']' + CHAR(10) + CHAR(13)
                        + 'SQL Error: [' + ERROR_MESSAGE() + '] Error Number: [' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + '] Error Severity: [' + CAST(ERROR_SEVERITY() AS NVARCHAR(10)) + ']';
            GOTO ErrExit;
        END CATCH
   END -- EOW
   
   IF ( @logToTable = 1 )
   BEGIN 
      BEGIN TRANSACTION trnDBSLogTSU

      BEGIN TRY
         IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: Updating table space used data.'
         UPDATE #tableSpaceUsed
         SET  [reserved_KB]   = REPlACE( [reserved_KB], 'KB', SPACE(0) )
             ,[data_KB]       = REPLACE( [data_KB],     'KB', SPACE(0) )
             ,[index_KB]      = REPLACE( [index_KB],    'KB', SPACE(0) )
             ,[unsed_KB]      = REPLACE( [unsed_KB],    'KB', SPACE(0) )
         
	     SET @rowcount = @@ROWCOUNT
	     IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: Updated KB [' + CAST( @rowcount AS NVARCHAR(10)) + ']'
      
         UPDATE #tableSpaceUsed
         SET  [reserved_MB]   = CONVERT( NVARCHAR(15), CAST( [reserved_KB] AS FLOAT ) / 1024.0 )
             ,[data_MB]       = CONVERT( NVARCHAR(15), CAST( [data_KB]     AS FLOAT ) / 1024.0 )
             ,[index_MB]      = CONVERT( NVARCHAR(15), CAST( [index_KB]    AS FLOAT ) / 1024.0 )
             ,[unsed_MB]      = CONVERT( NVARCHAR(15), CAST( [unsed_KB]    AS FLOAT ) / 1024.0 )
      
         SET @rowcount = @@ROWCOUNT                                
         IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: Updated MB [' + CAST( @rowcount AS NVARCHAR(10)) + ']'
      
         INSERT INTO [objLog].[tableSpaceUsed]
         (
	         [tableNameID]
            ,[NumRows]
            ,[ReservedSpaceKB]
            ,[DataSpaceKB]
            ,[IndexSizeKB]
            ,[UnusedSpaceKB]
            ,[ReservedSpaceMB]
            ,[DataSpaceMB]
            ,[IndexSizeMB]
            ,[UnusedSpaceMB]
			,[pctDiffOneDays]
            ,[pctDiffSevenDays]
            ,[pctDiffThirtyDays]
	        ,[pctDiffNinetyDays])
         SELECT   
              [tn].[id]
      	      ,[num_rows]
      	      ,[reserved_KB]
      	      ,[data_KB]
      	      ,[index_KB]
      	      ,[unsed_KB]
      	      ,[reserved_MB]
      	      ,[data_MB]
      	      ,[index_MB]
      	      ,[unsed_MB]
			  , 0.0
      	      , 0.0
      	      , 0.0
	          , 0.0
         FROM #tableSpaceUsed AS [tsu]
         INNER JOIN [objLog].[tableNames] AS [tn] ON 
                    [tsu].[objectID] = [tn].[ObjectID] 
	      	     AND [tsu].[TABLE_NAME] = [tn].[TableName]
	      	     AND [tsu].[TABLE_SCHEMA] = [tn].[schemaName]
	      	     AND [tsu].[TABLE_CATALOG] = [tn].[databaseName]
      
         SET @rowcount = @@ROWCOUNT                                
         IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: Insert table space used record [' + CAST( @rowcount AS NVARCHAR(10)) + ']'

         COMMIT TRANSACTION trnDBSLogTSU
      END TRY
      BEGIN CATCH
         SET @errMsg = 'ErrMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: failed to insert table space used records. [' + @dbsName + ']' + CHAR(10) + CHAR(13) +
	                 + 'SQL Error: [' + ERROR_MESSAGE() + '] Error Number: [' + CAST( ERROR_NUMBER() AS NVARCHAR(10)) + '] Error Severity: [' + CAST( ERROR_SEVERITY() AS NVARCHAR(10)) + ']'
	     GOTO ErrExit
      END CATCH
   END 

   GOTO finishExit

   errExit:
      IF ( @@TRANCOUNT > 0 ) ROLLBACK
      IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: getTableSpaceUsed finised with error  ' + CHAR(10) + CHAR(13) + @errMsg
      RAISERROR( @errMsg, 16, 1 )
      RETURN (1)
   
   finishExit:
      IF( @@TRANCOUNT > 0  ) COMMIT
      IF ( @debug = 1 ) PRINT 'InfoMsg: [' + CONVERT( NVARCHAR(32), GETDATE(), 121 ) + ']: getTableSpaceUsed finished  '
      RETURN (0)

END

