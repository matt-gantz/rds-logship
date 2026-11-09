IF DB_ID(N'Utility') IS NULL
BEGIN
    EXEC(N'CREATE DATABASE Utility');
END
GO



USE Utility
GO

IF OBJECT_ID(N'dbo.log_ship_history', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.log_ship_history
    (
        history_id INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_log_ship_history PRIMARY KEY,
        db_name SYSNAME NOT NULL,
        log_backup_file_name NVARCHAR(260) NOT NULL,
        s3_bucket NVARCHAR(512) NOT NULL,
        error_message NVARCHAR(MAX) NULL,
        status NVARCHAR(20) NOT NULL,
        backup_created_timestamp DATETIME2(3) NULL,
        last_lsn NUMERIC(25, 0) NULL,
        time_restored DATETIME2(3) NULL
    );

    CREATE INDEX IX_log_ship_history_lookup
        ON dbo.log_ship_history (db_name, log_backup_file_name, status, history_id DESC);
END
GO

IF USER_ID(N'log_ship_restore_user') IS NULL
BEGIN
    CREATE USER [log_ship_restore_user] FOR LOGIN [log_ship_restore_user];
END
GO

CREATE OR ALTER PROCEDURE dbo.Wait_For_RDS_Task_Completion
    @TaskId INT,
    @TaskLifecycle NVARCHAR(50) OUTPUT,
    @TaskInfo NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TaskStatus TABLE
    (
        task_id INT,
        task_type NVARCHAR(100),
        database_name SYSNAME,
        percent_complete INT,
        duration_mins INT,
        lifecycle NVARCHAR(50),
        task_info NVARCHAR(MAX),
        last_updated DATETIME2(3),
        created_at DATETIME2(3),
        S3_object_arn NVARCHAR(2048),
        overwrite_S3_backup_file BIT,
        KMS_master_key_arn NVARCHAR(2048),
        filepath NVARCHAR(2048),
        overwrite_file BIT
    );

    DECLARE @CurrentLifecycle NVARCHAR(50) = NULL;
    DECLARE @CurrentTaskInfo NVARCHAR(MAX) = NULL;

    WHILE 1 = 1
    BEGIN
        DELETE FROM @TaskStatus;

        INSERT INTO @TaskStatus
        EXEC msdb.dbo.rds_task_status @task_id = @TaskId;

        SELECT TOP (1)
            @CurrentLifecycle = lifecycle,
            @CurrentTaskInfo = task_info
        FROM @TaskStatus;

        IF @CurrentLifecycle IN (N'SUCCESS', N'ERROR', N'FAILED', N'FAIL', N'CANCELED')
        BEGIN
            BREAK;
        END

        WAITFOR DELAY '00:00:10';
    END

    SET @TaskLifecycle = @CurrentLifecycle;
    SET @TaskInfo = @CurrentTaskInfo;
END
GO

CREATE OR ALTER PROCEDURE dbo.Insert_RDS_Logship
    @LogBackupToRestore NVARCHAR(260),
    @RestoreDbName SYSNAME,
    @S3BaseArn NVARCHAR(512)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BackupCreatedTimestamp DATETIME2(3) = NULL;
    DECLARE @TimestampText NVARCHAR(14);
    DECLARE @TimestampIso NVARCHAR(19);
    DECLARE @TimestampStart INT = LEN(@RestoreDbName) + 2;

    -- Log backup names use <database>_yyyyMMddHHmmss.trn. TRY_CONVERT keeps
    -- unexpected or invalid names from failing the insert.
    IF LEFT(@LogBackupToRestore, @TimestampStart - 1) = @RestoreDbName + N'_'
       AND SUBSTRING(@LogBackupToRestore, @TimestampStart + 14, 1) = N'.'
       AND RIGHT(@LogBackupToRestore, 4) = N'.trn'
    BEGIN
        SET @TimestampText = SUBSTRING(@LogBackupToRestore, @TimestampStart, 14);

        IF LEN(@TimestampText) = 14
           AND @TimestampText NOT LIKE N'%[^0-9]%'
        BEGIN
            SET @TimestampIso =
                SUBSTRING(@TimestampText, 1, 4) + N'-' +
                SUBSTRING(@TimestampText, 5, 2) + N'-' +
                SUBSTRING(@TimestampText, 7, 2) + N'T' +
                SUBSTRING(@TimestampText, 9, 2) + N':' +
                SUBSTRING(@TimestampText, 11, 2) + N':' +
                SUBSTRING(@TimestampText, 13, 2);

            SET @BackupCreatedTimestamp = TRY_CONVERT(DATETIME2(3), @TimestampIso, 126);
        END
    END

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.log_ship_history
        WHERE db_name = @RestoreDbName
          AND log_backup_file_name = @LogBackupToRestore
    )
    BEGIN
        INSERT dbo.log_ship_history
        (
            db_name,
            log_backup_file_name,
            s3_bucket,
            error_message,
            status,
            backup_created_timestamp,
            last_lsn,
            time_restored
        )
        VALUES
        (
            @RestoreDbName,
            @LogBackupToRestore,
            @S3BaseArn,
            NULL,
            N'PENDING',
            @BackupCreatedTimestamp,
            NULL,
            NULL
        );
    END
