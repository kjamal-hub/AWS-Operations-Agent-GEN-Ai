#!/bin/bash

# Setup OAuth2 Credential Provider for AgentCore - Ubuntu Linux version
# Run this BEFORE deploying agents so they have OAuth capability from day 1

set -e  # Exit on any error

echo "🔧 AgentCore OAuth2 Credential Provider Setup (Ubuntu Linux)"
echo "============================================================"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory and project paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # Go up two levels to reach AgentCore root
CONFIG_DIR="${PROJECT_DIR}/config"

# Load static configuration
if [[ ! -f "${CONFIG_DIR}/static-config.yaml" ]]; then
    echo -e "${RED}❌ Config file not found: ${CONFIG_DIR}/static-config.yaml${NC}"
    exit 1
fi

# Extract values from YAML (Ubuntu-compatible method with fallbacks)
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
OKTA_DOMAIN_STATIC=$(get_yaml_value "okta.domain" "${CONFIG_DIR}/static-config.yaml")

echo -e "${BLUE}📋 This script will:${NC}"
echo "   1. Prompt for your Okta credentials (secure input)"
echo "   2. Create OAuth2 credential provider in AgentCore"
echo "   3. Update configuration files with provider details"
echo "   4. Prepare for agent deployment"
echo ""

# Function to verify prerequisites
verify_prerequisites() {
    echo -e "${BLUE}🔍 Verifying prerequisites...${NC}"
    
    # Check if prerequisites.sh has been run
    if ! aws iam get-role --role-name bac-execution-role &> /dev/null; then
        echo -e "${RED}❌ IAM role not found: bac-execution-role${NC}"
        echo "   Please run ./01-prerequisites-ubuntu.sh first"
        return 1
    fi
    
    # Check ECR repositories
    local repos=("bac-runtime-repo-diy" "bac-runtime-repo-sdk")
    for repo in "${repos[@]}"; do
        if ! aws ecr describe-repositories --repository-names "$repo" --region "$REGION" &> /dev/null; then
            echo -e "${RED}❌ ECR repository not found: $repo${NC}"
            echo "   Please run ./01-prerequisites-ubuntu.sh first"
            return 1
        fi
    done
    
    echo -e "${GREEN}✅ Prerequisites verified${NC}"
    return 0
}

# Function to collect Okta credentials securely
collect_okta_credentials() {
    echo -e "${BLUE}🔑 Okta Credential Collection${NC}"
    echo -e "${BLUE}=============================${NC}"
    echo "Please provide your Okta application credentials:"
    echo ""
    
    # Use Okta domain from static config or prompt if not found
    if [[ -n "$OKTA_DOMAIN_STATIC" ]]; then
        OKTA_DOMAIN="$OKTA_DOMAIN_STATIC"
        echo "Using Okta Domain from config: $OKTA_DOMAIN"
    else
        echo -n "Okta Domain (e.g., trial-7575566.okta.com): "
        read OKTA_DOMAIN
        
        if [[ -z "$OKTA_DOMAIN" ]]; then
            echo -e "${RED}❌ Okta domain is required${NC}"
            return 1
        fi
    fi
    
    # Collect Client ID
    echo -n "Client ID: "
    read OKTA_CLIENT_ID
    
    if [[ -z "$OKTA_CLIENT_ID" ]]; then
        echo -e "${RED}❌ Client ID is required${NC}"
        return 1
    fi
    
    # Collect Client Secret (hidden input)
    echo -n "Client Secret (input will be hidden): "
    read -s OKTA_CLIENT_SECRET
    echo ""  # New line after hidden input
    
    if [[ -z "$OKTA_CLIENT_SECRET" ]]; then
        echo -e "${RED}❌ Client secret is required${NC}"
        return 1
    fi
    
    # Collect custom scope
    echo ""
    echo -e "${BLUE}ℹ️  Custom Scope Configuration:${NC}"
    echo "   • This scope must be created in your Okta Authorization Server"
    echo "   • Go to: Security > API > Authorization Servers > [your-server] > Scopes"
    echo "   • Create a custom scope (e.g., 'api') if it doesn't exist"
    echo ""
    echo -n "Custom Scope (default: api): "
    read OKTA_SCOPE
    OKTA_SCOPE=${OKTA_SCOPE:-api}
    
    echo ""
    echo -e "${GREEN}✅ Credentials collected${NC}"
    echo "   Domain: $OKTA_DOMAIN"
    echo "   Client ID: $OKTA_CLIENT_ID"
    echo "   Client Secret: [HIDDEN]"
    echo "   Scope: $OKTA_SCOPE"
    echo ""
    
    return 0
}

