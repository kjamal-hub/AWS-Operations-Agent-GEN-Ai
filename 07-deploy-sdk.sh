#!/bin/bash

# Deploy the SDK agent implementation to ECR
echo "🚀 Deploying SDK agent (BedrockAgentCoreApp)..."

# Configuration - Get project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # Go up two levels to reach AgentCore root
RUNTIME_DIR="$(dirname "$SCRIPT_DIR")"  # agentcore-runtime directory

# Load configuration from unified config system
CONFIG_DIR="${PROJECT_DIR}/config"
BASE_SETTINGS="${CONFIG_DIR}/static-config.yaml"

# Check if config file exists
if [ ! -f "${BASE_SETTINGS}" ]; then
    echo "❌ Configuration file not found: ${BASE_SETTINGS}"
    exit 1
fi

# Extract configuration using sed (Ubuntu compatible)
echo "📋 Reading configuration..."
if command -v yq >/dev/null 2>&1; then
    echo "   Using yq for YAML parsing"
    REGION=$(yq eval '.aws.region' "${BASE_SETTINGS}")
    ACCOUNT_ID=$(yq eval '.aws.account_id' "${BASE_SETTINGS}")
else
    echo "   Using sed/grep fallback for YAML parsing"
    # More robust sed extraction for Ubuntu
    REGION=$(sed -n 's/^[[:space:]]*region[[:space:]]*:[[:space:]]*["'\'']*\([^"'\''#]*\)["'\'']*.*$/\1/p' "${BASE_SETTINGS}" | head -1 | sed 's/[[:space:]]*$//')
    ACCOUNT_ID=$(sed -n 's/^[[:space:]]*account_id[[:space:]]*:[[:space:]]*["'\'']*\([^"'\''#]*\)["'\'']*.*$/\1/p' "${BASE_SETTINGS}" | head -1 | sed 's/[[:space:]]*$//')
fi

# Validate extracted values
if [ -z "$REGION" ] || [ -z "$ACCOUNT_ID" ]; then
    echo "❌ Failed to extract AWS region or account ID from config"
    echo "   Region: '${REGION}'"
    echo "   Account ID: '${ACCOUNT_ID}'"
    echo "   Please check your configuration file: ${BASE_SETTINGS}"
    exit 1
fi

ECR_REPO="bac-runtime-repo-sdk"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"

echo "   ✅ Region: ${REGION}"
echo "   ✅ Account ID: ${ACCOUNT_ID}"
echo "   ✅ ECR Repository: ${ECR_REPO}"

# Get AWS credentials from SSO
echo "🔐 Setting up AWS credentials..."
if [ -n "$AWS_PROFILE" ]; then
    echo "   Using existing AWS profile: $AWS_PROFILE"
else
    echo "   Using default AWS credentials"
fi

# Use configured AWS profile if specified in static config
AWS_PROFILE_CONFIG=$(sed -n 's/^[[:space:]]*aws_profile[[:space:]]*:[[:space:]]*["'\'']*\([^"'\''#]*\)["'\'']*.*$/\1/p' "${CONFIG_DIR}/static-config.yaml" | head -1 | sed 's/[[:space:]]*$//')
if [ -n "$AWS_PROFILE_CONFIG" ] && [ "$AWS_PROFILE_CONFIG" != '""' ] && [ "$AWS_PROFILE_CONFIG" != "''" ] && [ "$AWS_PROFILE_CONFIG" != "null" ]; then
    echo "   Using configured AWS profile: $AWS_PROFILE_CONFIG"
    export AWS_PROFILE="$AWS_PROFILE_CONFIG"
fi

# Verify AWS CLI is available
if ! command -v aws >/dev/null 2>&1; then
    echo "❌ AWS CLI not found. Please install aws-cli:"
    echo "   sudo apt update && sudo apt install awscli"
    exit 1
fi

# Verify Docker is available and running
if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker not found. Please install Docker:"
    echo "   curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker daemon is not running. Please start Docker:"
    echo "   sudo systemctl start docker"
    echo "   sudo systemctl enable docker"
    exit 1
fi

# Login to ECR
echo "🔑 Logging into ECR..."
if ! aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${ECR_URI}"; then
    echo "❌ Failed to login to ECR. Please check your AWS credentials and permissions."
    exit 1
fi

# Check if repository exists, create if not
echo "📦 Checking ECR repository..."
if ! aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${REGION}" >/dev/null 2>&1; then
    echo "   Creating ECR repository: ${ECR_REPO}"
    if aws ecr create-repository --repository-name "${ECR_REPO}" --region "${REGION}" >/dev/null; then
        echo "   ✅ ECR repository created successfully"
    else
        echo "   ❌ Failed to create ECR repository"
        exit 1
    fi
else
    echo "   ✅ ECR repository exists: ${ECR_REPO}"
fi

# Verify Dockerfile exists
DOCKERFILE_PATH="${PROJECT_DIR}/agentcore-runtime/deployment/Dockerfile.sdk"
if [ ! -f "${DOCKERFILE_PATH}" ]; then
    echo "❌ Dockerfile not found: ${DOCKERFILE_PATH}"
    exit 1
fi

# Build ARM64 image using SDK Dockerfile
echo "🔨 Building ARM64 image..."
echo "   Building from: ${PROJECT_DIR}"
echo "   Using Dockerfile: ${DOCKERFILE_PATH}"
cd "${PROJECT_DIR}"

# Build with better error handling
if docker build --platform linux/arm64 -f agentcore-runtime/deployment/Dockerfile.sdk -t "${ECR_REPO}:latest" .; then
    echo "   ✅ Image built successfully"
else
    echo "   ❌ Docker build failed"
    exit 1
fi

# Tag for ECR
echo "🏷️ Tagging image..."
docker tag "${ECR_REPO}:latest" "${ECR_URI}:latest"

# Push to ECR
echo "📤 Pushing to ECR..."
if docker push "${ECR_URI}:latest"; then
    echo "   ✅ Image pushed successfully"
else
    echo "   ❌ Failed to push image to ECR"
    exit 1
fi

# Update dynamic configuration with ECR URI
echo "📝 Updating dynamic config with ECR URI..."
DYNAMIC_CONFIG="${CONFIG_DIR}/dynamic-config.yaml"

# Create dynamic config if it doesn't exist
if [ ! -f "${DYNAMIC_CONFIG}" ]; then
    echo "   Creating dynamic config file..."
    cat > "${DYNAMIC_CONFIG}" << EOF
# Dynamic configuration - auto-generated
runtime:
  sdk_agent:
    ecr_uri: "${ECR_URI}:latest"
EOF
    echo "   ✅ Dynamic config created"
elif command -v yq >/dev/null 2>&1; then
    # Use yq if available
    yq eval '.runtime.sdk_agent.ecr_uri = "'"${ECR_URI}:latest"'"' -i "${DYNAMIC_CONFIG}"
    echo "   ✅ Dynamic config updated with ECR URI using yq"
else
    # Fallback: update using sed
    if grep -q "ecr_uri:" "${DYNAMIC_CONFIG}"; then
        # Update existing entry
        sed -i 's|ecr_uri:.*|ecr_uri: "'"${ECR_URI}:latest"'"|' "${DYNAMIC_CONFIG}"
    else
        # Add new entry - ensure proper YAML structure
        if grep -q "sdk_agent:" "${DYNAMIC_CONFIG}"; then
            # Add under existing sdk_agent section
            sed -i '/sdk_agent:/a\    ecr_uri: "'"${ECR_URI}:latest"'"' "${DYNAMIC_CONFIG}"
        elif grep -q "runtime:" "${DYNAMIC_CONFIG}"; then
            # Add sdk_agent section under runtime
            sed -i '/runtime:/a\  sdk_agent:\n    ecr_uri: "'"${ECR_URI}:latest"'"' "${DYNAMIC_CONFIG}"
        else
            # Add everything
            cat >> "${DYNAMIC_CONFIG}" << EOF

runtime:
  sdk_agent:
    ecr_uri: "${ECR_URI}:latest"
EOF
        fi
    fi
    echo "   ✅ Dynamic config updated with ECR URI using sed"
fi

echo "✅ SDK agent deployed to: ${ECR_URI}:latest"
echo ""

# Automatically run the runtime deployment script
echo "🚀 Running runtime deployment script..."
echo "   Executing: python3 deploy-sdk-runtime.py"
echo ""

cd "${SCRIPT_DIR}"

# Check if Python script exists
if [ ! -f "deploy-sdk-runtime.py" ]; then
    echo "❌ Python deployment script not found: deploy-sdk-runtime.py"
    echo "   Please ensure the script exists in: ${SCRIPT_DIR}"
    exit 1
fi

# Check if Python 3 is available
if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ Python 3 not found. Please install Python 3:"
    echo "   sudo apt update && sudo apt install python3 python3-pip"
    exit 1
fi

if python3 deploy-sdk-runtime.py; then
    echo ""
    echo "🎉 SDK Agent Deployment Complete!"
    echo "================================="
    echo "✅ ECR image deployed: ${ECR_URI}:latest"
    echo "✅ AgentCore runtime created and configured"
    echo ""
    echo "📋 What was deployed:"
    echo "   • Docker image built and pushed to ECR"
    echo "   • AgentCore runtime instance created"
    echo "   • OAuth integration with bac-identity-provider-okta"
    echo "   • MCP client for bac-gtw gateway"
    echo "   • AgentCore Memory integration"
    echo ""
    echo "💻 Your SDK agent is now ready to use OAuth2 tokens and MCP gateway!"
    echo "   Uses BedrockAgentCoreApp framework with @entrypoint decorator"
    echo "   Connect to the MCP gateway for tool access"
else
    echo ""
    echo "❌ Runtime deployment failed"
    echo "Please check the error messages above and try running manually:"
    echo "   cd ${SCRIPT_DIR}"
    echo "   python3 deploy-sdk-runtime.py"
    exit 1
fi