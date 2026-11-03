# CRS Memories

Turn your photos into a short video montage on iPhone, iPad and Apple Watch, from Code Rendering Studio.

## What it does

- **Pick photos** with the system photo picker (3–60, in the order you tap them). The app never reads the rest of your library.
- **Edit**: reorder clips, captions on each photo, title and subtitle cards, end credits that hold or roll, three themes (Documentary, Warm, Energetic).
- **Music**: five original built-in tunes, songs from your own music library, or any audio file in Files. Clips can also carry their own sound bite, with the music ducked underneath.
- **AI assistant** (on-device, Apple Intelligence): writes titles, captions and credits, picks a tune, tells the story of the photos, and edits the montage by chat. Every change can be undone. Nothing leaves the device.
- **Export** to Photos, any folder in Files (On My iPhone, iCloud Drive, Google Drive, Dropbox…) or the share sheet, with a remembered default.
- **iPad**: split layout, with preview and actions on the left and the editor on the right.
- **Apple Watch companion**: see what's being edited, start an export from your wrist, and replay recent montages.

## Requirements

- Xcode 26, iOS / iPadOS 26.2+, watchOS 26.0+
- The assistant needs an Apple Intelligence device (iPhone 15 Pro, iPhone 16 or newer; M-series iPad). Everything else works without it.

## Project layout

| Folder | What's in it |
| --- | --- |
| `AI Gen Memories/` | iPhone and iPad app |
| `AI Gen Memories/Tunes/` | Built-in music (original, royalty-free) |
| `Watch App/` | Apple Watch companion |
| `Tools/make_tunes.py` | Regenerates the built-in tunes (`python3 Tools/make_tunes.py out`, needs numpy and ffmpeg) |

## Privacy

Photos are copied into the app and processed on the device. The assistant runs on Apple's on-device model. The iPhone and Watch talk over Apple's WatchConnectivity. No servers, no accounts, no analytics.

© Code Rendering Studio
