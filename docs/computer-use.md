# Computer Use on macOS

Start a task from the conversation menu or Settings → Toolkit → Desktop.
Select a local Ollama model, the paired target Mac, and the apps it may use.
The target Mac presents the request and grants that task access. It may also
remember an exact app scope for the same paired requester and mode. You can
forget that grant in the Desktop pane, and resumed tasks require fresh
approval. Both Macs can see progress. The target handles app interaction, and the Aides server
runs the local model and coordinates the steps.

Grant macOS Accessibility access to use native controls. Grant Screen
Recording only if you want window images. Image tasks need an Ollama model
that accepts images. A text-only task can work from the accessibility tree.
Aides captures a single window and withholds images when it cannot verify
the window, selected controls or protected content.

The model receives the window state after each completed step. It can
switch between granted apps, use supported controls and type or replace
text when it can verify the active field and selection. It can carry a
limited amount of text from previous authorized windows. Previous window
images and controls do not carry forward. Foreground
coordinate operations include pointer movement, left and right clicks,
double-clicks and drag. They require a recent image and show the positions
to review before execution. The model never sends raw commands to macOS.

Background mode is a text-only grant for apps that support non-activating
Accessibility controls. It can observe an open app and interact with its
verified controls while you work elsewhere. Operations that require
foreground keyboard, pointer input, menus or activation need a foreground
task. Native macOS permissions and app behavior determine which controls
are available.

Aides can pause on local input, a changed target window, disconnection,
sleep, or a locked session. The target Mac must be unlocked to allow a new
task or resume one. Use Pause or Stop from either paired device. If Aides
lost contact during a native action, inspect the app before retrying.
Reopening the application or server does not replay the action. A run has
a 40-step budget and an authorization expires after 15 minutes.

## Attach a window to chat

Enable the Appshot shortcut in Toolkit → Desktop. With another app in
front, press Control–Option–Shift–A, then review the captured content in
Aides. The shortcut can include a window screenshot if you enable images.
Remove the capture from the draft if you do not need it.

The selected capture goes to the local Ollama model for a single reply.
Aides records that a window was attached in chat history. The captured
pixels and extracted text are held temporarily for processing. A captured
window does not authorize Computer Use or future app access.

## Verify an interactive session

Use throwaway files and a local Ollama profile. A paired-device integration
fixture checks permission, visible steps, recovery and local model payloads
without operating real apps. Native macOS permissions and app-specific UI
behavior require a signed-in Mac for verification.

1. In TextEdit on the target Mac, open a scratch document with a marked
   sentence and select it. From the other paired Mac start a task requesting
   a particular replacement in TextEdit.
2. On the target approve the app and review the proposed text. Confirm the
   replacement and verify that the resulting window shows the requested text.
3. Add Calculator and start a new task with both apps. Verify that the target
   can switch apps and that the initiating device sees the final result.
4. In an image-enabled foreground session, review a coordinate operation
   using the window preview. Move the pointer or change the focused window
   before a later approved action to confirm that Aides halts on takeover.
5. In a text-only background session, select a supported app and switch to
   a different app. Verify that the target retains its granted scope and
   leaves your foreground app active.
6. Lock the target or disconnect it during work. Verify that the run pauses
   or interrupts and requires a new target approval to continue.
