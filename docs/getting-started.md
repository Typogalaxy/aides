# Run Aides v1 on macOS

Aides targets macOS 15 and later. Install an official DMG when one is available,
or use a Swift 6 toolchain from the repository root:

```sh
swift build
swift run AidesServer serve
```

In another terminal create a one-time pairing code with `swift run AidesServer invite`.
Launch the desktop app using `swift run AidesDesktop` and enter the code for
`http://127.0.0.1:8317`. A packaged app can start the per-user service and pair
locally from its connection screen. The host data directory is
`~/Library/Application Support/Aides` by default; set `AIDES_DATA_DIR` to use a
different protected directory. If a job was interrupted while performing an
external action, check its recorded outcome before retrying.

## Local and cloud execution

Add a local Ollama model in Settings and select it for secretary conversations.
Aides contacts only its loopback inference endpoint and requests Ollama's
explicit local model route. The mock profile can exercise the application
without a model download or an API account. An additional Ollama profile can
review sensitive operations.

OpenAI and Claude API profiles take server-side keys. Official Codex and Claude
Code are optional work adapters. Sign in directly to the official tool as the
host user and supply its absolute path on the server. The app passes explicitly
approved text to the CLI; interactive login, subscription eligibility and
vendor usage limits belong to that official tool. Details are in the
[macOS packaging and host instructions](../scripts/macos/README.md).

The cloud approval screen shows the task or explicitly selected source
snapshot. A cloud analysis task can include up to four memory fields that you
previously marked as shareable and select for that task. Aides checks the scope
again before dispatch. General conversation history stays in the local lane.
The policy rejects protected paths and common credential formats; review the
actual selected contents before authorizing external transmission. No provider
or payment route changes automatically. A running Worker remains associated
with its selected model. After a model interruption, resume that Worker or
create a new one with a separately chosen model.

Code proposals use an explicit set of UTF-8 project paths. The model returns
replacements for review. Apply changes one file at a time from the desktop;
a change to the file since the proposal is a conflict. Use your normal version
control workflow to review and test changes.

## Add another Mac

The HTTP server binds to loopback. Put it behind a private HTTPS connection
that the other Mac can reach and whose certificate it trusts. Generate a
one-time invite on the host or from the Devices settings of an already paired
client. Enter the private HTTPS address and code on the other Mac. See the
[private networking example](../scripts/macos/README.md).

## Use the file Toolkit

On the Mac that owns the files, open Settings → Toolkit and share the specific
folder. Other paired Macs can request directory listings and text reads. To
allow move requests, enable them when sharing the folder. The server keeps the
folder label, device and permissions. The absolute folder path stays on the
target Mac.

Request a file action from the same Toolkit settings pane. The target desktop
must be running and connected to claim it. Moves require confirmation on that
Mac and cannot overwrite an existing destination. Paired Macs can inspect the
request status and result in Toolkit settings. If the server restarts or loses
contact while a request is running, check the target Mac before requesting the
action again.

## Build and verify

Use `swift test` for tests and `python3 scripts/test-server.py /path/to/AidesServer`
for the loopback smoke test on isolated data. The test script uses Python's
standard library and never calls live model accounts. Use
`scripts/macos/package.sh` to create a development DMG from a release build.
Production signing, notarization and the Sparkle update feed require
maintainer credentials.

The iPhone client and QR pairing are in the backlog. This build's tool surface
is currently scoped to project files, reminders, local memory, model tasks and
structured reviews. Outlook, Gmail, and Fastmail are planned as Aides Toolkit
connectors. General desktop control, other third-party connectors, and
autonomous repository-wide coding are outside the current runtime.