# Function to extract ARN from JSON response (Ubuntu-compatible)
extract_provider_arn() {
    local json_response="$1"
    local arn=""
    
    # Method 1: Try jq if available (most reliable)
    if command -v jq >/dev/null 2>&1; then
        arn=$(echo "$json_response" | jq -r '.credentialProviderArn' 2>/dev/null)
        if [[ -n "$arn" && "$arn" != "null" ]]; then
            echo "$arn"
            return 0
        fi
    fi
    
    # Method 2: Python JSON parsing (reliable fallback)
    arn=$(python3 -c "
import json
import sys
try:
    data = json.loads('''$json_response''')
    arn = data.get('credentialProviderArn', '')
    if arn:
        print(arn)
    else:
        sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null)
    
    if [[ -n "$arn" ]]; then
        echo "$arn"
        return 0
    fi
    
    # Method 3: Grep and sed fallback for Ubuntu
    arn=$(echo "$json_response" | grep -o '"credentialProviderArn"[^,}]*' | sed 's/.*: *"\([^"]*\)".*/\1/' | head -1)
    if [[ -n "$arn" ]]; then
        echo "$arn"
        return 0
    fi
    
    # Method 4: Handle escaped JSON strings
    arn=$(echo "$json_response" | sed -n 's/.*\\\"credentialProviderArn\\\":\\\"\\([^\\]*\\)\\\".*/\1/p' | head -1)
    if [[ -n "$arn" ]]; then
        echo "$arn"
        return 0
    fi
    
    return 1
}

# Function to create OAuth2 credential provider
create_oauth_provider() {
    echo -e "${BLUE}🔧 Creating OAuth2 Credential Provider${NC}"
    echo -e "${BLUE}=====================================${NC}"
    
    local provider_name="bac-identity-provider-okta"
    local well_known_url="https://${OKTA_DOMAIN}/oauth2/default/.well-known/openid-configuration"
    
    echo "   Provider Name: $provider_name"
    echo "   Domain: $OKTA_DOMAIN"
    echo "   Discovery URL: $well_known_url"
    echo "   Client ID: $OKTA_CLIENT_ID"
    echo ""
    
    # Check if provider already exists
    if aws bedrock-agentcore-control get-oauth2-credential-provider --name "$provider_name" --region "$REGION" &> /dev/null; then
        echo -e "${YELLOW}⚠️  Provider already exists, updating configuration...${NC}"
        
        # Update existing provider with correct configuration
        local update_output
        if update_output=$(aws bedrock-agentcore-control update-oauth2-credential-provider \
            --name "$provider_name" \
            --credential-provider-vendor "CustomOauth2" \
            --oauth2-provider-config-input "{
                \"customOauth2ProviderConfig\": {
                    \"oauthDiscovery\": {
                        \"discoveryUrl\": \"$well_known_url\"
                    },
                    \"clientId\": \"$OKTA_CLIENT_ID\",
                    \"clientSecret\": \"$OKTA_CLIENT_SECRET\"
                }
            }" \
            --region "$REGION" 2>&1); then
            
            echo -e "${GREEN}✅ OAuth2 credential provider updated successfully${NC}"
        else
            echo -e "${RED}❌ Failed to update OAuth2 credential provider${NC}"
            echo "$update_output"
            return 1
        fi
    else
        echo "   Creating new OAuth2 credential provider..."
        
        # Create new provider using AWS CLI (more reliable than SDK)
        local create_output
        if create_output=$(aws bedrock-agentcore-control create-oauth2-credential-provider \
            --name "$provider_name" \
            --credential-provider-vendor "CustomOauth2" \
            --oauth2-provider-config-input "{
                \"customOauth2ProviderConfig\": {
                    \"oauthDiscovery\": {
                        \"discoveryUrl\": \"$well_known_url\"
                    },
                    \"clientId\": \"$OKTA_CLIENT_ID\",
                    \"clientSecret\": \"$OKTA_CLIENT_SECRET\"
                }
            }" \
            --region "$REGION" 2>&1); then
            
            echo -e "${GREEN}✅ OAuth2 credential provider created successfully${NC}"
        else
            echo -e "${RED}❌ Failed to create OAuth2 credential provider${NC}"
            echo "$create_output"
            return 1
        fi
    fi
    
    # Get provider details for configuration update
    local provider_details
    if provider_details=$(aws bedrock-agentcore-control get-oauth2-credential-provider \
        --name "$provider_name" \
        --region "$REGION" 2>&1); then
        
        # Extract ARN using Ubuntu-compatible method
        PROVIDER_ARN=$(extract_provider_arn "$provider_details")
        PROVIDER_NAME="$provider_name"
        
        echo "   Name: $PROVIDER_NAME"
        echo "   ARN: $PROVIDER_ARN"
        
        # Validate that we got an ARN
        if [[ -z "$PROVIDER_ARN" ]]; then
            echo -e "${YELLOW}⚠️  Warning: Could not extract ARN from response${NC}"
            echo "   Response preview: $(echo "$provider_details" | head -c 200)..."
            echo -e "${BLUE}   This may still work, but config update might need manual verification${NC}"
        fi
        
        return 0
    else
        echo -e "${RED}❌ Failed to get provider details${NC}"
        echo "$provider_details"
        return 1
    fi
}

