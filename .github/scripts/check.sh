#!/usr/bin/env bash
# Checks that each site is answering. If one is not, sends a message. If they
# all answer, does nothing at all.
#
# That is the whole program. It watches and it tells you. It never restarts,
# deploys, or logs in to anything — the only request it makes to a site is the
# same plain GET a visitor makes.
#
# While a site is down it messages on every run, and stops by itself once the
# site answers again. No state is kept and nothing needs resetting.
#
# THE SITE LIST IS A SECRET, NOT PART OF THIS FILE.
# `SITES` is whitespace-separated URLs, set in repository secrets. Keeping it
# out of the source means this repo names nothing, so a public repo advertises
# no target — and adding or removing a site is a secret edit, not a commit.
#
# WHY IT CONFIRMS THREE TIMES BEFORE SPEAKING
# A site is briefly unreachable every time it is deployed or restarted —
# measured at about 1 second of 502 for a normal restart. Alerting on that
# would mean a false alarm on every deploy, and an alert you learn to ignore is
# worse than no alert. So a site has to fail three checks spanning about 60
# seconds before it counts. A real outage lasts far longer than that; a restart
# never does.
set -uo pipefail

ROUNDS=3          # consecutive failed rounds before a site counts as down
GAP=30            # seconds between rounds
TIMEOUT=10        # per request

# Unquoted on purpose: splits on spaces AND newlines, so the secret can be
# written either way.
read -r -a SITE_LIST <<<"$(printf '%s' "${SITES:-}" | tr '\n' ' ')"
if [ ${#SITE_LIST[@]} -eq 0 ]; then
  echo "::error::the SITES secret is empty — nothing to check"
  exit 1
fi
echo "checking ${#SITE_LIST[@]} site(s)"

probe() {
  local c
  c=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$1" 2>/dev/null)
  printf '%s' "${c:-000}"
}

# Round 1 checks everything; later rounds re-check only what is still failing,
# so the waiting is shared across sites instead of paid per site.
failing=("${SITE_LIST[@]}")
declare -A code
for round in $(seq 1 "$ROUNDS"); do
  [ "$round" -eq 1 ] || sleep "$GAP"
  still=()
  for url in "${failing[@]}"; do
    c=$(probe "$url")
    code["$url"]=$c
    [ "$c" = "200" ] || still+=("$url")
  done
  failing=("${still[@]:-}")
  [ -n "${failing[0]:-}" ] || failing=()
  if [ ${#failing[@]} -eq 0 ]; then
    echo "all sites answering (confirmed round $round)"
    exit 0
  fi
  echo "round $round: ${#failing[@]} not answering"
done

down=""
for url in "${failing[@]}"; do
  down="$down${down:+, }$url (${code[$url]})"
done
text="DOWN: $down — $(date -u +%H:%M) UTC"
echo "$text"

sent=""
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  curl -sS -m 20 -o /dev/null -w '%{http_code}' \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" | grep -q 200 \
    && sent="$sent telegram" || echo "::warning::telegram send failed"
fi

# WhatsApp free-form text is dropped outside Meta's 24-hour window, so this
# sends a template with one body slot. META_TEMPLATE names a template already
# approved in the Meta account. Unset means WhatsApp is simply skipped.
if [ -n "${META_ACCESS_TOKEN:-}" ] && [ -n "${META_PHONE_ID:-}" ] \
   && [ -n "${META_TO_NUMBER:-}" ] && [ -n "${META_TEMPLATE:-}" ]; then
  body=$(TEXT="$text" TO="$META_TO_NUMBER" TPL="$META_TEMPLATE" \
    LANG="${META_TEMPLATE_LANG:-en}" node -e '
      process.stdout.write(JSON.stringify({
        messaging_product: "whatsapp",
        to: process.env.TO,
        type: "template",
        template: {
          name: process.env.TPL,
          language: { code: process.env.LANG },
          components: [{ type: "body", parameters: [{ type: "text", text: process.env.TEXT }] }],
        },
      }))')
  curl -sS -m 20 -o /dev/null -w '%{http_code}' \
    "https://graph.facebook.com/v21.0/${META_PHONE_ID}/messages" \
    -H "Authorization: Bearer ${META_ACCESS_TOKEN}" \
    -H 'Content-Type: application/json' \
    --data-binary "$body" | grep -q 200 \
    && sent="$sent whatsapp" || echo "::warning::whatsapp send failed"
fi

[ -n "$sent" ] && echo "notified:$sent" || echo "::warning::no channel configured — nothing was sent"
