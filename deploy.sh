#!/usr/bin/env bash
set -e

# Cleanup on exit
trap 'rm -f ~/.ssh/deploy_key' EXIT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Validate required environment variables
for var in TOOL_NAME SERVER_PATH HEALTH_URL SSH_HOST SSH_USER SSH_PRIVATE_KEY SLACK_WEBHOOK_URL; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: Required environment variable $var is not set${NC}"
        exit 1
    fi
done

echo -e "${GREEN}Deploying ${TOOL_NAME}...${NC}"

# Setup SSH
mkdir -p ~/.ssh
echo "$SSH_PRIVATE_KEY" > ~/.ssh/deploy_key
chmod 600 ~/.ssh/deploy_key

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/deploy_key"
SSH_CMD="ssh $SSH_OPTS ${SSH_USER}@${SSH_HOST}"

# Test SSH connection
echo "Testing SSH connection..."
$SSH_CMD "echo 'SSH connection successful'"

# Save current commit for rollback
echo "Saving current commit for potential rollback..."
OLD_COMMIT=$($SSH_CMD "cd ${SERVER_PATH} && git rev-parse HEAD")
echo "Current commit: ${OLD_COMMIT}"

# Deploy
echo "Pulling latest changes..."
$SSH_CMD "cd ${SERVER_PATH} && git pull origin main"

if [ "$BUILD" = "true" ]; then
    echo "Building Docker images..."
    $SSH_CMD "cd ${SERVER_PATH} && docker compose build"
else
    echo "Pulling Docker images..."
    $SSH_CMD "cd ${SERVER_PATH} && docker compose pull"
fi

echo "Starting containers..."
$SSH_CMD "cd ${SERVER_PATH} && docker compose up -d --remove-orphans"

# Health check with retry loop — some services (e.g. Grafana v12) cold-start
# for 60-90s, longer than a single 30s wait. Poll every 10s for up to 3 minutes.
wait_for_health() {
    local max_wait=180
    local interval=10
    local elapsed=0
    echo "Polling health check: ${HEALTH_URL} (max ${max_wait}s)"
    while [ $elapsed -lt $max_wait ]; do
        sleep $interval
        elapsed=$((elapsed + interval))
        if curl -sf --max-time 10 "${HEALTH_URL}" > /dev/null; then
            echo -e "${GREEN}Health check passed after ${elapsed}s${NC}"
            return 0
        fi
        echo "  still waiting (${elapsed}s / ${max_wait}s)..."
    done
    echo -e "${RED}Health check still failing after ${max_wait}s${NC}"
    return 1
}

if wait_for_health; then
    echo -e "${GREEN}Deployment successful!${NC}"
    exit 0
fi

# Health check failed - rollback
echo -e "${RED}Initiating rollback...${NC}"

echo "Rolling back to commit: ${OLD_COMMIT}"
$SSH_CMD "cd ${SERVER_PATH} && git reset --hard ${OLD_COMMIT}"
$SSH_CMD "cd ${SERVER_PATH} && docker compose up -d --remove-orphans"

# Same retry logic for rollback health
ROLLBACK_HEALTHY=true
if ! wait_for_health; then
    ROLLBACK_HEALTHY=false
    echo -e "${RED}Rollback also failed health check!${NC}"
fi

# Send Slack notification
NEW_COMMIT=$($SSH_CMD "cd ${SERVER_PATH} && git log -1 --format='%h' origin/main")
WORKFLOW_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

if [ "$ROLLBACK_HEALTHY" = true ]; then
    SLACK_MESSAGE=$(cat <<EOF
*Deployment Failed - Rolled Back*

*Tool:* ${TOOL_NAME}
*Failed Commit:* \`${NEW_COMMIT}\`
*Rolled Back To:* \`${OLD_COMMIT}\`
*Workflow:* ${WORKFLOW_URL}
EOF
)
else
    SLACK_MESSAGE=$(cat <<EOF
*CRITICAL: Deployment Failed - Rollback Also Failed*

*Tool:* ${TOOL_NAME}
*Failed Commit:* \`${NEW_COMMIT}\`
*Attempted Rollback To:* \`${OLD_COMMIT}\`
*Workflow:* ${WORKFLOW_URL}

*Manual intervention required!*
EOF
)
fi

curl -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"${SLACK_MESSAGE}\"}" \
    "${SLACK_WEBHOOK_URL}"

echo -e "${RED}Deployment failed. Slack notification sent.${NC}"
exit 1