# Function to update configuration files (Ubuntu GNU sed syntax)
update_config_files() {
    echo -e "${BLUE}📝 Updating configuration files${NC}"
    echo -e "${BLUE}===============================${NC}"
    
    # Update dynamic-config.yaml to include OAuth info (without secrets)
    local dynamic_config="${CONFIG_DIR}/dynamic-config.yaml"
    
    if [[ -f "$dynamic_config" ]]; then
        # Create backup for safety
        cp "$dynamic_config" "${dynamic_config}.backup"
        
        # Update OAuth provider section in dynamic config using Ubuntu GNU sed
        if grep -q "oauth_provider:" "$dynamic_config"; then
            # Use sed with different delimiter to handle ARN with / characters
            # Ubuntu GNU sed syntax (no -i '' flag)
            sed -i \
                -e "s|provider_name: \"\"|provider_name: \"$PROVIDER_NAME\"|" \
                -e "s|provider_arn: \"\"|provider_arn: \"$PROVIDER_ARN\"|" \
                -e "s|scopes: \[\]|scopes: [\"$OKTA_SCOPE\"]|" \
                "$dynamic_config"
            
            echo -e "${GREEN}✅ Updated: dynamic-config.yaml${NC}"
            
            # Validate the updates
            if [[ -n "$PROVIDER_ARN" ]]; then
                if grep -q "provider_arn: \"$PROVIDER_ARN\"" "$dynamic_config"; then
                    echo -e "${GREEN}   ✓ Provider ARN updated successfully${NC}"
                else
                    echo -e "${YELLOW}   ⚠️  Provider ARN may not have been updated correctly${NC}"
                    echo -e "${BLUE}   Attempting alternative update method...${NC}"
                    
                    # Alternative method using awk for more precise replacement
                    awk -v name="$PROVIDER_NAME" -v arn="$PROVIDER_ARN" -v scope="$OKTA_SCOPE" '
                    /^  provider_name: ""$/ { print "  provider_name: \"" name "\""; next }
                    /^  provider_arn: ""$/ { print "  provider_arn: \"" arn "\""; next }
                    /^  scopes: \[\]$/ { print "  scopes: [\"" scope "\"]"; next }
                    { print }
                    ' "$dynamic_config" > "${dynamic_config}.tmp" && mv "${dynamic_config}.tmp" "$dynamic_config"
                    
                    # Verify again
                    if grep -q "provider_arn: \"$PROVIDER_ARN\"" "$dynamic_config"; then
                        echo -e "${GREEN}   ✓ Provider ARN updated with alternative method${NC}"
                    else
                        echo -e "${YELLOW}   ⚠️  Manual verification recommended${NC}"
                    fi
                fi
            else
                echo -e "${YELLOW}   ⚠️  Provider ARN was empty - config may need manual update${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️  oauth_provider section not found in dynamic-config.yaml${NC}"
            echo -e "${BLUE}   Creating oauth_provider section...${NC}"
            
            # Add oauth_provider section if missing
            cat >> "$dynamic_config" << EOF

oauth_provider:
  provider_name: "$PROVIDER_NAME"
  provider_arn: "$PROVIDER_ARN"
  domain: "$OKTA_DOMAIN"
  scopes: ["$OKTA_SCOPE"]
EOF
            echo -e "${GREEN}✅ Added oauth_provider section to dynamic-config.yaml${NC}"
        fi
        
        # Clean up backup if update was successful
        rm -f "${dynamic_config}.backup"
    else
        echo -e "${YELLOW}⚠️  dynamic-config.yaml not found, creating new file${NC}"
        
        # Create new dynamic config file
        cat > "$dynamic_config" << EOF
# Dynamic Configuration - Updated by deployment scripts
oauth_provider:
  provider_name: "$PROVIDER_NAME"
  provider_arn: "$PROVIDER_ARN"
  domain: "$OKTA_DOMAIN"
  scopes: ["$OKTA_SCOPE"]
EOF
        echo -e "${GREEN}✅ Created: dynamic-config.yaml${NC}"
    fi
    
    return 0
}

