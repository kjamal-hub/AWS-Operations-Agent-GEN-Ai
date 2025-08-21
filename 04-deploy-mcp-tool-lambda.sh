#!/bin/bash

# Deploy MCP Tool Lambda function using ZIP-based SAM (no Docker) - Ubuntu Linux version
echo "🚀 Deploying MCP Tool Lambda function (ZIP-based, no Docker) - Ubuntu Linux..."

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - Get project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # Go up two levels to reach AgentCore root
RUNTIME_DIR="$(dirname "$SCRIPT_DIR")"  # agentcore-runtime directory
MCP_TOOL_DIR="${PROJECT_DIR}/mcp-tool-lambda"

# Load configuration from consolidated config files
CONFIG_DIR="${PROJECT_DIR}/config"

# Check if static config exists
if [[ ! -f "${CONFIG_DIR}/static-config.yaml" ]]; then
    echo -e "${RED}❌ Config file not found: ${CONFIG_DIR}/static-config.yaml${NC}"
    exit 1
fi

# Ubuntu-compatible YAML value extraction with fallbacks
get_yaml_value() {
    local key="$1"
    local file="$2"
    
    # Try yq first if available
    if command -v yq &> /dev/null; then
        local value=$(yq eval ".$key" "$file" 2>/dev/null || echo "")
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return
        fi
    fi
    
    # Fallback: Handle nested YAML keys with proper indentation for Ubuntu
    local nested_key="${key##*.}"  # Get the last part after the dot
    grep -E "^[[:space:]]*${nested_key}:" "$file" | head -1 | sed 's/.*:[[:space:]]*["'\'']*\([^"'\'']*\)["'\'']*$/\1/' | xargs
}

REGION=$(get_yaml_value "region" "${CONFIG_DIR}/static-config.yaml")
ACCOUNT_ID=$(get_yaml_value "account_id" "${CONFIG_DIR}/static-config.yaml")

if [[ -z "$REGION" || -z "$ACCOUNT_ID" ]]; then
    echo -e "${RED}❌ Failed to read region or account_id from static-config.yaml${NC}"
    exit 1
fi

STACK_NAME="bac-mcp-stack"

echo -e "${BLUE}📋 Configuration:${NC}"
echo "   Region: $REGION"
echo "   Account ID: $ACCOUNT_ID"
echo "   Stack Name: $STACK_NAME"
echo "   Deployment Type: ZIP-based (no Docker)"
echo "   MCP Tool Directory: $MCP_TOOL_DIR"
echo "   Platform: Ubuntu Linux"
echo ""

# Check if MCP tool directory exists
if [[ ! -d "$MCP_TOOL_DIR" ]]; then
    echo -e "${RED}❌ MCP tool directory not found: $MCP_TOOL_DIR${NC}"
    exit 1
fi

# Function to check Ubuntu dependencies
check_ubuntu_dependencies() {
    echo -e "${BLUE}🔍 Checking Ubuntu dependencies...${NC}"
    
    local deps_ok=true
    local missing_packages=()
    
    # Check essential packages
    local required_packages=("python3" "python3-pip" "python3-venv" "zip" "unzip" "curl" "wget")
    
    for pkg in "${required_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing_packages+=("$pkg")
            deps_ok=false
        fi
    done
    
    # Check for SAM CLI
    if ! command -v sam &> /dev/null; then
        echo -e "${YELLOW}⚠️  SAM CLI not found - will attempt to install${NC}"
        install_sam_cli_ubuntu
    else
        echo -e "${GREEN}✅ SAM CLI available${NC}"
    fi
    
    # Install missing packages if any
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠️  Missing packages: ${missing_packages[*]}${NC}"
        echo "   Installing missing packages..."
        if sudo apt-get update && sudo apt-get install -y "${missing_packages[@]}" > /dev/null 2>&1; then
            echo -e "${GREEN}✅ Missing packages installed${NC}"
        else
            echo -e "${RED}❌ Failed to install missing packages${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}✅ All required packages are installed${NC}"
    fi
    
    return 0
}

