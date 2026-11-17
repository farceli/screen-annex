# scrcpy integration

Screen Annex uses [Genymobile scrcpy v5.0.1](https://github.com/Genymobile/scrcpy/releases/tag/v5.0.1).
The original client source, its dependencies and their licenses are included
alongside the two desktop patches. The Android server stays at the upstream version.

- macOS · [Cocoa patch](scrcpy-macos-titlebar.patch) adds centered titles, grouped
  window positioning, and file-drop events for the Screen Annex transfer queue.
  The patched client is signed as part of the macOS application bundle.
- Windows · [Win32 patch](scrcpy-windows-events.patch) reports the first displayed
  frame and file drops over stdout and passes title-bar double clicks to the
  Screen Annex host when grouping is enabled. The Windows client links against
  the matching FFmpeg, SDL and libusb DLLs.

The host selects the device and starts the client. The client handles video,
audio and input. Both platforms use the user's separately installed ADB. See
[REBUILDING.md](REBUILDING.md) to rebuild or replace the patched client.