# Function to show next steps
show_next_steps() {
    echo -e "${GREEN}🎉 OAuth2 Setup Complete!${NC}"
    echo -e "${GREEN}=========================${NC}"
    echo ""
    echo -e "${BLUE}📋 What was created:${NC}"
    echo "   • OAuth2 credential provider: $PROVIDER_NAME"
    echo "   • Updated: config/dynamic-config.yaml"
    echo ""
    echo -e "${BLUE}🚀 Next Steps:${NC}"
    echo "   1. Deploy DIY agent: ./deploy-diy.sh"
    echo "   2. Deploy SDK agent: ./deploy-sdk.sh"
    echo "   3. Create runtimes: python3 deploy-diy-runtime.py"
    echo "   4. Create runtimes: python3 deploy-sdk-runtime.py"
    echo ""
    echo -e "${BLUE}💻 Using OAuth in your agents:${NC}"
    echo "   @requires_access_token("
    echo "       provider_name=\"$PROVIDER_NAME\","
    echo "       scopes=[\"$OKTA_SCOPE\"],"
    echo "       auth_flow=\"M2M\""
    echo "   )"
    echo "   async def my_function(*, access_token: str):"
    echo "       # access_token contains your Okta OAuth2 token"
    echo ""
    echo -e "${BLUE}🔒 Security Note:${NC}"
    echo "   • Credentials are stored securely in AgentCore Identity"
    echo "   • No secrets are saved in configuration files"
    echo "   • Tokens are automatically managed and refreshed"
    echo ""
    echo -e "${BLUE}🐧 Ubuntu-specific features:${NC}"
    echo "   • Enhanced JSON parsing with multiple fallback methods"
    echo "   • GNU sed compatibility for configuration updates"
    echo "   • Robust ARN extraction with Python fallback"
    echo "   • Configuration backup and recovery"
}

# Main execution
main() {
    echo -e "${BLUE}Step 2: OAuth2 Credential Provider Setup (Ubuntu)${NC}"
    echo "Run this BEFORE deploying agents"
    echo ""
    
    # Verify prerequisites
    if ! verify_prerequisites; then
        exit 1
    fi
    
    echo ""
    
    # Collect Okta credentials
    if ! collect_okta_credentials; then
        exit 1
    fi
    
    # Create OAuth2 credential provider
    if ! create_oauth_provider; then
        exit 1
    fi
    
    echo ""
    
    # Update configuration files
    if ! update_config_files; then
        exit 1
    fi
    
    echo ""
    
    # Show next steps
    show_next_steps
}

# Run main function
main "$@"