# Testing image drag-and-drop on iOS

## Run the build containing this change

These changes are local source changes, not proof that a TestFlight/App Store
build includes them.

1. On your Mac, open `apps/ios/Harness.xcodeproj` in Xcode.
2. Select the **Harness** scheme and your connected iPhone/iPad as the run
   destination. The project targets iOS 26 or newer.
3. If Xcode requests signing setup, choose your development team under the
   Harness target's **Signing & Capabilities**. Enable Developer Mode on the
   device if Xcode asks for it.
4. Press **Run** (Command-R). Sign into Harness and open an existing chat.
   Use a connected desktop host for the final send/agent-read check.

For a layout-only preview without signing in, you can set the scheme's
**Run → Arguments Passed On Launch** to `-demo -route chat:chat-tabs`.
Remove those arguments for real uploads: demo mode does not verify delivery to
an agent.

## Fastest physical-device check: screenshot Harness itself

Use harmless test content, not a screenshot containing credentials or private
information.

1. Open an existing Harness chat and type `Describe this screenshot` without
   sending it.
2. Take a screenshot while Harness is visible.
3. When the floating screenshot thumbnail appears, **press and hold it, then
   drag** it into the chat. Try both the transcript and directly over the text
   editor. Do not just tap the thumbnail, which opens the screenshot editor.
4. While hovering, look for **Drop images to attach** and the highlighted border.
5. Release. The screenshot should appear in the composer's attachment strip.
   The draft text should remain unchanged, and nothing should send automatically.
6. Remove it with its attachment remove button, then repeat the drop.
7. Tap Send. Check that the sent message shows the image and ask the agent to
   describe a distinctive detail in it. This last step checks the real upload
   and agent image-read path, not only the preview.

If your iOS screenshot settings open a full-screen preview instead of a floating
thumbnail, disable full-screen screenshot previews in the screen-capture
settings, or save the screenshot and test dragging it from Photos instead.
The availability of a draggable system screenshot thumbnail depends on iOS.

## Other manual cases

| Case | How to exercise it | Expected result |
| --- | --- | --- |
| Photos / Files | Long-press an image and start dragging. Keep holding with one finger; use another finger to switch back to Harness, then release over the chat. On iPad, use side-by-side windows if convenient. | Attachment preview appears; no automatic send. |
| Multiple images | Start a drag from a source that supports gathering multiple selected images. | All supported images appear in source order. |
| Existing content | Type a draft, attach one image, then drop another. | Draft and old attachment remain; new attachment is appended. |
| Keyboard visible | Focus the editor, then drop an image directly onto its text. | Image becomes an attachment, not inline text or a replacement for the draft. |
| Cancel | Hover with an image, then drag away and cancel the drag. | Highlight clears; draft and attachments are unchanged. |
| Repeated image | Drop the same image twice and remove only one preview. | Separate attachments; removing one does not remove the other. |
| Portrait / landscape | Repeat with the phone rotated and with the keyboard up/down. | Composer and previews remain usable. |
| Invalid / oversized image | Use an unreadable image or one over 24 MiB from Files, if the source permits dragging it. | Visible import error; existing draft/attachments are preserved. |
| Slow source | Drag a cloud-backed image that needs downloading. | Import feedback appears; a second import/send must not race incomplete staging. |
| Agent responding | Drop while a response is streaming, then explicitly send. | Normal queued-attachment behavior on a host supporting message queues. |
| Offline delivery | After staging, disconnect networking, then explicitly send. | Existing offline/delivery behavior is used; no silent claim of delivery. Reconnect and verify actual receipt. |

## Repeat the automated checks

Choose an available simulator with `xcrun simctl list devices available`, then
substitute its UUID for `SIMULATOR_UDID`:

```sh
xcodebuild test \
  -project apps/ios/Harness.xcodeproj \
  -scheme Harness \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /tmp/harness-ios-image-drop-build \
  -only-testing:HarnessTests/ImageDropTests \
  -only-testing:HarnessTests/ImageDropEdgeCaseTests \
  -only-testing:HarnessTests/ImageDropLifecycleTests \
  -only-testing:HarnessTests/ComposerEditorTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

The focused suite contains 22 tests: the six original drop tests, fourteen
additional edge/lifecycle tests, and the existing composer marked-text and
clipboard-image tests.
It covers real `NSItemProvider` data and file imports, JPEG byte preservation,
animated GIF frame preservation, TIFF-to-JPEG conversion, exact 24 MiB limits,
failed providers/alternate representations, mixed text/image drags, duplicates,
slow loading, draft isolation, canceled hover, native editor selection, and the
actual SwiftUI editor's drop-delegate wiring.

These are simulator unit/hosted-view tests. They do **not** synthesize the
system screenshot-thumbnail gesture or prove live relay/agent receipt. Use the
physical-device steps above for those checks.