END
GO

CREATE OR ALTER PROCEDURE dbo.Restore_RDS_Logship
    @RestoreDbName SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LogBackupToRestore NVARCHAR(260);
    DECLARE @S3BaseArn NVARCHAR(512);
    DECLARE @HistoryId INT;
	DECLARE @S3Arn NVARCHAR(1024);

    SELECT TOP (1) 
        @HistoryId = history_id,
        @LogBackupToRestore = log_backup_file_name,
        @S3BaseArn = s3_bucket
    FROM dbo.log_ship_history
    WHERE db_name = @RestoreDbName
      AND status = N'PENDING'
    ORDER BY history_id ASC;

    WHILE @HistoryId IS NOT NULL
    BEGIN        
        SET @S3Arn = @S3BaseArn + N'/' + @LogBackupToRestore;

        UPDATE dbo.log_ship_history
        SET status = N'RESTORING'
        WHERE history_id = @HistoryId;

        BEGIN TRY
            DECLARE @RestoreTask TABLE
            (
                task_id INT,
                task_type NVARCHAR(100),
                database_name SYSNAME,
                percent_complete INT,
                duration_mins INT,
                lifecycle NVARCHAR(50),
                task_info NVARCHAR(MAX),
                last_updated DATETIME2(3),
                created_at DATETIME2(3),
                S3_object_arn NVARCHAR(2048),
                overwrite_S3_backup_file BIT,
                KMS_master_key_arn NVARCHAR(2048),
                filepath NVARCHAR(2048),
                overwrite_file BIT
            );
        
            DECLARE @TaskId INT;
            DECLARE @TaskLifecycle NVARCHAR(50);
            DECLARE @TaskInfo NVARCHAR(MAX);
            DECLARE @ErrorMessage NVARCHAR(MAX);
            
            EXEC msdb.dbo.rds_restore_log
                @restore_db_name = @RestoreDbName,
                @s3_arn_to_restore_from = @S3Arn,
                @with_norecovery = 1;
            
            INSERT INTO @RestoreTask
            EXEC msdb.dbo.rds_task_status @RestoreDbName;

            SELECT TOP (1)
                @TaskId = task_id,
                @TaskLifecycle = lifecycle,
                @TaskInfo = task_info
            FROM @RestoreTask
            ORDER BY task_id DESC;

            EXEC dbo.Wait_For_RDS_Task_Completion
                @TaskId = @TaskId,
                @TaskLifecycle = @TaskLifecycle OUTPUT,
                @TaskInfo = @TaskInfo OUTPUT;

			PRINT @TaskLifecycle
			PRINT @TaskInfo

			UPDATE dbo.log_ship_history
            SET status = @TaskLifecycle,
                error_message = @TaskInfo,
                time_restored = SYSUTCDATETIME()
            WHERE history_id = @HistoryId;

			SET @HistoryId = NULL;
            SELECT TOP (1) 
                @HistoryId = history_id,
                @LogBackupToRestore = log_backup_file_name,
                @S3BaseArn = s3_bucket
            FROM dbo.log_ship_history
            WHERE db_name = @RestoreDbName
            AND status = N'PENDING'
            ORDER BY history_id ASC;
        
        END TRY
        BEGIN CATCH
            SET @ErrorMessage = ERROR_MESSAGE();

            UPDATE dbo.log_ship_history
            SET status = N'FAIL',
                error_message = @ErrorMessage,
                time_restored = SYSUTCDATETIME()
            WHERE history_id = @HistoryId;

            SET @errormessage = 'RDS Log Shipping Restore encountered error, check logs and retry';
            THROW 50001,@errormessage , 1;
        END CATCH
	END
