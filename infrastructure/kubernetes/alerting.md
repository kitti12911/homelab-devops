# Alerting

Alertmanager is configured to send notifications to Telegram.
Routing sends `severity=warning` and `severity=critical` alerts to Telegram. `Watchdog` and `InfoInhibitor` are silenced.

## Setup

### 1. Create a Telegram Bot

1. Open Telegram and message **@BotFather**
2. Send `/newbot` and follow the prompts
3. Save the bot token: `7123456789:AAHxxxxxxxxxxxxxxxxxxxxxxx`

### 2. Get your Chat ID

Send any message to your bot, then open in a browser:

```text
https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
```

Find `"chat": { "id": 123456789 }` in the response — that integer is your chat ID.
If the response is empty, send another message to the bot and refresh.

### 3. Create and encrypt the bot token secret

```bash
sops -e -i infrastructure/kubernetes/app/kube-prometheus-stack-manifests/alertmanager-telegram-secret.enc.yml
```

### 4. Set your chat ID

In `infrastructure/kubernetes/app/kube-prometheus-stack.yml`, replace:

```yaml
chat_id: 0 # TODO: replace with your Telegram chat ID (integer)
```

with your actual integer chat ID (no quotes):

```yaml
chat_id: 7395056934
```

### 5. Commit and push

```bash
git add \
  infrastructure/kubernetes/app/kube-prometheus-stack.yml \
  infrastructure/kubernetes/app/kube-prometheus-stack-manifests/alertmanager-telegram-secret.enc.yml \
  infrastructure/kubernetes/app/kube-prometheus-stack-manifests/secret-generator.yml

git commit -m "feat: add telegram alertmanager notifications"
git push
```

### 6. Test

After ArgoCD syncs, fire a test alert:

```bash
kubectl exec -n observability \
  $(kubectl get pod -n observability -l app.kubernetes.io/name=alertmanager -o name | head -1) \
  -- sh -c 'wget -qO- --header="Content-Type: application/json" --post-data='\''[{"labels":{"alertname":"TestAlert","severity":"warning","namespace":"observability"},"annotations":{"summary":"This is a test alert from Alertmanager"}}]'\'' http://localhost:9093/api/v2/alerts'
```

You should receive a Telegram message within ~30 seconds.

## Alert Routing

| Matcher                                  | Receiver | Notes                             |
| ---------------------------------------- | -------- | --------------------------------- |
| `alertname =~ "Watchdog\|InfoInhibitor"` | null     | Silenced — heartbeat/noise alerts |
| `severity =~ "warning\|critical"`        | telegram | Sent to Telegram                  |
| everything else                          | null     | Dropped                           |

Alerts are grouped by `alertname`, `namespace`, and `severity`.
Repeated alerts fire again after **12 hours** (`repeat_interval`).
A critical alert suppresses the matching warning via inhibit rules.
