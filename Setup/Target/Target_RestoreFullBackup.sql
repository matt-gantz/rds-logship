/*
To drop a demo DB that is in the restoring state:

EXEC msdb.dbo.rds_finish_restore  'LSDemo'
EXEC msdb.dbo.rds_drop_database 'LSDemo'
*/
DECLARE @restore_db_name sysname = 'LSDemo'
, @S3_arn_to_restore_from varchar(1000) = 'arn:aws:s3:::rds-logship-demo-531a8eeb/backups/LSDemo/Full/LSDemo_FULL.bak'

EXEC msdb.dbo.rds_restore_database   
   @restore_db_name = @restore_db_name ,
   @S3_arn_to_restore_from = @S3_arn_to_restore_from,
   @with_norecovery=1