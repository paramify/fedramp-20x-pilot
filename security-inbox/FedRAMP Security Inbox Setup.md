# FedRAMP Security Inbox - Gmail to Slack Automation

Automated Gmail filtering and Slack notifications for the [FedRAMP Security Inbox requirements](https://www.fedramp.gov/docs/fedramp-security-inbox/).

## What It Does

Monitors Gmail for emails from `@fedramp.gov` or `@gsa.gov` addresses (FRR-FSI-10) and automatically:

- **Categorizes** messages by criticality designators (FRR-FSI-02): Emergency, Emergency Test, Important, or General

- **Calculates** response deadlines per FRR-FSI-06 (High: 12 hours, Moderate: 2nd business day 3pm ET, Low: 3rd business day 3pm ET)
- **Sends** Slack notifications with deadlines and required actions
- **Labels** emails in Gmail for tracking and compliance

## Setup

### 1. Create Slack Webhook

**Option A: Using Manifest (Recommended)**
1. Go to [Slack API Apps](https://api.slack.com/apps)
2. Click **Create new app** → **From an app manifest**
3. Select your workspace
4. Copy and paste contents of `slack_app_manifest.json`
5. Click **Create**
6. Go to **Incoming Webhooks** → **Add New Webhook to Workspace**
7. Select your security/alerts channel
8. Copy the webhook URL

**Option B: Manual Setup**
1. Go to [Slack API Apps](https://api.slack.com/apps) 
2. Create new app → From scratch
3. Name it "FedRAMP Email Alerts" and select your workspace
4. Go to **Incoming Webhooks** → Enable
5. Click **Add New Webhook to Workspace**
6. Select your security/alerts channel
7. Copy the webhook URL

### 2. Create Google Apps Script

1. Go to [script.google.com](https://script.google.com)
2. Click **New project**
3. Rename project to "FedRAMP Security Inbox"
4. Delete default code and paste contents of [`Google_App_Script_FedRAMP_Security_Inbox.js`](Google_App_Script_FedRAMP_Security_Inbox.js)

### 3. Initialize

1. Update `CONFIG` values:
```javascript
   slackWebhookUrl: 'YOUR_WEBHOOK_URL', // copied slack webhook
   impactLevel: 'moderate',  // 'high', 'moderate', or 'low'
```
2. Run `setupLabels` (select from dropdown, click Run, creates Gmail labels)
3. Authorize when prompted (Gmail permissions required)

### 4. Test (optional)

1. Run `testSlackWebhook` (verify Slack connection)
2. Set `testMode.enabled: true` in CONFIG
3. Send yourself test emails:
   - `Emergency - Urgent action`
   - `Emergency Test - Quarterly drill`
   - `Important - Policy update`
   - `General inquiry`
4. Apply label `fedramp-test-emails` to test emails
5. Run `checkFedRAMPEmails`
6. Verify Slack notifications in desired channel
7. Run `resetTestEmails` to retest if needed

### 5. Deploy

1. Set `testMode.enabled: false`
2. Save the script
3. Click the **Triggers** icon (clock) in the left sidebar
4. Click **Add Trigger**
5. Configure:
   - Function: `checkFedRAMPEmails`
   - Event source: `Time-driven`
   - Type: `Minutes timer`
   - Interval: `Every 5 minutes`
6. Click **Save**


## Verification Checklist

| Step | Status |
|------|--------|
| Script created and saved | ☐ |
| Webhook URL configured | ☐ |
| Impact level set | ☐ |
| `setupLabels()` run successfully | ☐ |
| `testSlackWebhook()` message received | ☐ |
| Test mode enabled | ☐ |
| Test emails sent and labeled | ☐ |
| `checkFedRAMPEmails()` processed test emails | ☐ |
| Slack notifications received for all 4 types | ☐ |
| Test mode disabled | ☐ |
| Time-based trigger created | ☐ |



## Functions Reference

| Function | Purpose |
|----------|---------|
| `checkFedRAMPEmails` | Main function (set as trigger) |
| `setupLabels` | Create Gmail labels |
| `testSlackWebhook` | Test Slack connection |
| `resetTestEmails` | Reset test emails for retesting |

## Troubleshooting

- Click Execution Log to see console log of script execution
- **No notifications**: Run `testSlackWebhook` to verify webhook
- **Duplicates**: Check `fedramp-notified` label is being applied
- **Wrong priority**: Ensure "Emergency Test" has those words adjacent in subject

## Contributing

For issues, problems, or help: [Contact Paramify](https://www.paramify.com/contact-us)

Initial version: Nov 26, 2025 by Isaac at Paramify 