#!/usr/bin/env bash
# fm-pin-pipeline-model.sh - pin no-mistakes' Claude agents to an explicit model.
#
# Usage: fm-pin-pipeline-model.sh [config-path]
#
# Appends an agent_config block to no-mistakes' config.yaml (default
# $HOME/.no-mistakes/config.yaml). No-ops when the file is absent or already
# declares agent_config at column 0.
set -euo pipefail

CONFIG=${1:-$HOME/.no-mistakes/config.yaml}

if [ -f "$CONFIG" ] && ! grep -qE '^agent_config:' "$CONFIG"; then
  printf '\nagent_config:\n  claude:\n    model: "opus[1m]"\n    effort: xhigh\n' >> "$CONFIG"
  echo "pinned no-mistakes claude agents to opus[1m]/xhigh in $CONFIG"
fi
