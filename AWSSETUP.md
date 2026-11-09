# Manual AWS Setup Guide: RDS SQL Server Log Shipping (PowerShell)

This guide walks through configuring the entire AWS infrastructure for the `rds-logship` project manually using **PowerShell** and the **AWS CLI**. It mirrors the architecture deployed by Terraform.

---

## Architecture Overview

```mermaid
flowchart TD
    subgraph OnPrem["Source SQL Server (Local / On-Prem)"]
        SourceDB[("Source Database: LSDemo")]
        FullJob["SQL Agent: Sync Full"]
        LogJob["SQL Agent: Sync Log"]
        S3User["IAM User: s3_backup_user"]
    end

    subgraph AWSCloud["AWS Cloud"]
        subgraph S3["Amazon S3 Demo Bucket"]
            FullFolder["backups/LSDemo/Full/"]
            LogFolder["backups/LSDemo/Log/"]
        end

        subgraph SSM["AWS Systems Manager"]
            SSMPassword["SSM Parameter Store: log_ship_restore_user password"]
        end

        subgraph VPC["VPC & Networking"]
            RDSInstance[("RDS SQL Server 2022 Express: rds-logship-db")]
            RDSProxyRole["IAM Role: rds-sqlserver-s3-role"]
            OptGroup["Option Group: SQLSERVER_BACKUP_RESTORE"]
        end

        subgraph ECR["Amazon ECR"]
            ECRInsert["ECR: rds-logship-rds-insert-logship"]
        end

        subgraph Lambdas["AWS Lambda Functions"]
            LambdaInsert["rds-logship-rds-insert-logship (Container)"]
            LambdaStop["rds-logship-stop-rds (Python 3.12 Zip)"]
        end
    end

    FullJob -->|AWS CLI S3 Sync| FullFolder
    LogJob -->|AWS CLI S3 Sync| LogFolder
    S3User -.->|Authenticates| FullJob
    S3User -.->|Authenticates| LogJob

    LambdaInsert -->|Reads parameter| SSMPassword
    LambdaInsert -->|Lists log files| LogFolder
    LambdaInsert -->|sqlcmd executes Insert_RDS_Logship| RDSInstance

    LambdaStop -->|Stops instance for cost savings| RDSInstance
    RDSInstance -->|Native Restore from S3 via Option Group| FullFolder
    RDSInstance -->|Native Restore from S3 via Option Group| LogFolder
    RDSProxyRole -->|Grants S3 Read/Write| RDSInstance
```

---

## Prerequisites

