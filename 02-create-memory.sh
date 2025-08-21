#!/bin/bash

# AgentCore Memory Resource Creation - Ubuntu Linux version
# Creates memory resource for conversation storage and retrieval

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "🧠 Creating AgentCore Memory Resource (Ubuntu Linux)..."
echo "====================================================="

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration with fallback methods for Ubuntu
load_config_value() {
    local key="$1"
    local default_value="$2"
    local config_file="$PROJECT_ROOT/config/static-config.yaml"
    
    if [ -f "$config_file" ]; then
        # Try yq first if available
        if command -v yq &> /dev/null; then
            local value=$(yq eval ".$key" "$config_file" 2>/dev/null || echo "null")
            if [ "$value" != "null" ] && [ "$value" != "" ]; then
                echo "$value"
                return
            fi
        fi
        
        # Fallback to grep/sed method for Ubuntu
        local value=$(grep -E "^\s*${key##*.}:" "$config_file" | head -1 | sed 's/.*:[[:space:]]*["'\'']*\([^"'\'']*\)["'\'']*$/\1/' | xargs)
        if [ -n "$value" ]; then
            echo "$value"
        else
            echo "$default_value"
        fi
    else
        echo "$default_value"
    fi
}

if [ -f "$PROJECT_ROOT/config/static-config.yaml" ]; then
    MEMORY_NAME=$(load_config_value "memory.name" "bac_agent_memory")
    MEMORY_DESCRIPTION=$(load_config_value "memory.description" "BAC Agent conversation memory storage")
    EVENT_EXPIRY_DAYS=$(load_config_value "memory.event_expiry_days" "90")
    REGION=$(load_config_value "aws.region" "us-east-1")
else
    echo -e "${YELLOW}⚠️ Configuration file not found, using defaults${NC}"
    MEMORY_NAME="bac_agent_memory"
    MEMORY_DESCRIPTION="BAC Agent conversation memory storage"
    EVENT_EXPIRY_DAYS="90"
    REGION="us-east-1"
fi

echo -e "${BLUE}📋 Memory Configuration:${NC}"
echo "   • Name: $MEMORY_NAME"
echo "   • Description: $MEMORY_DESCRIPTION"
echo "   • Event Expiry: $EVENT_EXPIRY_DAYS days"
echo "   • Region: $REGION"
echo ""

# Check if memory already exists
echo -e "${BLUE}🔍 Checking for existing memory resource...${NC}"
EXISTING_MEMORY=$(python3 -c "
import json
import sys
from bedrock_agentcore.memory import MemoryClient

try:
    client = MemoryClient(region_name='$REGION')
    memories = client.list_memories()
    
    for memory in memories:
        if memory.get('name') == '$MEMORY_NAME':
            print(json.dumps(memory, default=str))
            exit(0)
    
    print('null')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    exit(1)
" 2>/dev/null)

if [ "$EXISTING_MEMORY" != "null" ] && [ -n "$EXISTING_MEMORY" ]; then
    echo -e "${GREEN}✅ Memory resource already exists${NC}"
    MEMORY_ID=$(echo "$EXISTING_MEMORY" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('id', ''))")
    MEMORY_STATUS=$(echo "$EXISTING_MEMORY" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status', ''))")
    
    echo "   • Memory ID: $MEMORY_ID"
    echo "   • Status: $MEMORY_STATUS"
    
    if [ "$MEMORY_STATUS" != "AVAILABLE" ] && [ "$MEMORY_STATUS" != "ACTIVE" ]; then
        echo -e "${YELLOW}⚠️ Memory resource exists but is not available (status: $MEMORY_STATUS)${NC}"
        echo "   Waiting for memory to become available..."
        
        # Wait for memory to be ready
        python3 -c "
from bedrock_agentcore.memory import MemoryClient
import time
import sys

client = MemoryClient(region_name='$REGION')
memory_id = '$MEMORY_ID'

print('⏳ Waiting for memory resource to be ready...')
for i in range(60):  # Wait up to 5 minutes
    try:
        memories = client.list_memories()
        for memory in memories:
            if memory.get('id') == memory_id:
                status = memory.get('status', '')
                if status in ['AVAILABLE', 'ACTIVE']:
                    print(f'✅ Memory resource is now {status}')
                    exit(0)
                else:
                    print(f'   Status: {status} (attempt {i+1}/60)')
                    time.sleep(5)
                    break
    except Exception as e:
        print(f'   Error checking status: {e}')
        time.sleep(5)

print('❌ Memory resource did not become available within timeout')
exit(1)
"
    fi
else
    echo -e "${BLUE}🚀 Creating new memory resource...${NC}"
    
    # Create memory resource with basic configuration
    MEMORY_RESULT=$(python3 -c "
import json
import sys
from bedrock_agentcore.memory import MemoryClient

try:
    client = MemoryClient(region_name='$REGION')
    
    # Create memory resource first (we can add strategies later)
    memory = client.create_memory(
        name='$MEMORY_NAME',
        description='$MEMORY_DESCRIPTION',
        event_expiry_days=$EVENT_EXPIRY_DAYS
    )
    
    print(json.dumps(memory, default=str))
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    exit(1)
")
    
    if [ $? -eq 0 ]; then
        MEMORY_ID=$(echo "$MEMORY_RESULT" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('id', ''))")
        echo -e "${GREEN}✅ Memory resource created successfully${NC}"
        echo "   • Memory ID: $MEMORY_ID"
        
        # Wait for memory to be available
        echo -e "${BLUE}⏳ Waiting for memory resource to become available...${NC}"
        python3 -c "
from bedrock_agentcore.memory import MemoryClient
import time
import sys

client = MemoryClient(region_name='$REGION')
memory_id = '$MEMORY_ID'

for i in range(60):  # Wait up to 5 minutes
    try:
        memories = client.list_memories()
        for memory in memories:
            if memory.get('id') == memory_id:
                status = memory.get('status', '')
                if status in ['AVAILABLE', 'ACTIVE']:
                    print(f'✅ Memory resource is {status} and ready')
                    exit(0)
                else:
                    print(f'   Status: {status} (attempt {i+1}/60)')
                    time.sleep(5)
                    break
    except Exception as e:
        print(f'   Error checking status: {e}')
        time.sleep(5)

print('❌ Memory resource did not become available within timeout')
exit(1)
"
    else
        echo -e "${RED}❌ Failed to create memory resource${NC}"
        echo "$MEMORY_RESULT"
        exit 1
    fi
fi

# Update dynamic configuration with memory ID
echo ""
echo -e "${BLUE}📝 Updating dynamic configuration...${NC}"

# Ensure dynamic config exists
if [ ! -f "$PROJECT_ROOT/config/dynamic-config.yaml" ]; then
    echo "# Dynamic configuration generated by deployment scripts" > "$PROJECT_ROOT/config/dynamic-config.yaml"
fi

# Update or add memory section
python3 -c "
import yaml
import sys
from datetime import datetime

config_file = '$PROJECT_ROOT/config/dynamic-config.yaml'

try:
    # Load existing config
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f) or {}
    
    # Update memory section with comprehensive details
    config['memory'] = {
        'id': '$MEMORY_ID',
        'name': '$MEMORY_NAME', 
        'region': '$REGION',
        'status': 'available',
        'event_expiry_days': $EVENT_EXPIRY_DAYS,
        'created_at': datetime.now().isoformat(),
        'description': '$MEMORY_DESCRIPTION'
    }
    
    # Write updated config maintaining existing structure
    with open(config_file, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False, indent=2)
    
    print('✅ Dynamic configuration updated with memory details')
    print(f'   • Memory ID: $MEMORY_ID')
    print(f'   • Memory Name: $MEMORY_NAME')
    print(f'   • Region: $REGION')
    print(f'   • Event Expiry: $EVENT_EXPIRY_DAYS days')
    
except Exception as e:
    print(f'❌ Failed to update configuration: {e}')
    sys.exit(1)
"

# Fix quote consistency: Convert single quotes to double quotes for empty strings
# Ubuntu GNU sed syntax (no -i '' flag needed)
echo -e "${BLUE}🔧 Ensuring quote consistency in dynamic-config.yaml...${NC}"
sed -i "s/: ''/: \"\"/g" "$PROJECT_ROOT/config/dynamic-config.yaml"

# Fix the scopes array format to maintain consistency
# Ubuntu GNU sed syntax with proper escaping
echo -e "${BLUE}🔧 Fixing scopes array format...${NC}"

# Create a temporary file for complex sed operations on Ubuntu
TEMP_FILE=$(mktemp)
cp "$PROJECT_ROOT/config/dynamic-config.yaml" "$TEMP_FILE"

# Remove any existing "- api" line under scopes using awk (more reliable on Ubuntu)
awk '
/^  scopes:$/ {
    print $0
    in_scopes = 1
    next
}
in_scopes && /^  - api$/ {
    next
}
in_scopes && /^[^ ]/ {
    in_scopes = 0
}
{print}
' "$TEMP_FILE" > "$PROJECT_ROOT/config/dynamic-config.yaml"

# Then ensure scopes line has the proper JSON array format
sed -i 's/^  scopes:$/  scopes: ["api"]/' "$PROJECT_ROOT/config/dynamic-config.yaml"

# Clean up
rm -f "$TEMP_FILE"

# Verify memory resource is accessible
echo ""
echo -e "${BLUE}🧪 Testing memory resource access...${NC}"
python3 -c "
from bedrock_agentcore.memory import MemoryClient
import sys

try:
    client = MemoryClient(region_name='$REGION')
    memories = client.list_memories()
    
    memory_found = False
    for memory in memories:
        if memory.get('id') == '$MEMORY_ID':
            memory_found = True
            status = memory.get('status', 'unknown')
            strategies = memory.get('strategies', [])
            
            print(f'✅ Memory resource verified:')
            print(f'   • ID: {memory.get(\"id\")}')
            print(f'   • Name: {memory.get(\"name\")}')
            print(f'   • Status: {status}')
            print(f'   • Strategies: {len(strategies)} configured')
            
            if strategies:
                for i, strategy in enumerate(strategies):
                    strategy_type = strategy.get('type', 'unknown')
                    print(f'     - Strategy {i+1}: {strategy_type}')
            
            break
    
    if not memory_found:
        print('❌ Memory resource not found in list')
        exit(1)
        
except Exception as e:
    print(f'❌ Failed to verify memory resource: {e}')
    exit(1)
"

echo ""
echo -e "${GREEN}🎉 AgentCore Memory Resource Setup Complete!${NC}"
echo "==========================================="
echo -e "${GREEN}✅ Memory ID: $MEMORY_ID${NC}"
echo -e "${GREEN}✅ Configuration updated in: config/dynamic-config.yaml${NC}"
echo -e "${GREEN}✅ Memory resource ready for agent use${NC}"
echo ""
echo -e "${BLUE}📋 Summary:${NC}"
echo "   • Agents can now store and retrieve conversation context"
echo "   • No automatic strategies configured - pure conversation storage"
echo "   • Events expire after $EVENT_EXPIRY_DAYS days"
echo "   • Both DIY and SDK agents will use this memory resource"
echo ""
echo -e "${BLUE}📋 Ubuntu-specific adaptations:${NC}"
echo "   • GNU sed syntax used (no -i '' flag)"
echo "   • Enhanced config parsing with fallbacks"
echo "   • awk used for complex text processing"
echo "   • Improved error handling and color output"
echo ""
echo -e "${BLUE}🔍 To verify memory status later:${NC}"
echo "   aws bedrock-agentcore-control list-memories --region $REGION"