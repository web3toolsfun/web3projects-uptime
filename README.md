Checks a list of sites every 5 minutes and messages Telegram if one is down.

Stops messaging when the site is back up. Does nothing else — no restarts, no
deploys, no access to any server.

The sites are in the `SITES` secret (whitespace-separated URLs), not in this
repo. Alerting needs `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`.

A site must fail 3 checks over 60 seconds before it counts, so a deploy or a
restart never raises a false alarm.

Then a **second runner repeats the whole check** and only that one messages.
About 4% of runners cannot reach the host at all while the host is up and
serving traffic — their packets are dropped upstream, so every site reads 000
at once. One machine cannot tell that from a real outage, and control probes do
not help: those runs reached `api.github.com` and `cloudflare.com` fine. Two
machines agreeing can. A real outage still alerts, about 2 minutes later.