Before starting, ensure you have:
1. **PowerShell 5.1+ or PowerShell 7+** (built into Windows).
2. **AWS CLI (v2)** installed (see [Step 0](#step-0-aws-cli-installation-and-authentication)).
3. **Administrative AWS Access** (permissions to create VPC, Subnets, Security Groups, S3 Buckets, IAM Users/Roles/Policies, RDS Instances, ECR Repositories, Lambda Functions, and SSM Parameters).
4. **Docker Desktop** installed and running (required for building Lambda container images with SQL Server ODBC tools).
5. **SQL Server Management Studio (SSMS)** or **sqlcmd** (v18+) for running database setup scripts.

---

## Step 0: AWS CLI Installation and Authentication

Before running any AWS commands, ensure the AWS CLI is installed and authenticated.

### 0.1 Verify or Install AWS CLI v2
Open PowerShell and check if the AWS CLI is installed:
```powershell
aws --version
```
Expected output: `aws-cli/2.x.x ...`

If it is not installed, install it silently via PowerShell:
```powershell
Start-Process msiexec.exe -Wait -ArgumentList '/i https://awscli.amazonaws.com/AWSCLIV2.msi /qn'
```
*(Restart your PowerShell session after the installer finishes)*

---

### 0.2 Authenticate the AWS CLI

Choose the method that matches your environment:

#### Method A: Long-Lived IAM User Access Keys (`aws configure`)
If you have an IAM User access key pair (`AKIA...`):
```powershell
aws configure
```
Enter your credentials when prompted:
```text
AWS Access Key ID [None]: AKIAIOSFODNN7EXAMPLE
AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
Default region name [None]: us-east-1
Default output format [None]: json
```

#### Method B: AWS IAM Identity Center / AWS SSO (`aws configure sso`)
If your organization uses AWS SSO / Identity Center:
```powershell
aws configure sso
```
Follow the browser login prompts, select your account and permission set, and name the profile (e.g. `my-sso-profile`). For daily use:
```powershell
aws sso login --profile my-sso-profile
$env:AWS_PROFILE = "my-sso-profile"
```

#### Method C: Temporary Session Environment Variables
If you received temporary session credentials:
```powershell
$env:AWS_ACCESS_KEY_ID = "ASIA..."
$env:AWS_SECRET_ACCESS_KEY = "..."
$env:AWS_SESSION_TOKEN = "..."
$env:AWS_DEFAULT_REGION = "us-east-1"
```

---

### 0.3 Verify Active Identity
Run the caller identity command in PowerShell:
```powershell
aws sts get-caller-identity
```

Example successful response:
```json
{
    "UserId": "AIDAS6L6EXAMPLEEXAMPLE",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/matt-admin"
}
```

> [!IMPORTANT]
> If `aws sts get-caller-identity` returns an error (`ExpiredToken`, `SignatureDoesNotMatch`, or `AccessDenied`), resolve your authentication before continuing. All steps require permissions to create and manage AWS resources.

---

## Configuration Variables

Run this block in PowerShell to set the session variables used throughout this guide:

```powershell
$AwsRegion = "us-east-1"
$AccountId = (aws sts get-caller-identity --query Account --output text)

# Generate a random 8-character hex suffix for unique naming
$RandSuffix = -join ((48..57) + (97..102) | Get-Random -Count 8 | ForEach-Object {[char]$_})
$BucketName = "rds-logship-demo-$RandSuffix"
$RdsIdentifier = "rds-logship-db"
$DbAdminUser = "admin"
$DbAdminPassword = "ReplaceWithStrongMasterPassword!123"
$DbRestoreUser = "log_ship_restore_user"
$DbRestorePassword = "ReplaceWithStrongRestorePassword!123"
$SsmParamName = "/rds-logship/log-ship-restore-user-password"

Write-Host "AWS Account ID: $AccountId"
Write-Host "Target Region:  $AwsRegion"
Write-Host "S3 Bucket Name: $BucketName"
```

---

## Step 1: Create the S3 Bucket and Folder Prefixes

### 1.1 Create the Bucket & Enable Public Access Block
```powershell
# Create bucket (us-east-1 does not require LocationConstraint)
aws s3api create-bucket `
  --bucket $BucketName `
  --region $AwsRegion

# (If using a region other than us-east-1, add LocationConstraint):
# aws s3api create-bucket --bucket $BucketName --region $AwsRegion `
#   --create-bucket-configuration LocationConstraint=$AwsRegion

# Block all public access
aws s3api put-public-access-block `
  --bucket $BucketName `
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### 1.2 Create Required Prefix Directories
```powershell
aws s3api put-object --bucket $BucketName --key "backups/LSDemo/"
aws s3api put-object --bucket $BucketName --key "backups/LSDemo/Full/"
aws s3api put-object --bucket $BucketName --key "backups/LSDemo/Log/"
```

---

## Step 2: Configure Systems Manager (SSM) Parameter Store

Store the SQL password for `log_ship_restore_user` as a KMS-encrypted `SecureString`:

```powershell
aws ssm put-parameter `
  --name $SsmParamName `
  --description "Password for the log_ship_restore_user SQL login" `
  --type "SecureString" `
  --value $DbRestorePassword `
  --overwrite `
  --tags "Key=Name,Value=log_ship_restore_user password" `
  --region $AwsRegion
```

---

## Step 3: Network & VPC Setup (Prerequisite for RDS)

### 3.1 Create VPC & Enable DNS Hostnames
```powershell
$VpcId = aws ec2 create-vpc `
  --cidr-block 10.0.0.0/16 `
  --query "Vpc.VpcId" `
  --output text

aws ec2 create-tags --resources $VpcId --tags Key=Name,Value=rds-logship-vpc
aws ec2 modify-vpc-attribute --vpc-id $VpcId --enable-dns-support '{\"Value\":true}'
aws ec2 modify-vpc-attribute --vpc-id $VpcId --enable-dns-hostnames '{\"Value\":true}'
Write-Host "VPC ID: $VpcId"
```

### 3.2 Create and Attach Internet Gateway
```powershell
$IgwId = aws ec2 create-internet-gateway `
  --query "InternetGateway.InternetGatewayId" `
  --output text

aws ec2 create-tags --resources $IgwId --tags Key=Name,Value=rds-logship-igw
aws ec2 attach-internet-gateway --vpc-id $VpcId --internet-gateway-id $IgwId
```

### 3.3 Create Two Public Subnets in Different AZs
```powershell
# Get first two available AZs
$Az1 = aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text
$Az2 = aws ec2 describe-availability-zones --query "AvailabilityZones[1].ZoneName" --output text

$Subnet1Id = aws ec2 create-subnet `
  --vpc-id $VpcId `
  --cidr-block 10.0.1.0/24 `
  --availability-zone $Az1 `
  --query "Subnet.SubnetId" `
  --output text
aws ec2 create-tags --resources $Subnet1Id --tags Key=Name,Value=rds-logship-public-subnet-1
aws ec2 modify-subnet-attribute --subnet-id $Subnet1Id --map-public-ip-on-launch

$Subnet2Id = aws ec2 create-subnet `
  --vpc-id $VpcId `
  --cidr-block 10.0.2.0/24 `
  --availability-zone $Az2 `
  --query "Subnet.SubnetId" `
  --output text
aws ec2 create-tags --resources $Subnet2Id --tags Key=Name,Value=rds-logship-public-subnet-2
aws ec2 modify-subnet-attribute --subnet-id $Subnet2Id --map-public-ip-on-launch
```

### 3.4 Create Route Table with Internet Route
```powershell
$RouteTableId = aws ec2 create-route-table `
  --vpc-id $VpcId `
  --query "RouteTable.RouteTableId" `
  --output text
aws ec2 create-tags --resources $RouteTableId --tags Key=Name,Value=rds-logship-public-route-table

aws ec2 create-route `
  --route-table-id $RouteTableId `
  --destination-cidr-block 0.0.0.0/0 `
  --gateway-id $IgwId

aws ec2 associate-route-table --subnet-id $Subnet1Id --route-table-id $RouteTableId
aws ec2 associate-route-table --subnet-id $Subnet2Id --route-table-id $RouteTableId
```

### 3.5 Create DB Subnet Group
```powershell
aws rds create-db-subnet-group `
  --db-subnet-group-name "rds-logship-db-subnet-group" `
  --db-subnet-group-description "Subnet group for RDS SQL Server log shipping" `
  --subnet-ids $Subnet1Id $Subnet2Id `
  --tags Key=Name,Value=rds-logship-db-subnet-group
```

### 3.6 Create RDS Security Group
Allow inbound SQL Server traffic on port 1433:
```powershell
$RdsSgId = aws ec2 create-security-group `
  --group-name "rds-logship-sg" `
  --description "Allow SQL Server traffic" `
  --vpc-id $VpcId `
  --query "GroupId" `
  --output text
aws ec2 create-tags --resources $RdsSgId --tags Key=Name,Value=rds-logship-sg

# Inbound port 1433 (customize CIDR block as required; 0.0.0.0/0 used for demo)
aws ec2 authorize-security-group-ingress `
  --group-id $RdsSgId `
  --protocol tcp `
  --port 1433 `
  --cidr 0.0.0.0/0
```

---

## Step 4: IAM Users, Roles, and Policies

### 4.1 Create On-Prem / Source IAM User (`s3_backup_user`)
The source SQL Server Agent runs scripts under this user's credentials to sync backups to S3.

```powershell
# Create user
aws iam create-user --user-name s3_backup_user

# Attach S3 policy directly to user
@"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::$BucketName"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": "arn:aws:s3:::$BucketName/*"
    }
  ]
}
"@ | Out-File -FilePath s3_user_policy.json -Encoding utf8

aws iam put-user-policy `
  --user-name s3_backup_user `
  --policy-name s3_backup_user-s3-access `
  --policy-document file://s3_user_policy.json
```

Generate access keys for this user and save the output:
```powershell
aws iam create-access-key --user-name s3_backup_user
```

### 4.2 Create IAM Role for RDS SQL Server S3 Integration (`rds-sqlserver-s3-role`)
RDS assumes this role to perform native backup and restore operations from S3.

```powershell
# Trust policy: allows both RDS and s3_backup_user to assume this role
@"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "rds.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::$AccountId:user/s3_backup_user"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
"@ | Out-File -FilePath rds_trust_policy.json -Encoding utf8

aws iam create-role `
  --role-name rds-sqlserver-s3-role `
  --assume-role-policy-document file://rds_trust_policy.json

# Permissions policy for S3 bucket operations
@"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:ListObjectsV2",
        "s3:GetBucketLocation",
        "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3:::$BucketName",
        "arn:aws:s3:::$BucketName/*"
      ]
    }
  ]
}
"@ | Out-File -FilePath rds_s3_policy.json -Encoding utf8

aws iam put-role-policy `
  --role-name rds-sqlserver-s3-role `
  --policy-name rds-sqlserver-s3-policy `
  --policy-document file://rds_s3_policy.json

# Allow s3_backup_user to assume this role
@"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::$AccountId:role/rds-sqlserver-s3-role"
    }
  ]
}
"@ | Out-File -FilePath s3_user_assume_role_policy.json -Encoding utf8

aws iam put-user-policy `
  --user-name s3_backup_user `
  --policy-name s3_backup_user-assume-rds-sqlserver-s3-role `
  --policy-document file://s3_user_assume_role_policy.json
```

---

## Step 5: Configure RDS Option Group & Launch SQL Server Instance

### 5.1 Create RDS Option Group with `SQLSERVER_BACKUP_RESTORE`
```powershell
aws rds create-option-group `
  --option-group-name "rds-sqlserver-s3-option-group" `
  --engine-name "sqlserver-ex" `
  --major-engine-version "16.00" `
  --option-group-description "Option group enabling S3 backup/restore on SQL Server Express 2022" `
  --region $AwsRegion

# Configure the option setting pointing to the IAM Role
@"
[
  {
    "OptionName": "SQLSERVER_BACKUP_RESTORE",
    "OptionSettings": [
      {
        "Name": "IAM_ROLE_ARN",
        "Value": "arn:aws:iam::$AccountId:role/rds-sqlserver-s3-role"
      }
    ]
  }
]
"@ | Out-File -FilePath option_settings.json -Encoding utf8

aws rds modify-option-group `
  --option-group-name "rds-sqlserver-s3-option-group" `
  --options-to-include file://option_settings.json `
  --apply-immediately `
  --region $AwsRegion
```

### 5.2 Create the RDS DB Instance
```powershell
aws rds create-db-instance `
  --db-instance-identifier $RdsIdentifier `
  --db-instance-class "db.t3.micro" `
  --engine "sqlserver-ex" `
  --engine-version "16.00.4165.4.v1" `
  --master-username $DbAdminUser `
  --master-user-password $DbAdminPassword `
  --allocated-storage 20 `
  --storage-type "gp2" `
  --publicly-accessible `
  --db-subnet-group-name "rds-logship-db-subnet-group" `
  --vpc-security-group-ids $RdsSgId `
  --option-group-name "rds-sqlserver-s3-option-group" `
  --backup-retention-period 0 `
  --no-deletion-protection `
  --no-multi-az `
  --region $AwsRegion
```

Wait until the instance is fully provisioned:
```powershell
Write-Host "Waiting for RDS instance to become available..."
aws rds wait db-instance-available --db-instance-identifier $RdsIdentifier
Write-Host "RDS instance is ready!"

# Retrieve the endpoint address
$RdsEndpoint = aws rds describe-db-instances `
  --db-instance-identifier $RdsIdentifier `
  --query "DBInstances[0].Endpoint.Address" `
  --output text

Write-Host "RDS SQL Server Hostname: $RdsEndpoint"
```

---

## Step 6: IAM Roles for Lambda Functions

### 6.1 Create Lambda Trust Policy File
```powershell
@"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
"@ | Out-File -FilePath lambda_trust_policy.json -Encoding utf8
```

### 6.2 Role for `rds-insert-logship` Lambda
```powershell
aws iam create-role `
  --role-name rds-logship-rds-insert-lambda-role `
  --assume-role-policy-document file://lambda_trust_policy.json

aws iam attach-role-policy `
  --role-name rds-logship-rds-insert-lambda-role `
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

# S3 read policy scoped to Log/ prefix
@"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::$BucketName",
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "backups/LSDemo/Log/",
            "backups/LSDemo/Log/*"
          ]
        }
      }
    }
  ]
}
"@ | Out-File -FilePath lambda_insert_s3_policy.json -Encoding utf8

aws iam put-role-policy `
  --role-name rds-logship-rds-insert-lambda-role `
  --policy-name rds-logship-rds-insert-lambda-s3-access `
  --policy-document file://lambda_insert_s3_policy.json

# SSM Parameter Store & KMS Decrypt policy
@"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ssm:GetParameter"],
      "Resource": "arn:aws:ssm:${AwsRegion}:${AccountId}:parameter${SsmParamName}"
    },
    {
      "Effect": "Allow",
      "Action": ["kms:Decrypt"],
      "Resource": "arn:aws:kms:${AwsRegion}:${AccountId}:alias/aws/ssm"
    }
  ]
}
"@ | Out-File -FilePath lambda_ssm_policy.json -Encoding utf8

aws iam put-role-policy `
  --role-name rds-logship-rds-insert-lambda-role `
  --policy-name rds-logship-rds-insert-lambda-ssm-access `
  --policy-document file://lambda_ssm_policy.json
```

### 6.3 Role for `stop-rds-instance` Lambda
```powershell
aws iam create-role `
  --role-name rds-logship-stop-rds-lambda-role `
  --assume-role-policy-document file://lambda_trust_policy.json

aws iam attach-role-policy `
  --role-name rds-logship-stop-rds-lambda-role `
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

@"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBInstances",
        "rds:StopDBInstance"
      ],
      "Resource": "*"
    }
  ]
}
"@ | Out-File -FilePath lambda_stop_rds_policy.json -Encoding utf8

aws iam put-role-policy `
  --role-name rds-logship-stop-rds-lambda-role `
  --policy-name rds-logship-stop-rds-lambda-rds-access `
  --policy-document file://lambda_stop_rds_policy.json
```

---

## Step 7: Build, Push Container Images, and Deploy Lambdas

### 7.1 Create ECR Repositories
```powershell
aws ecr create-repository --repository-name rds-logship-rds-insert-logship --region $AwsRegion

$EcrInsertUri = "$AccountId.dkr.ecr.$AwsRegion.amazonaws.com/rds-logship-rds-insert-logship"
```

### 7.2 Authenticate Docker to Amazon ECR
```powershell
aws ecr get-login-password --region $AwsRegion | docker login --username AWS --password-stdin "$AccountId.dkr.ecr.$AwsRegion.amazonaws.com"
```

### 7.3 Build and Push Container Images
> [!IMPORTANT]
> Always pass `--platform linux/amd64` and `--provenance=false`. Docker Buildx multi-manifest indexes will cause Lambda deployments to fail with `InvalidParameterValueException`.

From the project root folder:
```powershell
# 1. Build & Push Insert Lambda image
docker build --platform linux/amd64 --provenance=false `
  -t "${EcrInsertUri}:latest" `
  terraform\lambda\rds_insert_logship

docker push "${EcrInsertUri}:latest"

```

### 7.4 Deploy the Container Lambdas

Wait 10-15 seconds for IAM role propagation before creating the functions:
```powershell
Start-Sleep -Seconds 10
```

#### Deploy `rds-logship-rds-insert-logship`
```powershell
@"
{
  "Variables": {
    "LOG_BUCKET_NAME": "$BucketName",
    "LOG_PREFIX": "backups/LSDemo/Log/",
    "RESTORE_DB_NAME": "LSDemo",
    "RESTORE_S3_BASE_ARN": "arn:aws:s3:::$BucketName/backups/LSDemo/Log",
    "SQL_HOST": "$RdsEndpoint",
    "SQL_PORT": "1433",
    "SQL_USERNAME": "$DbRestoreUser",
    "DB_RESTORE_PASSWORD_PARAMETER_NAME": "$SsmParamName",
    "UTILITY_DATABASE": "Utility"
  }
}
"@ | Out-File -FilePath env_insert.json -Encoding utf8

aws lambda create-function `
  --function-name "rds-logship-rds-insert-logship" `
  --package-type Image `
  --code ImageUri="${EcrInsertUri}:latest" `
  --role "arn:aws:iam://${AccountId}:role/rds-logship-rds-insert-lambda-role" `
  --timeout 900 `
  --memory-size 256 `
  --environment file://env_insert.json `
  --region $AwsRegion
```

### 7.4 Package and Deploy `rds-logship-stop-rds` Lambda
Use native PowerShell `Compress-Archive` to package the script:

```powershell
# Create zip archive from the script
Compress-Archive `
  -Path terraform\lambda\stop_rds_instance.py `
  -DestinationPath terraform\lambda\stop-rds-instance.zip `
  -Force

@"
{
  "Variables": {
    "DB_INSTANCE_IDENTIFIER": "$RdsIdentifier"
  }
}
"@ | Out-File -FilePath env_stop.json -Encoding utf8

aws lambda create-function `
  --function-name "rds-logship-stop-rds" `
  --runtime "python3.12" `
  --role "arn:aws:iam://${AccountId}:role/rds-logship-stop-rds-lambda-role" `
  --handler "stop_rds_instance.handler" `
  --zip-file "fileb://terraform/lambda/stop-rds-instance.zip" `
  --timeout 30 `
  --memory-size 128 `
  --environment file://env_stop.json `
  --region $AwsRegion
```

### 7.5 Create CloudWatch Log Groups
```powershell
aws logs create-log-group --log-group-name "/aws/lambda/rds-logship-rds-insert-logship"
aws logs put-retention-policy --log-group-name "/aws/lambda/rds-logship-rds-insert-logship" --retention-in-days 14


aws logs create-log-group --log-group-name "/aws/lambda/rds-logship-stop-rds"
aws logs put-retention-policy --log-group-name "/aws/lambda/rds-logship-stop-rds" --retention-in-days 14
```

---

## Step 8: Initialize Database Objects on RDS SQL Server

Execute [UtilityDatabase.sql](file:///Setup/Target/UtilityDatabase.sql) against the new RDS SQL Server using `sqlcmd` from PowerShell:

```powershell
sqlcmd -S "$RdsEndpoint,1433" -U $DbAdminUser -P $DbAdminPassword `
  -v DB_RESTORE_PASSWORD="$DbRestorePassword" `
  -i Setup\Target\UtilityDatabase.sql
```

This creates:
- The `Utility` database.
- The `log_ship_restore_user` SQL login with appropriate privileges.
- The `dbo.log_ship_history` tracking table.
- The stored procedures: `dbo.Wait_For_RDS_Task_Completion`, `dbo.Insert_RDS_Logship`, `dbo.Restore_RDS_Logship`, and `dbo.Monitor_RDS_Logship`.

---

## Step 9: Configure Source Server & Sync Jobs

On the source Windows SQL Server machine:

### 9.1 Set AWS CLI Credentials on the Source Server
Run in PowerShell under the SQL Agent service account context (or interactive admin session):
```powershell
aws configure set aws_access_key_id <YOUR_S3_BACKUP_USER_ACCESS_KEY>
aws configure set aws_secret_access_key <YOUR_S3_BACKUP_USER_SECRET_KEY>
aws configure set default.region us-east-1
```

### 9.2 Update PowerShell Sync Scripts
Copy the files in `Setup\Source\Scripts` to `C:\SQL2022\Scripts\` (or your preferred path) and update the `$bucket` value in:
- `C:\SQL2022\Scripts\SyncToS3_Full.ps1`:
  ```powershell
  $bucket = "s3://$BucketName/backups/LSDemo/Full"
  ```
- `C:\SQL2022\Scripts\SyncToS3_Log.ps1`:
  ```powershell
  $bucket = "s3://$BucketName/backups/LSDemo/Log"
  ```

### 9.3 Create SQL Agent Backup & Sync Jobs
In SSMS or `sqlcmd`, run the scripts in `Setup\Source\Jobs`:
1. `Log Backup.sql` - Schedules transaction log backups every 15 minutes.
2. `Sync Jobs.sql` - Configures the `Sync Full backup` and `Sync Log backup` jobs that invoke PowerShell to run `aws s3 sync`.

---

## Step 10: Perform Initial Full Restore on RDS

1. On the source server, start the **Sync Full backup** SQL Agent job.
2. Check that the `.bak` file uploaded to S3:
   ```powershell
   aws s3 ls "s3://$BucketName/backups/LSDemo/Full/"
   ```
3. Run `Setup\Target\Target_RestoreFullBackup.sql` against the RDS instance (updating the S3 ARN to match your bucket):
   ```sql
   DECLARE @restore_db_name sysname = 'LSDemo';
   DECLARE @S3_arn_to_restore_from varchar(1000) = 'arn:aws:s3:::<YOUR_BUCKET_NAME>/backups/LSDemo/Full/LSDemo_FULL.bak';

   EXEC msdb.dbo.rds_restore_database   
      @restore_db_name = @restore_db_name,
      @S3_arn_to_restore_from = @S3_arn_to_restore_from,
      @with_norecovery = 1;
   ```
4. Check restore task status:
   ```sql
   EXEC msdb.dbo.rds_task_status @db_name = 'LSDemo';
   ```

The database `LSDemo` will remain in the `RESTORING` state on RDS, ready for log backups.

---

## Step 11: Testing & Verification

### 11.1 Test Continuous Log Shipping
Invoke the insert Lambda function to apply pending log backups from S3:
```powershell
aws lambda invoke `
  --function-name rds-logship-rds-insert-logship `
  --payload '{}' `
  response.json

Get-Content response.json
```

Verify applied logs in SQL Server:
```sql
USE Utility;
SELECT * FROM dbo.log_ship_history ORDER BY history_id DESC;
```

### 11.2 Test Stopping the RDS Instance
```powershell
aws lambda invoke `
  --function-name rds-logship-stop-rds `
  --payload '{}' `
  stop_response.json

Get-Content stop_response.json
```

---

## Step 12: Manual Cleanup / Teardown Order (PowerShell)

To delete all resources without leaving orphaned dependencies, run this in PowerShell:

```powershell
# 1. Delete Lambda functions & CloudWatch logs
aws lambda delete-function --function-name rds-logship-rds-insert-logship
aws lambda delete-function --function-name rds-logship-stop-rds
aws logs delete-log-group --log-group-name "/aws/lambda/rds-logship-rds-insert-logship"
aws logs delete-log-group --log-group-name "/aws/lambda/rds-logship-stop-rds"

# 2. Delete ECR Repositories
aws ecr delete-repository --repository-name rds-logship-rds-insert-logship --force

# 3. Delete RDS DB Instance and Option Group
aws rds delete-db-instance --db-instance-identifier $RdsIdentifier --skip-final-snapshot
Write-Host "Waiting for RDS instance deletion..."
aws rds wait db-instance-deleted --db-instance-identifier $RdsIdentifier
aws rds delete-option-group --option-group-name "rds-sqlserver-s3-option-group"
aws rds delete-db-subnet-group --db-subnet-group-name "rds-logship-db-subnet-group"

# 4. Delete IAM Roles and User
aws iam delete-role-policy --role-name rds-logship-rds-insert-lambda-role --policy-name rds-logship-rds-insert-lambda-s3-access
aws iam delete-role-policy --role-name rds-logship-rds-insert-lambda-role --policy-name rds-logship-rds-insert-lambda-ssm-access
aws iam detach-role-policy --role-name rds-logship-rds-insert-lambda-role --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
aws iam delete-role --role-name rds-logship-rds-insert-lambda-role

aws iam delete-role-policy --role-name rds-logship-stop-rds-lambda-role --policy-name rds-logship-stop-rds-lambda-rds-access
aws iam detach-role-policy --role-name rds-logship-stop-rds-lambda-role --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
aws iam delete-role --role-name rds-logship-stop-rds-lambda-role

aws iam delete-role-policy --role-name rds-sqlserver-s3-role --policy-name rds-sqlserver-s3-policy
aws iam delete-role --role-name rds-sqlserver-s3-role

# Delete all access keys for s3_backup_user
(aws iam list-access-keys --user-name s3_backup_user --query 'AccessKeyMetadata[*].AccessKeyId' --output text) -split "\s+" | Where-Object { $_ } | ForEach-Object {
    aws iam delete-access-key --user-name s3_backup_user --access-key-id $_
}
aws iam delete-user-policy --user-name s3_backup_user --policy-name s3_backup_user-s3-access
aws iam delete-user-policy --user-name s3_backup_user --policy-name s3_backup_user-assume-rds-sqlserver-s3-role
aws iam delete-user --user-name s3_backup_user

# 5. Delete SSM Parameter
aws ssm delete-parameter --name $SsmParamName

# 6. Delete S3 Bucket and contents
aws s3 rm "s3://$BucketName" --recursive
aws s3api delete-bucket --bucket $BucketName

# 7. Delete Security Group and VPC
aws ec2 delete-security-group --group-id $RdsSgId
aws ec2 detach-internet-gateway --internet-gateway-id $IgwId --vpc-id $VpcId
aws ec2 delete-internet-gateway --internet-gateway-id $IgwId
aws ec2 delete-subnet --subnet-id $Subnet1Id
aws ec2 delete-subnet --subnet-id $Subnet2Id
aws ec2 delete-route-table --route-table-id $RouteTableId
aws ec2 delete-vpc --vpc-id $VpcId

# Clean up local JSON temporary files
Remove-Item -Path *.json -ErrorAction SilentlyContinue
```