END
GO

CREATE OR ALTER PROCEDURE dbo.Monitor_RDS_Logship
    @DatabaseName SYSNAME = NULL,
    -- Use a SQL Server time zone name (for example, 'Pacific Standard Time' or 'Eastern Standard Time').
    -- NULL assumes the source and RDS use the same local time zone.
    @SourceTimeZone SYSNAME = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH StatusCounts AS
    (
        SELECT
            h.db_name,
            COUNT(CASE WHEN UPPER(h.status) = N'PENDING' THEN 1 END) AS pending_count,
            COUNT(CASE WHEN UPPER(h.status) = N'RESTORING' THEN 1 END) AS restoring_count,
            COUNT(CASE WHEN UPPER(h.status) = N'SUCCESS' THEN 1 END) AS success_count,
            COUNT(CASE WHEN UPPER(h.status) IN (N'FAIL', N'FAILED', N'ERROR') THEN 1 END) AS fail_count,
            COUNT(CASE WHEN UPPER(h.status) NOT IN (N'PENDING', N'RESTORING', N'SUCCESS', N'FAIL', N'FAILED', N'ERROR') THEN 1 END) AS other_count,
            COUNT(*) AS total_count
        FROM dbo.log_ship_history h
        WHERE (@DatabaseName IS NULL OR h.db_name = @DatabaseName)
        GROUP BY h.db_name
    )
    SELECT
        d.name AS database_name,
        COALESCE(sc.pending_count, 0) AS pending_count,
        COALESCE(sc.restoring_count, 0) AS restoring_count,
        COALESCE(sc.success_count, 0) AS success_count,
        COALESCE(sc.fail_count, 0) AS fail_count,
        COALESCE(sc.other_count, 0) AS other_count,
        COALESCE(sc.total_count, 0) AS total_count,
        last_ins.most_recently_inserted_file,
        last_res.most_recently_restored_file,
        last_res.last_restored_backup_created_timestamp,
        CASE
            WHEN @SourceTimeZone IS NULL THEN
                DATEDIFF(MINUTE, last_res.last_restored_backup_created_timestamp, SYSDATETIME())
            ELSE
                DATEDIFF
                (
                    MINUTE,
                    SWITCHOFFSET(last_res.last_restored_backup_created_timestamp AT TIME ZONE @SourceTimeZone, '+00:00'),
                    SYSUTCDATETIME()
                )
        END AS diff_minutes_last_restored_to_now
    FROM sys.databases d
    LEFT JOIN StatusCounts sc
        ON sc.db_name = d.name
    OUTER APPLY
    (
        SELECT TOP (1)
            h_ins.log_backup_file_name AS most_recently_inserted_file
        FROM dbo.log_ship_history h_ins
        WHERE h_ins.db_name = d.name
        ORDER BY h_ins.history_id DESC
    ) last_ins
    OUTER APPLY
    (
        SELECT TOP (1)
            h_res.log_backup_file_name AS most_recently_restored_file,
            h_res.backup_created_timestamp AS last_restored_backup_created_timestamp
        FROM dbo.log_ship_history h_res
        WHERE h_res.db_name = d.name
          AND UPPER(h_res.status) = N'SUCCESS'
        ORDER BY COALESCE(h_res.time_restored, '1900-01-01') DESC, h_res.history_id DESC
    ) last_res
    WHERE d.state_desc = N'RESTORING'
      AND (@DatabaseName IS NULL OR d.name = @DatabaseName)
    ORDER BY d.name;
END
GO

GRANT EXECUTE ON dbo.Wait_For_RDS_Task_Completion TO [log_ship_restore_user];
GRANT EXECUTE ON dbo.Insert_RDS_Logship TO [log_ship_restore_user];
GRANT EXECUTE ON dbo.Restore_RDS_Logship TO [log_ship_restore_user];
GRANT EXECUTE ON dbo.Monitor_RDS_Logship TO [log_ship_restore_user];

GO
