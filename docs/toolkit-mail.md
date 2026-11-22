# Toolkit mail accounts

Aides supports Gmail, Outlook and Fastmail accounts configured on the server.
The Toolkit can search mail, read message text and prepare a plain-text draft.
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
Aides checks this identity before using the credential. With `allowSend`
omitted, mail stays read-only even if the provider token can send. Keep the
tokens in the protected host directory. Drafts and mail tool results can be
viewed on paired devices. In Settings → Toolkit → Mail, the account list shows
whether a credential is available on the host.

- **Gmail.** Obtain a delegated OAuth access token with the
  `https://www.googleapis.com/auth/gmail.readonly` scope. To enable confirmed
  sending, add `https://www.googleapis.com/auth/gmail.send` when requesting
  authorization. [Google OAuth and Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- **Outlook.** Obtain a delegated Microsoft Graph access token with
  `User.Read` and `Mail.Read`. Add `Mail.Send` if sending is enabled. The
  token should identify your signed-in mailbox in Microsoft Graph.
  [Microsoft Graph permissions](https://learn.microsoft.com/en-us/graph/permissions-reference)
- **Fastmail.** Generate a JMAP API token using Fastmail's account settings,
  or provide a Fastmail OAuth access token with mail access. For sending, it
  must also have mail submission access. [Fastmail JMAP and authentication](https://www.fastmail.com/dev/)

You can replace an expired token in its host file. Aides reads the file for
each operation. OAuth sign-in and token refresh currently take place outside
Aides. For local development, `AIDES_MAIL_ACCOUNTS` can supply the same JSON
when the protected configuration file is absent. Each development account can
also reference a specific host environment variable using
`"credentialEnvironment":"AIDES_MAIL_EXAMPLE_TOKEN"`.

## Confirm delivery

A draft approval is recorded before Aides submits the message. If a crash or
network interruption leaves the outcome uncertain, the draft becomes
interrupted and the same draft ID cannot be sent again. Inspect the provider's
Sent folder before creating a new draft. With Fastmail, a failed submission can
leave a copy in the provider's Drafts folder.
