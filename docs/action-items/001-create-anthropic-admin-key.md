# Create an Anthropic Admin API key for tokmon

The Anthropic API spend provider needs an Admin API key to call the
organization cost report endpoint. tokmon cannot create this for you.

## Important caveat first

**The Admin API is unavailable for individual accounts.** If your Claude
Console account is an individual account (no organization), this provider
will not work until you set up an organization in Console under
Settings -> Organization. If you don't want an organization, disable the
"Anthropic API" provider in tokmon's Settings instead.

## Steps

1. Go to the Claude Console: https://console.anthropic.com/
2. Open Settings -> Admin keys (organization admin role required).
3. Create a new Admin API key. Name it something like `tokmon-readonly`.
   If scopes are offered, usage/cost read access is all tokmon needs.
4. Copy the key (it starts with `sk-ant-admin01-`).
5. Open tokmon's Settings window (menu bar widget -> Settings), paste the
   key into the "Anthropic API" field, and click "Save key".

The key is stored in your macOS Keychain (service `tokmon`), never in a
file. Spend data lags real usage by about 5 minutes and is polled every
15 minutes.

## Verify

Within a minute of saving, the menu should show an "Anthropic API" section
with "Spend (MTD)" matching the Cost page in Console (within the data lag).
If it shows "Admin key rejected", re-check the key; if it shows an HTTP
error and you're on an individual account, see the caveat above.
