Checks a list of sites every 5 minutes and messages Telegram if one is down.

Stops messaging when the site is back up. Does nothing else — no restarts, no
deploys, no access to any server.

The sites are in the `SITES` secret (whitespace-separated URLs), not in this
repo. Alerting needs `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`.

A site must fail 3 checks over 60 seconds before it counts, so a deploy or a
restart never raises a false alarm.
