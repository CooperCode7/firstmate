#!/usr/bin/env bash
# Container entrypoint for the sealed firstmate image.
# Runs before every start so host guardrail edits propagate on restart:
#   1. copy guardrail material out of the read-only /seed/claude mount
#   2. write this container's MCP server config from injected tokens
#   3. point the away-mode alarm at the ClickUp notifier
#   4. start a detached tmux session for the fleet
# Credentials are never copied from the seed mount and never printed.
set -euo pipefail

SEED=/seed/claude
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
FM_HOME=${FM_HOME:-$HOME/fmhome}

mkdir -p "$CLAUDE_DIR" "$FM_HOME/config"

# Guardrails only, named one by one: session transcripts, history, and the
# host's credentials are never among them, so this container authenticates as
# itself. Nothing here removes an existing login, because an interactive
# `claude` login inside the container writes its credentials into this same
# directory and must survive a restart.
if [ -d "$SEED" ]; then
  synced=
  for item in CLAUDE.md settings.json settings.local.json keybindings.json agents skills plugins; do
    [ -e "$SEED/$item" ] || continue
    rm -rf "${CLAUDE_DIR:?}/$item"
    cp -R "$SEED/$item" "$CLAUDE_DIR/$item"
    synced="$synced $item"
  done
  if [ -n "$synced" ]; then
    echo "entrypoint: synced from $SEED:$synced"
  else
    # An empty or wrong mount would otherwise look identical to a good one.
    echo "entrypoint: $SEED holds none of the expected guardrail files; check the mount" >&2
  fi
else
  echo "entrypoint: no $SEED mount; using whatever already lives in $CLAUDE_DIR" >&2
fi

# MCP servers are declared here rather than copied, so no host token is read.
# Each server is installed in the image, so starting one needs no package
# registry and the egress allowlist stays closed to npm and PyPI.
mcp_config=$HOME/.claude.json
tmp=$(mktemp)
[ -f "$mcp_config" ] || printf '{}\n' > "$mcp_config"
jq '.mcpServers = ((.mcpServers // {})
      | .clickup = {command: "clickup-mcp",
                    env: {CLICKUP_API_KEY: env.CLICKUP_API_KEY,
                          CLICKUP_TEAM_ID: env.CLICKUP_TEAM_ID}}
      | .motherduck = {command: "mcp-server-motherduck",
                       args: ["--db-path", "md:", "--read-only"],
                       env: {motherduck_token: env.MOTHERDUCK_TOKEN}})' \
  "$mcp_config" > "$tmp" && mv "$tmp" "$mcp_config"

if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git 2>/dev/null || echo "entrypoint: gh auth setup-git failed; check GH_TOKEN scope" >&2
fi

# Linux has no default alert channel, so away-mode escalations go to ClickUp.
if [ -n "${FM_CLICKUP_TASK:-}" ] && [ ! -e "$FM_HOME/config/wedge-alarm" ]; then
  printf 'command:/opt/firstmate/bin/fm-clickup-notify.sh\n' > "$FM_HOME/config/wedge-alarm"
fi

tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
echo "entrypoint: fleet session ready - attach with: docker compose exec firstmate tmux attach -t firstmate"

exec "$@"
