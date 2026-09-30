# Camera Pocket for iPhone

A native SwiftUI photo picker for Samsung Wi-Fi cameras, using the protocol in this repository. The user confirmed that the Mac Python client works with their DV300F in **MobileLink** mode. This iOS app still needs a real iPhone/camera test.

## What this version does

- Connect by camera IP, device-description URL, or ContentDirectory service URL.
- Show a scrollable photo/video grid; tap to select, or touch and hold then drag across a range to select/deselect. Select all, Select day, and Clear are available. Selecting a day chooses its unsaved items; items without a camera date appear under Unknown date. Hold your finger near the top or bottom of the grid viewport to scroll while extending the selection. Normal swipes scroll without selecting.
- Show a green badge for items previously imported by this app, including after reconnecting or relaunching.
- Prefer the camera's smallest advertised thumbnail. For photos without one, try a small HTTP range for an embedded JPEG preview before fetching the original for a downsampled tile.
- Download selected original photo and MP4 video resources directly from the camera to Apple Photos, preserving the downloaded bytes and embedded metadata without recompression.
- Show import progress and errors; leave failed/cancelled items selected for retry.
- Browse multiple pages and nested folders, avoid folder cycles and duplicate file URLs.
- Request local-network permission and add-only Photos access.

The Mac does not relay transfers. The app and camera must be on the same reachable Wi-Fi network. This version uses manual connection, so no multicast entitlement is required.

## Install on your iPhone

Requires Xcode and an iPhone running iOS 17 or later.

1. Open `CameraPocket.xcodeproj` in Xcode.
2. Select the **CameraPocket** project, then its app target. Under **Signing & Capabilities**, select your development team. Add your Apple account in Xcode Settings if necessary. Change the bundle identifier if Xcode reports it unavailable.
3. Connect your iPhone by USB, unlock it, and trust the Mac if prompted. Enable Developer Mode on the iPhone if Xcode requests it.
4. Select your iPhone as the run destination and press **Run** (Command-R).
5. Keep the camera in **MobileLink**, using the same working configuration as on the Mac. Join its Wi-Fi network on your iPhone if that is how you connected on the Mac; otherwise join the shared router network. Approve the phone on the camera if prompted. If the camera allows only one client, disconnect the Mac from its Wi-Fi before connecting the phone.
6. Enter the camera's IP address, then tap **Connect to camera**. Allow Local Network access.
7. Tap the desired photos, use **Select day** to choose a camera date, or use **Select all**. Then tap **Download … to Photos** and allow adding photos. Keep the app open until it finishes.

### If the IP address doesn't work

The IP-only route tries the same known description paths as the Python client's manual command. The DV300F may use a different path. On the Mac, run:

```bash
python3 samsung_link.py browse
```

Copy the value printed after **ContentDirectory URL:** (the full `http://…` address). Enter it in the app, enable **Use service URL**, and connect. That URL must still be reachable from the iPhone; addresses can change after reconnecting or changing camera mode.

If permission was denied, enable **Local Network** or **Photos → Add Photos Only** for Camera Pocket in iPhone Settings. If a connection fails immediately after first granting permission, retry Connect.

## Current limits

- No automatic discovery or remote deletion. Video importing supports MP4 resources; Photos must support the video codec.
- Download progress counts files, not bytes. Transfers are foreground operations; locking the phone or changing apps may interrupt them. The app prevents automatic screen locking during an import.
- Saved badges are based on successful imports recorded by this app. They persist across launches for the same camera host, file path, name, size, and media type. They cannot detect imports made outside this app or items later deleted from Photos; a camera address change may also prevent a match.
- Day selection uses dates supplied by the camera's file listing. Files without a date appear under Unknown date; the app does not download originals just to discover their capture dates.
- The grid uses the smallest camera thumbnail when available. If a photo has none, the app asks for the first 128 KiB to try an embedded JPEG thumbnail, then downloads the original for a downsampled preview if needed. Cameras that ignore range requests may still send the full file. Only two preview requests run at once and the decoded cache is bounded.
- Entries advertising only thumbnails are excluded rather than saving a thumbnail as an original. Video entries without an MP4 resource are excluded. Videos without an image preview show an MP4 placeholder; the grid does not download entire movies. Resources explicitly marked as transcoded by the camera are excluded.
- Original bytes and filenames are passed to Photos without recompression or metadata rewriting. This preserves embedded EXIF/GPS/capture timestamps and MP4 metadata present in the served file; it cannot recover metadata removed by the camera or preserve SD-card filesystem timestamps. Photos controls how metadata is displayed. Actual resource quality depends on what the camera exposes; compare an exported unmodified original with the SD-card file.
- No background-transfer guarantee, app icon artwork, or App Store distribution setup in this initial development version.

## Validation

The unsigned iPhone build and protocol fixture checks were run locally. Signing, installation, visual layout on an iPhone, permissions, and a real DV300F transfer still need device verification.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios/CameraPocket.xcodeproj -scheme CameraPocket \
  -sdk iphoneos -configuration Debug -derivedDataPath /tmp/CameraPocket-build \
  CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -module-cache-path /tmp/CameraPocket-swift-cache \
  ios/CameraPocket/CameraClient.swift ios/Tests/main.swift \
  -o /tmp/CameraPocket-protocol-tests
/tmp/CameraPocket-protocol-tests
```

Apple references: [local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [local HTTP configuration](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking), [Photos import](https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource(with:fileurl:options:)).

The repository's MIT license applies; preserve its copyright and permission notice when redistributing.

Recent validation: direct DV300F Wi-Fi photo transfer was confirmed by the user using `http://192.168.11.1:52235/upnp/control/ContentDirectory1` with **Use service URL** enabled. The new MP4 import and drag gesture still require an iPhone test.