# Function to install SAM CLI on Ubuntu
install_sam_cli_ubuntu() {
    echo -e "${BLUE}🔧 Installing AWS SAM CLI for Ubuntu...${NC}"
    
    cd /tmp
    
    # Download SAM CLI for Linux
    if wget -q "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-x86_64.zip" -O sam-cli.zip; then
        echo "   Downloaded SAM CLI"
    else
        echo -e "${RED}❌ Failed to download SAM CLI${NC}"
        return 1
    fi
    
    # Extract and install
    if unzip -q sam-cli.zip -d sam-installation && sudo ./sam-installation/install; then
        echo -e "${GREEN}✅ SAM CLI installed successfully${NC}"
        rm -rf sam-cli.zip sam-installation
        
        # Verify installation
        if sam --version > /dev/null 2>&1; then
            echo -e "${GREEN}✅ SAM CLI installation verified${NC}"
        else
            echo -e "${YELLOW}⚠️  SAM CLI installed but not immediately available${NC}"
            echo "   You may need to restart your shell or run: hash -r"
        fi
    else
        echo -e "${RED}❌ Failed to install SAM CLI${NC}"
        rm -rf sam-cli.zip sam-installation
        return 1
    fi
    
    return 0
}

# Function to setup virtual environment
setup_virtual_environment() {
    echo -e "${BLUE}🐍 Setting up Python virtual environment...${NC}"
    
    cd "$MCP_TOOL_DIR"
    
    # Check if .venv exists
    if [[ ! -d ".venv" ]]; then
        echo "   Creating new virtual environment..."
        if python3 -m venv .venv; then
            echo -e "${GREEN}   ✅ Virtual environment created${NC}"
        else
            echo -e "${RED}❌ Failed to create virtual environment${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}   ✅ Virtual environment already exists${NC}"
    fi
    
    # Activate virtual environment
    echo "   Activating virtual environment..."
    source .venv/bin/activate
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}❌ Failed to activate virtual environment${NC}"
        exit 1
    fi
    echo -e "${GREEN}   ✅ Virtual environment activated${NC}"
    
    # Verify Python version
    local python_version=$(python3 --version)
    echo "   Python version: $python_version"
    
    # Upgrade pip for better compatibility
    echo "   Upgrading pip..."
    pip install --upgrade pip > /dev/null 2>&1
    echo -e "${GREEN}   ✅ pip upgraded${NC}"
}

# Function to install dependencies
install_dependencies() {
    echo -e "${BLUE}📦 Installing Lambda dependencies...${NC}"
    
    cd "$MCP_TOOL_DIR"
    source .venv/bin/activate
    
    # Check if requirements.txt exists
    if [[ ! -f "lambda/requirements.txt" ]]; then
        echo -e "${RED}❌ Requirements file not found: lambda/requirements.txt${NC}"
        exit 1
    fi
    
    # Create packaging directory if it doesn't exist
    mkdir -p ./packaging/python
    
    # Install dependencies with Lambda-compatible settings for Ubuntu
    echo "   Installing dependencies for Lambda runtime (Ubuntu-optimized)..."
    
    # Use pip with Ubuntu-specific settings for Lambda compatibility
    pip install -r lambda/requirements.txt \
        --python-version 3.12 \
        --platform manylinux2014_x86_64 \
        --target ./packaging/python \
        --only-binary=:all: \
        --upgrade \
        --no-warn-script-location
    
    local pip_exit_code=$?
    
    if [[ $pip_exit_code -ne 0 ]]; then
        echo -e "${YELLOW}⚠️  Some packages may have failed with binary-only installation${NC}"
        echo "   Retrying with source compilation allowed..."
        
        # Fallback: allow source compilation for packages that don't have manylinux wheels
        pip install -r lambda/requirements.txt \
            --target ./packaging/python \
            --upgrade \
            --no-warn-script-location
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}❌ Failed to install dependencies${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}   ✅ Dependencies installed successfully${NC}"
    
    # Check package size for Lambda limits
    local package_size=$(du -sh ./packaging/python | cut -f1)
    echo "   Package size: $package_size"
    
    # Clean up unnecessary files to reduce package size
    echo "   Cleaning up unnecessary files..."
    find ./packaging/python -name "*.pyc" -delete
    find ./packaging/python -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find ./packaging/python -name "*.so" -exec strip {} + 2>/dev/null || true
    
    local cleaned_size=$(du -sh ./packaging/python | cut -f1)
    echo "   Cleaned package size: $cleaned_size"
}

