# Toolkit mail accounts

Aides supports Gmail, Outlook and Fastmail accounts configured on the server.
The Toolkit can search mail, read message text, list attachment metadata and
prepare a plain-text draft. Attachment metadata includes filenames, types and
sizes where the provider supplies them.
Sending requires confirmation of the exact sender, recipients, subject and body
on a paired desktop. Drafts stay in Aides until confirmation. Outlook's
accepted response and Fastmail's submission receipt indicate that the provider
accepted the message for submission.

## Configure the host

Place `mail-accounts.json` in the `Toolkit` subdirectory of your Aides data
directory. The default is `~/Library/Application Support/Aides/Toolkit`. This
directory must have mode `0700` and belong to the user running the server.
Give the configuration and token files mode `0600` and the same owner. A
configuration can have multiple accounts, including multiple accounts of the
same provider.

```json
[
  {"id":"personal","provider":"gmail","label":"Personal","address":"you@example.com"},
  {"id":"work","provider":"outlook","label":"Work","address":"you@example.net","allowSend":true},
  {"id":"private","provider":"fastmail","label":"Private","address":"you@example.org","allowSend":true}
]
```

Place each provider credential in `mail-<id>.token` in the same directory.
Use the account's primary mailbox email address, as reported by its provider.
Aides checks this identity before using the credential. Sending requires
`allowSend` in addition to the provider permission. Keep the tokens in the
protected host directory. Drafts and mail tool results can be
viewed on paired devices. In Settings → Toolkit → Mail, the account list shows
whether a credential is available on the host. Add `"allowArchive":true` to enable explicit archiving for
a selected message on one account.

- **Gmail.** Obtain a delegated OAuth access token with the
  `https://www.googleapis.com/auth/gmail.readonly` scope. To enable confirmed
  sending, add `https://www.googleapis.com/auth/gmail.send` when requesting
  authorization. Confirmed archiving requires the
  `https://www.googleapis.com/auth/gmail.modify` scope.
  [Google OAuth and Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- **Outlook.** Obtain a delegated Microsoft Graph access token with
  `User.Read` and `Mail.Read`. Add `Mail.Send` if sending is enabled. The
  token should identify your signed-in mailbox in Microsoft Graph. Confirmed
  archiving requires `Mail.ReadWrite`.
  [Microsoft Graph permissions](https://learn.microsoft.com/en-us/graph/permissions-reference)
- **Fastmail.** Generate a JMAP API token using Fastmail's account settings,
  or provide a Fastmail OAuth access token with mail access. For sending, it
  must also have mail submission access. A token used to archive messages needs
  mail write access. [Fastmail JMAP and authentication](https://www.fastmail.com/dev/)

You can replace an expired static token in its host file. Aides reads the file
before each operation. For local development, `AIDES_MAIL_ACCOUNTS` can supply the same JSON
when the protected configuration file is absent. Each development account can
also reference a specific host environment variable using
`"credentialEnvironment":"AIDES_MAIL_EXAMPLE_TOKEN"`.

## Keep Gmail or Outlook connected with OAuth

For long-running watches, obtain a refresh token through the provider’s
consent flow. Place it in `mail-<id>.oauth.json` next to the account
configuration, with mode `0600`. The fields are `clientID`, `refreshToken`
and `clientSecret` when required by your registered application. Use the mail
scopes listed above and request offline access during consent. Gmail and
Outlook refresh through their official token endpoints. The app’s Microsoft
registration must support the account type served by its common endpoint.

A static `mail-<id>.token` file takes precedence. To enable renewal, remove
that file from the host credential directory once the OAuth configuration is
in place. Fastmail continues to use a static protected token. Account consent
takes place with the provider outside Aides.

Aides caches access tokens in memory and renews them before expiration. It
uses a provider-returned replacement refresh token until the process exits.
The protected OAuth file remains the startup source. If the provider revokes
that grant, reauthorize and replace the file. A provider send or archive
attempt is submitted once after obtaining a token.

[Google offline OAuth access](https://developers.google.com/identity/protocols/oauth2/web-server#offline) ·
[Microsoft token renewal](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow#refresh-the-access-token) ·
[Microsoft refresh token lifetime](https://learn.microsoft.com/en-us/entra/identity-platform/refresh-tokens)

## Confirm delivery

A draft approval is recorded before Aides submits the message. If a crash or
network interruption leaves the outcome uncertain, the draft becomes
interrupted and the same draft ID cannot be sent again. Inspect the provider's
Sent folder before creating a new draft. With Fastmail, a failed submission can
leave a copy in the provider's Drafts folder.

## Archive an Inbox message

Select one message and confirm its preview and mailbox. Archiving removes it
from Inbox. Gmail removes its `INBOX` label. Outlook moves the message from
Inbox to its Archive folder. Fastmail preserves its other labels and moves
Inbox-only messages to Archive. Outlook and Fastmail check whether the selected
message is still in Inbox before changing it. If Fastmail has no Archive folder
and the message only belongs to Inbox, Aides leaves the message in place.

Aides saves the approval before calling the provider. A disrupted operation
leaves a receipt marked interrupted. Check the provider before making another
archive request.

## Preview a text attachment

Open a message and choose **Preview text** next to an eligible attachment.
Aides verifies the selected attachment against the current message and shows
up to 16 KiB of UTF-8 plain text, CSV, tab-separated values, or Markdown as
literal text. The preview stays in Toolkit. Attachments that have a separately
addressable file or blob, a supported media type, and a known size can be
previewed. Other attachments show metadata.

The provider request targets one attachment on Gmail or Microsoft Graph.
Fastmail uses the exact attachment endpoint advertised in its authenticated
JMAP session. Aides recognizes the official Fastmail download origins and
requires the documented JMAP template. Other endpoints leave attachments at
metadata only. [Fastmail JMAP endpoint](https://jmap.io/crash-course/) ·
[JMAP attachment download protocol](https://www.rfc-editor.org/rfc/rfc8620.html#section-6.2)
