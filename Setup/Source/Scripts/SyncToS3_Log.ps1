try{ 
    $aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
    
    # Configure the profile for the service account.
    # The configure commands store these values to ~/.aws/credentials. 
    # These can be run once under the service account and then removed from the script. 
    . $aws configure set aws_access_key_id <access_key_id>
    . $aws configure set aws_secret_access_key <access_secret>


    # Configure the source/target folders
    $bucket = 's3://rds-logship-demo-531a8eeb/backups/LSDemo/Log'
    $source = 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\Log'
    
    # Sync the backups. Note the --delete flag removes backups that are not in the source directory.
    . $aws s3 sync "$source" "$bucket" --delete --region us-east-1
    exit $lastexitcode
}
catch {
    throw
}