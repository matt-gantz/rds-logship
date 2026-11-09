try{ 
$aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'

# Configure the profile for the service account.
# The configure commands store these values to ~/.aws/credentials. 
# These can be run once under the service account and then removed from the script. 
. $aws configure set aws_access_key_id <access_key_id>
. $aws configure set aws_secret_access_key <access_secret>

$bucket = 's3://rds-logship-demo-531a8eeb/backups/LSDemo/Full'
$source = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup'
. $aws s3 sync "$source" "$bucket" --region us-east-1

. $aws s3 ls "$bucket" --region us-east-1
exit $lastexitcode
}
catch {
    throw
}