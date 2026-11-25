<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Driftline icon">
</p>

<h1 align="center">Driftline</h1>
<p align="center"><b>by <a href="https://apavin.com/driftline">Apavin</a></b><br>
Your internet speed, live in the Mac menu bar. Free and open source.</p>

<p align="center">
  <a href="https://github.com/vinayak0920/driftline/releases/latest/download/Driftline.zip"><b>⬇ Download for Mac</b></a> ·
  <a href="https://apavin.com/driftline">Website</a> ·
  <a href="../../releases">All releases</a>
</p>

---

## Features

- **Live speed, every second.** Upload and download speed in the menu bar, read straight from macOS's own network counters, the same numbers Activity Monitor uses. Choose a stacked, inline or download-only layout, in bits (Mb/s) or bytes (MB/s).
- **Live dashboard.** A smooth 90-second graph, peak speeds, and data sent and received this session.
- **Speed test.** Ping, jitter, and multi-stream download and upload, measured against Cloudflare's global network.
- **Keep Awake.** Stop your Mac sleeping for 15m to 8h, until a set time, or **until your downloads finish**. You can let the display sleep while the Mac keeps running, and it stops automatically at 20% battery. Right-click the menu bar item to toggle it.
- **Friends.** Link Macs with a 6-character room code. Your friend's character sits on your desktop in a frosted-glass bubble and acts out gestures you send each other: wave, heart, high five, coffee break and more.
- **Messages on the desktop.** Type a message to everyone or to one friend, and it pops up above your character on their screen. Double-click a friend's character to reply. Messages are end-to-end encrypted and never stored.
- **Per-app volume.** Turn Spotify down without touching Zoom: every app playing sound gets its own slider and mute button (macOS 14.2 or later).
- **History.** Your last 25 speed tests, saved on your Mac.
- Lightweight: native Swift, no Dock icon, almost no CPU use.

## Install

1. **[Download Driftline.zip](https://github.com/vinayak0920/driftline/releases/latest/download/Driftline.zip)**. The download starts right away and always gets the newest version.
2. Unzip it and drag **Driftline** into **Applications**.
3. Open it. The first time, macOS may say it can't verify the developer, because Driftline isn't distributed through the App Store. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. Or run this once in Terminal:
   ```bash
   xattr -cr /Applications/Driftline.app
   ```

Requires **macOS 13 Ventura or later**, on Apple silicon or Intel.

## Build from source

You only need Apple's free command line tools (`xcode-select --install`):

```bash
git clone https://github.com/vinayak0920/driftline.git
cd driftline
bash build.sh --install
```

## How it works

| Part | What it does |
| --- | --- |
| `Sources/NetStats.swift` | Reads 64-bit per-interface byte counters from the kernel (`sysctl NET_RT_IFLIST2`). It skips VPN tunnels and virtual interfaces so traffic isn't counted twice. |
| `Sources/SpeedTester.swift` | Ping from the measured round-trip time minus the server's processing time, plus parallel download and upload streams with a 2-second warm-up discarded. |
| `Sources/AwakeController.swift` | Keep Awake through standard macOS power assertions (the same mechanism `caffeinate` uses). |
| `Sources/Friends.swift`, `Buddy.swift` | Friends rooms over a WebSocket, encrypted messages (AES-GCM, key derived from the room code), and code-drawn animated characters. |
| `Sources/Mixer.swift` | Per-app volume using Core Audio process taps: each adjusted app's audio is tapped, its original muted, and played back with your volume. |
| `Sources/Updater.swift` | Checks GitHub Releases, asks the user, verifies the update's signature, installs and relaunches. |
| `relay/` | The Cloudflare Worker that links Friends rooms: one Durable Object per room, using WebSocket hibernation. |

## Privacy

- Live speed and Keep Awake run entirely on your Mac.
- The speed test only talks to `speed.cloudflare.com`.
- Friends sends only your display name, chosen character, color, gestures and messages, and only to people in your room. Nothing is stored. The relay only sees a hash of your room code, and messages are encrypted with a key made from the code, so the relay can't read them. Anyone with a room code can join that room, so share codes only with people you know.
- Per-app volume needs the "System Audio Recording" permission so it can adjust an app's sound. Audio is processed live on your Mac and never recorded or saved.

## Run your own Friends relay

Friends uses a free Cloudflare Worker. To host your own:

```bash
cd relay
npm install
npx wrangler login
npx wrangler deploy
```

Then build with your URL: `RELAY_URL=https://driftline-relay.<you>.workers.dev bash build.sh --install`.

## Automatic updates

Driftline checks this repo's latest GitHub release shortly after launch and every 6 hours. When a newer version exists it asks the user, then downloads it, **verifies its Ed25519 signature**, replaces the app and relaunches. Unsigned or tampered downloads are never installed; the user is sent to the release page instead. Users can turn automatic checks off in the gear menu.

One-time setup (creates the signing key on your Mac, stores the private half as a GitHub secret and the public half in `Info.plist`):

```bash
bash scripts/setup-updates.sh
git add Info.plist && git commit -m "Add update signing key" && git push
```

## Releasing (maintainers)

Push a version tag. GitHub Actions builds the universal app, signs it, and attaches `Driftline.zip` and `Driftline.zip.sig` to a new release. Every installed copy (1.1 and later) then offers the update:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

---

Made by [Apavin](https://apavin.com) · More [free tools](https://apavin.com/free-tools) · MIT License
