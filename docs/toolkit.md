# Aides Toolkit

Open Settings → Toolkit to use the available categories. Toolkit tools are
actions. Resources identify what an action can access and where it runs.
Connectors bind a service or device to an explicitly selected resource.
Triggers create notices or queued work according to their own schedules.

| Category | Available actions |
| --- | --- |
| Files | Share a folder on a paired Mac, list and read, and request moves or text creates and replacements. A mounted NAS volume can be shared as a folder if it supports the required filesystem operations. |
| Commands | Run a fixed executable and argument list configured by the host operator for a selected project. Review and confirm before starting. Inspect output, status and exit code, or request that a running command stop. |
| Mail | Use configured Gmail, Outlook and Fastmail accounts for search, read, attachment metadata and bounded text previews, drafts, confirmed sending and confirmed archiving. Mail watches can notify you of new matching messages. |
| Calendar | On the current Mac, select a calendar, view events and availability, and confirm creating or editing eligible events after granting macOS Calendar access. |
| Contacts | On the current Mac, grant macOS Contacts access and search a selected account by name, and confirm the chosen email change. |
| Aides data | Query scoped memory, projects, project files, schedules and reminder history. Create or manage reminders with Aides scheduling. |
| GitHub | Read Issues, pull requests and workflow runs for a configured repository. With an approved write scope, prepare and confirm creating an Issue or a same-repository PR. |
| Web sources | Monitor explicitly added RSS or Atom feeds and public HTTPS pages. Open the configured source in the browser yourself. |
| Desktop | Grant a local Worker access to chosen apps on a paired Mac. Use multi-step interaction, one-shot window attachments, approval and handoff. [Computer Use guide](computer-use.md) |
| Audit | Review recent request outcomes for paired devices. Request and response contents stay out of the audit. |
| Notifications | Receive in-app notices from Aides reminders and source watches. Enable generic macOS notifications individually on each desktop. |

## Agent workflow

Select a folder for one conversation turn or one local analysis Worker.
Only the list, read and authorized move tools for that folder can be proposed.
Confirm the proposal to enqueue it. When configured, the local safety model
reviews Agent-proposed moves. The target Mac additionally confirms moves and
text changes. To use file output in a local analysis Worker, select
a completed read or listing as its input. The server rechecks that the folder
grant still exists when it builds the model request. Aides data query results
can also be selected as local Worker inputs. Cloud Workers cannot accept
these Toolkit inputs. A local conversation or Worker can instead select an
available send-enabled mailbox and propose a plain-text draft. Review the
recipients and content before preparing it in Toolkit. The mail draft then
requires a separate send confirmation. Calendar, Contacts and window data stay on the Mac
displaying them. Existing recurring calendar events and events with guests
are handled in system Calendar.

Text file creation requires an unused path. Replacement requires the expected
current text and only applies if it still matches the file. These operations
require a folder's separate text-write grant. Older desktop clients continue
to see and claim list, read and move jobs.

If a file, command or external action is interrupted, check the target outcome
before starting a new action. A retry using the same invocation ID retrieves
the existing receipt while its details are retained. An expired receipt still
prevents replay.

## Configure the server

In the Mac Studio's Aides data directory (default
`~/Library/Application Support/Aides`), create a `Toolkit` directory with
permissions `0700`. Configuration and credential files in it must be owned by
the server user, with no group or other permissions, for example `0600`.
Use the provider-specific setup in [Mail](toolkit-mail.md) and
[GitHub](toolkit-github.md). The server reads these files directly for packaged
and developer launches. The contents of credential files are available to
the relevant connector only. No Toolkit action returns a credential to a
model or desktop.

For terminal commands, place an array of profiles in `Toolkit/commands.json`:

```json
[
  {
    "id": "swift-version",
    "label": "Check the Swift version",
    "projectID": "YOUR-EXISTING-PROJECT-UUID",
    "executable": "/usr/bin/swift",
    "arguments": ["--version"],
    "timeoutSeconds": 20
  }
]
```

Commands run as the server user, with the designated project's working
directory and an isolated home environment. The operator supplies fixed
arguments. The desktop shows the executable and arguments before confirmation.
Keep credentials out of those fields. The process retains the macOS permissions
of the server account.
Only configure trusted executables and project code. Output is limited to
64 KiB. For a project that uses Git, you can configure a fixed
`/usr/bin/git` profile for operations such as reviewing a diff. When stopping a command, verify any external effects it may already
have initiated.

## Source and notification behavior

Public sources use HTTPS and public IPv4 only. They do not follow redirects.
The first successful check establishes a baseline and future updates produce
generic notices. Mail watches apply a selected search to a configured account
and examine up to ten matching messages per check. Message text stays out of
watch notices. Calendar and Contacts access is managed by macOS on each
desktop. The first notification sync establishes a baseline for the local
desktop so it does not replay older notices.
