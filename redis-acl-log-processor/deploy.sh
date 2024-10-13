#!/bin/bash
# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to display help message
show_help() {
    echo "Usage: ./deploy.sh -b <s3-bucket-name> -r <redis-cluster-endpoint> -u <redis-username-param> -p <redis-password-param> -g <aws-region> -s <lambda-schedule>  [-c <custom-bucket-name>]"
    echo ""
    echo "Options:"
    echo "  -b <s3-bucket-name>      Specify the S3 bucket name (must be globally unique)."
    echo "  -r <redis-cluster-endpoint>     Specify the Redis cluster Endpoint."
    echo "  -u <redis-username-param> Specify the SSM parameter name for the Redis username."
    echo "  -p <redis-password-param> Specify the SSM parameter name for the Redis password."
    echo "  -g <aws-region>           Specify the AWS region (default: eu-west-1)."
    echo "  -s <lambda-schedule>      Specify the Lambda schedule expression (default: rate(12 hours))."
    echo "  -c <custom-bucket-name>   Specify the custom S3 bucket name for the processed logs (optional)."
    echo "  -h                        Display this help message."
}

# Default values
AWS_REGION="eu-west-1"   # Default AWS region
LAMBDA_SCHEDULE="rate(12\ hours)" # Default Lambda schedule

# Parse command-line arguments
while getopts "b:r:u:p:g:s:c:h" opt; do
    case $opt in
        b) S3_BUCKET_NAME="$OPTARG" ;;
        r) REDIS_CLUSTER_ENDPOINT="$OPTARG" ;;
        u) REDIS_USERNAME_PARAM="$OPTARG" ;;
        p) REDIS_PASSWORD_PARAM="$OPTARG" ;;
        g) AWS_REGION="$OPTARG" ;;
        s) LAMBDA_SCHEDULE="$OPTARG" ;;
        c) CUSTOM_BUCKET_NAME="$OPTARG" ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

# Check if required parameters are provided
if [ -z "$S3_BUCKET_NAME" ] || [ -z "$REDIS_CLUSTER_ENDPOINT" ] || [ -z "$REDIS_USERNAME_PARAM" ] || [ -z "$REDIS_PASSWORD_PARAM" ] || [ -z "$CUSTOM_BUCKET_NAME" ]; then
    echo "Error: S3 bucket names, Redis cluster ID, Redis username parameter, and Redis password parameter are required."
    show_help
    exit 1
fi

# Check for required tools
echo "Checking for required tools..."
if ! command_exists sam; then
    echo "AWS SAM CLI is not installed. Please install it first."
    exit 1
fi
if ! command_exists aws; then
    echo "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Create the S3 bucket if it doesn't exist
echo "Checking if the S3 bucket $S3_BUCKET_NAME exists..."
if ! aws s3api head-bucket --bucket "$S3_BUCKET_NAME" 2>/dev/null; then
    echo "Creating S3 bucket $S3_BUCKET_NAME..."
    aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION"
    if [ $? -ne 0 ]; then
        echo "Error creating S3 bucket. Please check your permissions."
        exit 1
    fi
else
    echo "S3 bucket $S3_BUCKET_NAME already exists."
fi

# Build the application
echo "Building the SAM application..."
sam build

# Package the application
echo "Packaging the SAM application..."
sam package \
    --output-template-file packaged.yaml \
    --s3-bucket "$S3_BUCKET_NAME" \
    --region "$AWS_REGION"

# Deploy the application
echo "Deploying the SAM application..."
sam deploy \
    --template-file packaged.yaml \
    --stack-name redis-acl-processor-stack \
    --parameter-overrides \
        RedisClusterId="$REDIS_CLUSTER_ENDPOINT" \
        RedisUsernameParameter="$REDIS_USERNAME_PARAM" \
        RedisPasswordParameter="$REDIS_PASSWORD_PARAM" \
        LambdaSchedule="$LAMBDA_SCHEDULE" \
        S3Bucket="$CUSTOM_BUCKET_NAME" \
    --region "$AWS_REGION" \
    --guided

echo "Deployment complete."