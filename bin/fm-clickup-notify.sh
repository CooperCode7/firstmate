#!/usr/bin/env bash
# Post a comment on a ClickUp task so the captain is alerted by email.
# The sealed container's only outbound captain channel: input needed, PR opened,
# next step ready, work finished or failed.
# Usage: fm-clickup-notify.sh <message> [task-id]
#   task-id defaults to $FM_CLICKUP_TASK.
#   CLICKUP_API_KEY authenticates. FM_CLICKUP_MENTION_USER_ID, when set, adds an
#   assignee mention so ClickUp sends its notification mail.
# The token is passed by reference and never echoed, and the response body is
# redacted before it reaches stderr. The body lands in a private temporary file
# rather than a fixed name under the shared temp directory, so concurrent runs
# cannot collide and no pre-created path is trusted.
set -euo pipefail

MESSAGE=${1:-}
TASK=${2:-${FM_CLICKUP_TASK:-}}

if [ -z "$MESSAGE" ] || [ -z "$TASK" ]; then
  echo "usage: fm-clickup-notify.sh <message> [task-id]   (or set FM_CLICKUP_TASK)" >&2
  exit 2
fi
if [ -z "${CLICKUP_API_KEY:-}" ]; then
  echo "fm-clickup-notify: CLICKUP_API_KEY is not set; cannot reach the captain" >&2
  exit 1
fi

payload=$(jq -n \
  --arg text "$MESSAGE" \
  --arg assignee "${FM_CLICKUP_MENTION_USER_ID:-}" \
  '{comment_text: $text, notify_all: true}
   + (if $assignee == "" then {} else {assignee: ($assignee | tonumber)} end)')

body=$(mktemp "${TMPDIR:-/tmp}/fm-clickup-notify.XXXXXX") || {
  echo "fm-clickup-notify: could not create a temporary file for the response" >&2
  exit 1
}
trap 'rm -f "$body"' EXIT INT TERM

status=$(curl -sS -o "$body" -w '%{http_code}' \
  -X POST "https://api.clickup.com/api/v2/task/$TASK/comment" \
  -H "Authorization: $CLICKUP_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "$payload") || {
    echo "fm-clickup-notify: request failed" >&2
    exit 1
  }

case "$status" in
  2*) echo "fm-clickup-notify: posted to task $TASK" ;;
  *)
    echo "fm-clickup-notify: ClickUp returned HTTP $status" >&2
    # The response may echo a credential-shaped string, so it is redacted before
    # reaching stderr. Guarded because under `set -e` an unreadable or absent
    # body would make sed's own status the script's, and GNU and BSD sed differ
    # there, so the failure exit below has to be the one that lands.
    if [ -s "$body" ]; then
      sed -e 's/[A-Za-z0-9_-]\{24,\}/<redacted>/g' "$body" >&2 || true
    fi
    exit 1
    ;;
esac
