
--Get the password from the parameter store (SSM)
USE MASTER
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = 'log_ship_restore_user')
CREATE LOGIN [log_ship_restore_user] WITH PASSWORD = '[PASSWORD]'


GRANT VIEW ANY DATABASE TO [log_ship_restore_user];
GO
