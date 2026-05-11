#!/bin/bash
# LM Studio Configuration Script for claw-code
# This script configures claw-code to use a local LM Studio server

set -e

# Configuration
LM_STUDIO_HOST="${LM_STUDIO_HOST:-10.0.0.58}"
LM_STUDIO_PORT="${LM_STUDIO_PORT:-1234}"
MODEL_NAME="${MODEL_NAME:-qwen/qwen3-coder-next}"

# Validate connection
echo "Testing LM Studio connection at http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}..."

if ! curl -s -f "http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}/v1/models" > /dev/null 2>&1; then
    echo "❌ Cannot connect to LM Studio at http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}"
    echo ""
    echo "Please ensure:"
    echo "  1. LM Studio server is running on port ${LM_STUDIO_PORT}"
    echo "  2. The model 'qwen/qwen3-coder-next' (or similar) is loaded"
    echo "  3. Network connectivity exists from this machine to ${LM_STUDIO_HOST}:${LM_STUDIO_PORT}"
    echo ""
    echo "To check from the current machine:"
    echo "  ping ${LM_STUDIO_HOST}"
    echo "  curl http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}/v1/models"
    exit 1
fi

echo "✓ LM Studio server is accessible"

# Set environment variables
echo ""
echo "Setting environment variables..."
export ANTHROPIC_BASE_URL="http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}/v1"
export ANTHROPIC_API_KEY="local-model"

echo "  ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
echo "  ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"

# Display available models
echo ""
echo "Available models on LM Studio:"
curl -s "http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}/v1/models" | jq -r '.data[].id' 2>/dev/null || echo "  (unable to fetch model list)"

echo ""
echo "✓ LM Studio configuration ready!"
echo ""
echo "Usage:"
echo "  source scripts/setup-lm-studio.sh"
echo "  cd rust && ./target/debug/claw prompt 'your question here'"
