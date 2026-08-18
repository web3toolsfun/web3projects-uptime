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
#
# TWO MODES, ONE SCRIPT (see .github/workflows/check.yml)
#   MODE=probe   first runner. Finds the failing sites and says so in the log.
#                It NEVER messages anybody. It writes `down=1` to the step
#                output, which is what starts the second job.
#   MODE=alert   second runner, a different machine on a different network
#                path. It repeats the whole check and messages only if it
#                agrees. This is the default when MODE is unset.
set -uo pipefail

MODE="${MODE:-alert}"
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
echo "mode=$MODE — checking ${#SITE_LIST[@]} site(s)"

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
    # Reaching here in alert mode means the first runner could not reach what
    # this one reaches: the first runner's network was at fault, not the sites.
    if [ "$MODE" = "alert" ]; then
      echo "::notice::second vantage reached every site that the first runner could not — a RUNNER network fault, nothing sent"
    fi
    exit 0
  fi
  echo "round $round: ${#failing[@]} not answering"
done

# ── IS IT THE SITES, OR IS IT US? ───────────────────────────────────────────
# Everything above proves only that THIS RUNNER could not reach them. Those are
# different claims, and the difference has now cost eight false alarms: all
# four sites reported 000 (connection never completed, not an HTTP error),
# every probe burning its full 10s timeout, while the box sat at load ~1
# serving real traffic. The runner's packets were blackholed somewhere between
# Azure and the host — about 4% of runs, a fresh runner IP every time.
#
# Control probes alone DO NOT catch this. They were added on 2026-08-18 and
# three more false alarms followed the same day (runs #127, #142, #150): the
# runner reached api.github.com and cloudflare.com with a 200 each time and
# still could not reach one single host — ours. A control proves the runner has
# *a* network. It cannot prove the runner has a route to US.
#
# Only a SECOND VANTAGE can tell those apart, so the alert now needs two
# independent runners to agree (MODE=probe hands over to MODE=alert). The
# controls stay because they are nearly free and they catch the cheaper case
# early.
#
# Note what none of this suppresses: if the box is genuinely gone, both runners
# see it gone, and the alert goes out as before — about 2 minutes later.
CONTROLS="${CONTROLS:-https://api.github.com https://www.cloudflare.com}"
control_ok=0
for c in $CONTROLS; do
  cc=$(probe "$c")
  echo "control $c -> $cc"
  case "$cc" in 200|30[0-9]) control_ok=1 ;; esac
done

if [ "$control_ok" -eq 0 ]; then
  echo "::warning::this runner cannot reach the public internet either (${#failing[@]} site(s) unreachable, every control also failed) — treating as a RUNNER network fault and sending nothing"
  exit 0
fi

down=""
for url in "${failing[@]}"; do
  down="$down${down:+, }$url (${code[$url]})"
done

# First vantage: hand over to a second runner instead of messaging. The site
# names stay in this log and go no further — the job output is a single digit.
if [ "$MODE" = "probe" ]; then
  echo "first vantage cannot reach: $down"
  echo "handing over to a second runner on a different network path"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "down=1" >> "$GITHUB_OUTPUT"
  exit 0
fi

text="DOWN: $down — $(date -u +%H:%M) UTC (confirmed from two runners)"
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
