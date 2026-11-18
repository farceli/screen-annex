# Windows HarmonyOS components

- LibVLCSharp.WinUI 3.10.2 is provided by VideoLAN under LGPL-2.1-or-later. The accompanying license is in this directory. The exact source revision is `3082c09ca955131c705fc4767fde03e9c4a14999`. Its source and the matching Screen Annex source are available alongside this Windows download in `Screen-Annex-Windows-corresponding-source.zip`.
- SharpDX, SharpDX.DXGI and SharpDX.Direct3D11 4.2.0 are provided under the accompanying MIT license.
- The app obtains the native VideoLAN.LibVLC.Windows 3.0.21 package from the official NuGet feed on first use. The publisher provides the [package](https://www.nuget.org/packages/VideoLAN.LibVLC.Windows/3.0.21) and [VLC source](https://download.videolan.org/pub/videolan/vlc/3.0.21/).

The managed VLC wrapper is loaded as a separate DLL. With the app closed, users may replace that DLL with an interface-compatible rebuild. Users may modify LGPL components for their own use and reverse engineer the combined work to debug those modifications under the applicable LGPL terms.
