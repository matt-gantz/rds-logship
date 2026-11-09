import logging
import os

import boto3


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

rds = boto3.client("rds")


def handler(event, context):
    db_instance_identifier = os.environ["DB_INSTANCE_IDENTIFIER"]

    response = rds.describe_db_instances(DBInstanceIdentifier=db_instance_identifier)
    db_instance = response["DBInstances"][0]
    status = db_instance["DBInstanceStatus"]

    LOGGER.info("RDS instance %s is currently %s", db_instance_identifier, status)

    if status in {"stopped", "stopping"}:
        LOGGER.info("RDS instance %s is already stopping or stopped", db_instance_identifier)
        return {"status": status, "action": "noop"}

    if status != "available":
        LOGGER.info("RDS instance %s is not in a stoppable state", db_instance_identifier)
        return {"status": status, "action": "noop"}

    rds.stop_db_instance(DBInstanceIdentifier=db_instance_identifier)
    LOGGER.info("Requested stop for RDS instance %s", db_instance_identifier)
    return {"status": status, "action": "stop_requested"}
