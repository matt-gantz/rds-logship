import logging
import os
import subprocess

import boto3


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

s3 = boto3.client("s3")
ssm = boto3.client("ssm")

RESTORE_DB_NAME = os.environ["RESTORE_DB_NAME"]
RESTORE_S3_BASE_ARN = os.environ["RESTORE_S3_BASE_ARN"]
UTILITY_DATABASE = os.environ.get("UTILITY_DATABASE", "Utility")
SQL_HOST = os.environ["SQL_HOST"]
SQL_PORT = os.environ.get("SQL_PORT", "1433")
SQL_USERNAME = os.environ["SQL_USERNAME"]
LOG_BUCKET_NAME = os.environ["LOG_BUCKET_NAME"]
LOG_PREFIX = os.environ["LOG_PREFIX"]
DB_RESTORE_PASSWORD_PARAMETER_NAME = os.environ["DB_RESTORE_PASSWORD_PARAMETER_NAME"]
RESTORE_PASSWORD = None


def quote_sql_literal(value):
    return value.replace("'", "''")


def get_restore_password():
    global RESTORE_PASSWORD

    if RESTORE_PASSWORD is None:
        response = ssm.get_parameter(
            Name=DB_RESTORE_PASSWORD_PARAMETER_NAME,
            WithDecryption=True,
        )
        RESTORE_PASSWORD = response["Parameter"]["Value"]

    return RESTORE_PASSWORD


def list_log_objects(bucket_name, prefix):
    paginator = s3.get_paginator("list_objects_v2")
    keys = []

    for page in paginator.paginate(Bucket=bucket_name, Prefix=prefix):
        for item in page.get("Contents", []):
            key = item["Key"]
            if key.endswith("/"):
                continue
            keys.append(key)

    keys.sort()
    return keys


def run_insert_procedure(file_name):
    escaped_file_name = file_name.replace("'", "''")
    escaped_restore_db_name = quote_sql_literal(RESTORE_DB_NAME)
    escaped_restore_s3_base_arn = quote_sql_literal(RESTORE_S3_BASE_ARN)
    sql_batch = (
        "SET NOCOUNT ON; "
        f"EXEC dbo.Insert_RDS_Logship N'{escaped_file_name}', "
        f"N'{escaped_restore_db_name}', "
        f"N'{escaped_restore_s3_base_arn}';"
    )

    command = [
        "sqlcmd",
        "-S",
        f"{SQL_HOST},{SQL_PORT}",
        "-d",
        UTILITY_DATABASE,
        "-U",
        SQL_USERNAME,
        "-N",
        "-C",
        "-b",
        "-l",
        "60",
        "-Q",
        sql_batch,
    ]

    environment = os.environ.copy()
    environment["SQLCMDPASSWORD"] = get_restore_password()

    LOGGER.info("Running insert proc for %s", file_name)
    result = subprocess.run(command, capture_output=True, text=True, env=environment)

    if result.stdout:
        LOGGER.info("sqlcmd output for %s: %s", file_name, result.stdout.strip())
    if result.returncode != 0:
        error_message = result.stderr.strip() or result.stdout.strip() or "sqlcmd failed"
        raise RuntimeError(f"Insert failed for {file_name}: {error_message}")


def handler(event, context):
    log_objects = list_log_objects(LOG_BUCKET_NAME, LOG_PREFIX)
    LOGGER.info("Found %d log file(s) under s3://%s/%s", len(log_objects), LOG_BUCKET_NAME, LOG_PREFIX)

    for key in log_objects:
        file_name = key.rsplit("/", 1)[-1]
        LOGGER.info("Processing %s", file_name)
        run_insert_procedure(file_name)

    return {
        "bucket": LOG_BUCKET_NAME,
        "prefix": LOG_PREFIX,
        "processed_files": [key.rsplit("/", 1)[-1] for key in log_objects],
    }

