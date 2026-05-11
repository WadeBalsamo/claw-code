#!/usr/bin/env bash
# setup_clawcode_lmstudio.sh
# Setup script for clawcode with LM Studio integration

set -euo pipefail

echo "Setting up clawcode with LM Studio integration..."

# Make sure the clawcode script is executable
chmod +x "/home/wisgood/claw-code/scripts/clawcode"

echo ""
echo "Setup complete!"
echo ""
echo "To use clawcode, you can either:"
echo "1. Add the scripts directory to your PATH by adding this to your ~/.bashrc or ~/.zshrc:"
echo "     export PATH=\"/home/wisgood/claw-code/scripts:\$PATH\""
echo ""
echo "2. Or run it directly with:"
echo "     /home/wisgood/claw-code/scripts/clawcode"
echo ""
echo "Usage examples:"
echo "  clawcode                    # Interactive model selection with memory info"
echo "  clawcode --model MODEL      # Use specific model"
echo "  clawcode --host HOST --port PORT  # Custom LM Studio server"