# Function to package Lambda function
package_lambda() {
    echo -e "${BLUE}📦 Packaging Lambda function...${NC}"
    
    cd "$MCP_TOOL_DIR"
    source .venv/bin/activate
    
    # Check if packaging script exists
    if [[ -f "package_for_lambda.py" ]]; then
        echo "   Using existing packaging script..."
        python3 package_for_lambda.py
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}❌ Failed to package Lambda function${NC}"
            exit 1
        fi
    else
        echo "   Creating Ubuntu-compatible packaging..."
        
        # Create deployment package directory
        mkdir -p deployment-package
        
        # Copy Lambda function code
        if [[ -d "lambda" ]]; then
            cp -r lambda/* deployment-package/
        else
            echo -e "${RED}❌ Lambda source directory not found${NC}"
            exit 1
        fi
        
        # Copy dependencies
        if [[ -d "packaging/python" ]]; then
            cp -r packaging/python/* deployment-package/
        fi
        
        # Create ZIP package
        cd deployment-package
        zip -rq ../lambda-deployment-package.zip .
        cd ..
        
        echo -e "${GREEN}   ✅ Lambda package created: lambda-deployment-package.zip${NC}"
    fi
    
    echo -e "${GREEN}   ✅ Lambda function packaged successfully${NC}"
}

# Function to deploy with SAM
deploy_with_sam() {
    echo -e "${BLUE}🚀 Deploying with SAM...${NC}"
    
    cd "$MCP_TOOL_DIR"
    
    # Check if deployment script exists
    if [[ -f "deploy-mcp-tool-zip.sh" ]]; then
        echo "   Using existing deployment script..."
        
        # Make sure deployment script is executable
        chmod +x deploy-mcp-tool-zip.sh
        
        # Run deployment script
        ./deploy-mcp-tool-zip.sh
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}❌ SAM deployment failed${NC}"
            exit 1
        fi
    else
        echo "   Running direct SAM deployment..."
        
        # Check if SAM template exists
        if [[ ! -f "template.yaml" ]]; then
            echo -e "${RED}❌ SAM template not found: template.yaml${NC}"
            exit 1
        fi
        
        # Build with SAM
        echo "   Building with SAM..."
        sam build --use-container=false
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}❌ SAM build failed${NC}"
            exit 1
        fi
        
        # Deploy with SAM
        echo "   Deploying with SAM..."
        sam deploy \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --capabilities CAPABILITY_IAM \
            --no-confirm-changeset \
            --no-fail-on-empty-changeset
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}❌ SAM deployment failed${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}   ✅ SAM deployment completed successfully${NC}"
}

# Function to update dynamic configuration
update_dynamic_config() {
    echo -e "${BLUE}📝 Updating dynamic configuration...${NC}"
    
    # Get Lambda function details
    local function_name="bac-mcp-tool"  # Adjust if different
    local function_arn=""
    local role_arn=""
    
    # Try to get function details
    if aws lambda get-function --function-name "$function_name" --region "$REGION" > /dev/null 2>&1; then
        local function_details=$(aws lambda get-function --function-name "$function_name" --region "$REGION" 2>/dev/null)
        
        # Extract ARN using multiple methods
        if command -v jq >/dev/null 2>&1; then
            function_arn=$(echo "$function_details" | jq -r '.Configuration.FunctionArn' 2>/dev/null)
            role_arn=$(echo "$function_details" | jq -r '.Configuration.Role' 2>/dev/null)
        else
            # Fallback for systems without jq
            function_arn=$(echo "$function_details" | grep -o '"FunctionArn": "[^"]*"' | cut -d'"' -f4)
            role_arn=$(echo "$function_details" | grep -o '"Role": "[^"]*"' | cut -d'"' -f4)
        fi
        
        echo "   Function ARN: $function_arn"
        echo "   Role ARN: $role_arn"
        
        # Update dynamic config if available
        local dynamic_config="${CONFIG_DIR}/dynamic-config.yaml"
        if [[ -f "$dynamic_config" ]]; then
            # Create or update mcp_lambda section
            if grep -q "mcp_lambda:" "$dynamic_config"; then
                # Update existing section using GNU sed
                sed -i \
                    -e "s|function_name: \"\"|function_name: \"$function_name\"|" \
                    -e "s|function_arn: \"\"|function_arn: \"$function_arn\"|" \
                    -e "s|stack_name: \"\"|stack_name: \"$STACK_NAME\"|" \
                    "$dynamic_config"
            else
                # Add new section
                cat >> "$dynamic_config" << EOF

mcp_lambda:
  function_name: "$function_name"
  function_arn: "$function_arn"
  role_arn: "$role_arn"
  stack_name: "$STACK_NAME"
EOF
            fi
            echo -e "${GREEN}   ✅ Dynamic configuration updated${NC}"
        fi
    else
        echo -e "${YELLOW}   ⚠️  Could not retrieve function details for config update${NC}"
    fi
}

# Main execution
main() {
    echo -e "${BLUE}🔄 Starting complete ZIP-based deployment pipeline...${NC}"
    echo ""
    
    # Step 0: Check Ubuntu dependencies
    if ! check_ubuntu_dependencies; then
        exit 1
    fi
    echo ""
    
    # Step 1: Setup virtual environment
    setup_virtual_environment
    echo ""
    
    # Step 2: Install dependencies
    install_dependencies
    echo ""
    
    # Step 3: Package Lambda function
    package_lambda
    echo ""
    
    # Step 4: Deploy with SAM
    deploy_with_sam
    echo ""
    
    # Step 5: Update dynamic configuration
    update_dynamic_config
    echo ""
    
    echo -e "${GREEN}🎉 Complete MCP Tool Lambda Deployment Successful!${NC}"
    echo "=================================================="
    echo ""
    echo -e "${GREEN}✅ Ubuntu dependencies: Verified/installed${NC}"
    echo -e "${GREEN}✅ Virtual environment: Created/verified${NC}"
    echo -e "${GREEN}✅ Dependencies: Installed for Lambda runtime${NC}"
    echo -e "${GREEN}✅ Lambda package: Created with all dependencies${NC}"
    echo -e "${GREEN}✅ SAM deployment: Completed successfully${NC}"
    echo -e "${GREEN}✅ Configuration: Updated with deployment details${NC}"
    echo ""
    echo -e "${BLUE}🎯 Benefits of this Ubuntu-optimized deployment:${NC}"
    echo "   • No Docker caching issues"
    echo "   • Faster deployments on Ubuntu systems"
    echo "   • No Docker daemon required"
    echo "   • Architecture-specific dependency handling"
    echo "   • Automated virtual environment management"
    echo "   • Complete dependency isolation"
    echo "   • Ubuntu package management integration"
    echo "   • Enhanced error handling and recovery"
    echo ""
    echo -e "${BLUE}📋 Next Steps:${NC}"
    echo "   • Run ../05-create-gateway-targets.sh to create AgentCore Gateway"
    echo "   • Test the Lambda function with MCP tools"
    echo "   • Deploy DIY or SDK agents to use the MCP tools"
    echo ""
    echo -e "${BLUE}🔧 Troubleshooting:${NC}"
    echo "   • Check CloudWatch logs: /aws/lambda/bac-mcp-tool"
    echo "   • Verify IAM permissions for Cost Explorer and Budgets"
    echo "   • Test individual tools with the Lambda function"
    echo "   • Review Ubuntu-specific package installations"
}

# Run main function
main "$@"