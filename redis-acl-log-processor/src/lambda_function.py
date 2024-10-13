import logging
import boto3
import json
import os
import time

from datetime import datetime
from redis import Redis

# Set up logging
logger = logging.getLogger()
logger.setLevel("INFO")

# Environment variables
S3_BUCKET = os.environ['S3_BUCKET']
REDIS_CLUSTER_ENDPOINT = os.environ['REDIS_CLUSTER_ENDPOINT']
REGION = os.environ['AWS_REGION']

# Initialize AWS services
s3 = boto3.client('s3')
ssm = boto3.client('ssm', region_name=REGION)

def parse_client_info(client_info_str):
    """Convert client-info string to a dictionary while extracting IPs without ports."""
    client_info = {}

    # Split by space and process each part
    for item in client_info_str.split():
        key, value = item.split('=', 1)

        # Check if the key is 'addr' or 'laddr' to remove the port
        if key in ['addr', 'laddr']:
            # Extract only the IP address
            value = value.split(':')[0]

        client_info[key] = value

    return client_info

def get_redis_credentials():
    """Fetch Redis username and password from SSM Parameter Store."""
    try:
        username_param = ssm.get_parameter(Name='acl-log-cluster1-user', WithDecryption=True)
        password_param = ssm.get_parameter(Name='acl-log-cluster1-pwd', WithDecryption=True)
        username = username_param['Parameter']['Value']
        password = password_param['Parameter']['Value']
        return username, password
    except Exception as e:
        logger.error(f"Error fetching Redis credentials: {e}")
        raise

# Initialize Redis client
username, password = get_redis_credentials()
redis_client = Redis(
    host=REDIS_CLUSTER_ENDPOINT,
    port=6379,
    username=username,
    password=password,
    decode_responses=True,
    ssl=True
)

def lambda_handler(event, context):
    # Fetch all logs from Redis
    logs = fetch_acl_logs()

    if logs:
        process_logs(logs)
        reset_acl_log()  # Clear the logs after processing
    else:
        logger.info("No logs to process.")

def fetch_acl_logs():
    """Fetch the latest ACL logs from Redis."""
    try:
        data_list = []
        logs = redis_client.execute_command("ACL LOG 128")
        if logs:
            for log in logs:
                # Construct a dictionary from the raw log list
                entry_dict = {log[i]: log[i + 1] for i in range(0, len(log), 2)}
                # Parse the client-info string into a dictionary
                entry_dict['client-info'] = parse_client_info(entry_dict['client-info'])
                data_list.append(entry_dict)
        return data_list  # Return formatted logs
    except Exception as e:
        logger.error(f"Error fetching logs from Redis: {e}")
        return []

def process_logs(logs):
    """Process logs and store them in S3."""
    current_date = datetime.now().strftime("%Y-%m-%d")
    epoch_timestamp = int(time.time())

    endpoint_parts = REDIS_CLUSTER_ENDPOINT.split('.')
    if len(endpoint_parts) >= 2:
        if endpoint_parts[0] == "master":
            cluster_name = endpoint_parts[1]
        else:
            cluster_name = endpoint_parts[0]
    unique_filename = f"{cluster_name}/logs_{current_date}_{epoch_timestamp}.json"

    # Write all logs to a single file in S3
    logs_json = "\n".join(json.dumps(log, separators=(',', ':')) for log in logs)
    s3.put_object(Bucket=S3_BUCKET, Key=unique_filename, Body=logs_json)

    logging.info(f"Stored {len(logs)} logs in S3 as {unique_filename}.")

def reset_acl_log():
    """Reset ACL logs in Redis."""
    try:
        redis_client.execute_command("ACL LOG RESET")
        logger.info("ACL logs have been reset.")
    except Exception as e:
        logger.error(f"Error resetting ACL logs: {e}")