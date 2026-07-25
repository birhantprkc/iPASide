# Changelog

All notable changes to iPASide are documented here. This project adheres to
[Semantic Versioning](https://semver.org/) and
[Keep a Changelog](https://keepachangelog.com/).

## [1.0.0] - 2026-07-26

First release. iPASide signs and installs `.ipa` files onto a physical iPhone or iPad
using a free Apple ID, on Windows, with no jailbreak and no paid developer account.
Verified end to end against an iPhone 8 Plus running iOS 16.7.15 over USB.

Everything runs locally. There is no iPASide server, no remote anisette provider and no
telemetry — your Apple ID talks to Apple directly from your own machine, over TLS
verified against Apple's own pinned root.

### Sideloading

- Pick or drop an `.ipa` and iPASide provisions, signs and installs it in one action,
  reporting each phase live: Provision → Sign → Install.
- Apple ID sign-in against Apple's GrandSlam service — modified SRP-6a (SHA-256,
  NG-2048, `s2k` password derivation) with two-step trusted-device 2FA. Your password is
  never passed on a command line and never written to disk.
- Device-provisioning (anisette) headers are generated **in-process and offline**, in
  pure Python. No Apple DLLs, and no third-party anisette server ever sees your session.
- TLS is verified against Apple's bundled `Apple Root CA` chain plus `certifi`.
  Verification is never disabled anywhere in the codebase.
- Full provisioning against Apple's developer services: issues a development
  certificate, registers the device, creates the App ID and downloads the provisioning
  profile. Free accounts are limited to one certificate, so a stale one is revoked
  first, and the App ID slots Apple allows per 7-day window are tracked for you
  (`slots`).
- Signing uses a purpose-built `zsign` (SHA-256 CodeDirectory, canonical DER
  entitlements), reproducibly compiled from source by `tools/zsign/build-zsign.sh`.
- Apps whose bundle id belongs to someone else — Instagram's `com.burbn.instagram`, say
  — are automatically given a team-scoped id, because Apple refuses to register an
  identifier you do not own.

### More than one Apple ID

- Sign in with several and keep them all. Home names the one in use and switches
  between them without asking for a password again — the session is already
  cached — and Settings lists them with their team, adds another, or signs one out
  without disturbing the rest. This matters because a free account may register
  only ten App IDs per 7-day window; a second Apple ID is how you keep going. It does
  not raise how many apps can be installed at once - iOS caps that at three per
  device across every free profile, whichever account signed them.
- **A refresh runs as the account that signed the app**, not whichever is selected.
  Re-signing an installed app with a different team's identity produces something
  iOS will not install over the existing copy, so the app simply stops opening —
  the opposite of what a refresh is for. Each sideload records its team, and each
  account records the team it provisions under, so the two can always be matched.
- When the account that signed an app is not signed in at all, iPASide says so by
  name and team rather than letting Apple answer with bare error 9401 ("An App ID
  with Identifier ... is not available"), which reads like a problem with the app
  instead of with which account is in use.
- Signing material is kept per account. Shared, a second Apple ID found the first
  one's private key, failed to match it against its own team's certificates, and
  revoked that team's only certificate to recover — breaking every app the other
  account had signed.
- Upgrading from a single-account build keeps you signed in: the old session is
  migrated on first read, and not left behind as a second copy to disagree with.

### Choosing where it goes, and how

- **Which device.** With more than one iPhone or iPad attached, pick the target from the
  sidebar; the Sideload screen names the device it is about to write to, directly above
  the button that does it. A single device is selected silently, and the choice is
  remembered between launches. The engine refuses to guess between two devices rather
  than picking one quietly.
- **Every screen follows that choice as you make it.** Home's status cards and the Apps
  list re-read when you pick a different phone, rather than describing whichever one was
  selected when the screen opened — which would put one device's details, transports and
  installed apps under another device's name, with an Uninstall button beside each.
- **Which connection.** Automatic, USB only, or Wi-Fi only. Automatic prefers the cable
  and falls back; the other two are honoured rather than treated as hints, so asking for
  USB fails with a clear message instead of quietly going over the air. Wi-Fi costs much
  more per round trip than it does per megabyte: reading a device's details took 132 ms
  over USB against 575 ms over Wi-Fi, while a complete 299 MB sideload took 95 s over USB
  against 108 s over Wi-Fi. Automatic reaches for the cable because the chatty parts of
  the job dominate, not the upload.

### Tweak injection

- Inject `.dylib` tweaks, or `.deb` packages directly: iPASide unpacks the `ar` archive
  and its `data.tar.{gz,xz,bz2,lzma,zst}` and pulls out every Mach-O dylib, labelled with
  its CPU architecture. Rootful, rootless and roothide layouts are all understood.
- Multiple tweaks per app, added by picker or by dropping them anywhere on the window,
  each row showing the dylib, its architecture and the `.deb` it came from.
- Optional weak linking, and injection into app extensions.

### Keeping apps alive

- Free-account provisioning profiles last 7 days. The **Library** tracks everything you
  have sideloaded with a live expiry countdown, and re-signs on demand per app or all at
  once — showing the same Provision → Sign → Install progress a first install does,
  because that is exactly what a refresh performs.
- An optional daily background refresh renews only what is due, through a Windows
  scheduled task. iPASide does not need to be open for it, a day the PC was off is
  caught up once it is back, and it is neither blocked by nor killed by running on
  battery. Verified by letting the Task Scheduler run it with the app closed: it
  launched with no window, re-signed and reinstalled a due app on the phone in 110
  seconds, and moved its expiry from one day left back to a full seven.

### Keeping the signed `.ipa`, if you want it

- Off by default. When enabled, the signed app is saved as `<original name>_Signed.ipa`
  in a folder you choose, so you can install or inspect it again without signing a
  second time. Settings reports how many are stored and how much space they take, and
  can delete them all after confirming.
- The signing workspace goes to the same folder, so pointing iPASide at a roomier disk
  moves all of the heavy I/O there rather than only the finished file.

### When Windows cannot reach your iPhone

- iPASide needs Apple Mobile Device Service for USB, and says so plainly when it is
  absent instead of implying the phone is unplugged. Three states, three different
  answers: nothing at all when it is running; **Start the service** when it is installed
  but stopped; **Install iTunes** when it is missing.
- Installing fetches Apple's current 64-bit iTunes installer, shows real download
  progress, and verifies it before running: the file must carry a valid Authenticode
  signature **and** be signed by Apple. Apple publishes no checksum, and a signature is
  the stronger claim anyway — a checksum only proves the bytes match a list you were
  handed, while a valid signature proves Apple produced them. Anything else is deleted
  and refused.

### Managing what is installed

- The **Apps** list shows everything on the device with its real home-screen icon, read
  from SpringBoard as a second pass so the list never waits on artwork.
- Uninstall from the app, with confirmation. Removing something from the Library
  uninstalls it from the device it was actually installed onto, which the registry
  records — not whichever device happens to be selected now.

### Advanced options

- Override the bundle id, display name and version; strip app extensions, the watch app
  or `UISupportedDevices`; enable file sharing.

### The app itself

- A chromeless Flutter desktop shell with seven screens — Home, Sideload, Library, Apps,
  Sign in, Diagnostics, Settings — in both light and dark themes, following the system
  theme with a manual override.
- Drop an `.ipa` anywhere on the window and it loads, switching to Sideload on its own;
  drop a `.deb` or `.dylib` and it joins the selected app's tweak list. Your selection
  survives moving between screens.
- Motion throughout — staggered entrances, hover lift, press feedback, an animated
  stepper — all respecting the OS "reduce motion" setting, and tuned so a screen settles
  in about a third of a second rather than assembling itself in front of you.
- **Diagnostics** reports the real state of your toolchain: Apple Mobile Device Service,
  the anisette provider, connected devices and the SDKs.
- Expected failures read as sentences. An unreachable device says which one and what to
  do about it, and an `.ipa` that has been moved or deleted since you chose it says so
  by name — which is the one a background refresh weeks later is most likely to hit.
  Only an actual bug produces a stack trace.

### Install progress you can actually read

- The install step streams the AFC upload byte by byte ("Uploading to iPhone · 120 /
  232 MB"), then `installd`'s own sub-steps as they happen — staging, extracting,
  inspecting, preflighting, verifying, creating the container, installing, sandboxing,
  finalising. Roughly 70 progress events per install, ending at 100%. iPASide drives the
  upload and the `installd` exchange itself, because the underlying library reports no
  upload progress and discards `installd`'s status.

### In-app updates

- iPASide compares its version against the latest GitHub release at startup — a version
  check only, nothing is downloaded uninvited. On request it downloads the installer and
  verifies its SHA-256 against the release's published `SHA256SUMS.txt` before offering
  to install it.
- Fail-closed throughout: a release with no checksums, or a download whose hash does not
  match the entry **for its filename**, is refused and discarded. Installing is always
  your click. A checksum published alongside the installer proves integrity, not
  authenticity, so an unattended install will only be defensible once releases are
  code-signed. Every release ships `SHA256SUMS.txt`.

### Installer

- A wizard in iPASide's own colours rather than the stock one: dark whatever the Windows
  theme, the brand mark on a panel, and a progress bar in the app's accent gradient. One
  screen carries the single real choice, then it installs.
- Upgrades are transactional. The previous install is renamed aside — a metadata-only
  move on the same volume, so milliseconds rather than copying hundreds of MB — and the
  upgrade commits only once the new engine *answers*: `ipaside_engine version` eagerly
  imports pymobiledevice3, unicorn's native library, cryptography and Pillow, so a zero
  exit proves the payload runs rather than merely arrived. Anything else restores what
  was there before, including a setup cancelled mid-copy. Every step is recorded in
  `%LOCALAPPDATA%\iPASide\install.log`.
- Uninstalling removes the program but leaves your signing material and settings alone.

### Performance

- Cold start is a few hundred milliseconds. The engine is a resident process
  (newline-delimited JSON over stdio) that imports once and serves many commands rather
  than paying Python startup per command, and it is prewarmed while the window is coming
  up.
- The engine is adopted into a Windows Job Object, so it is reaped even if iPASide is
  force-killed, and child processes are terminated as a tree so nothing strands `zsign`
  or device helpers.
- iPASide runs the engine it shipped, isolated from the environment, so a `PYTHONPATH`
  set elsewhere on the machine cannot substitute a different one.
- Shipped bytecode is precompiled, so a fresh install does not spend its first launch
  compiling Python.

### The engine on its own

- Everything the UI does is available as a CLI: `doctor`, `devices`, `device-info`,
  `developer-mode`, `apps`, `app-icons`, `install`, `uninstall`, `anisette`,
  `apple-support`, `login`, `teams`, `provision`, `sign`, `sideload`, `inspect`,
  `prepare`, `resolve-tweak`, `installs`, `refresh`, `signed`, `forget`, `slots`,
  `delete-app-id` and `version` — plus `serve`, the resident mode the app drives.
  `--json` works on all of them, and output is UTF-8 so non-ASCII app names survive
  Windows. Device commands take `--udid` and `--connection usb|wifi|auto`; `login`
  takes `--accounts`, `--use <email>` and `--logout [--email <email>]`.

### Quality

- A pytest suite over the engine and a Flutter suite over the shell, both run in CI
  alongside a full installer build on every push. Releases are built locally, verified
  against a real device, and published by hand — CI never uploads to a release, because
  there is no iPhone on a build runner.

### Known limitations

- **The installer is not code-signed**, so Windows SmartScreen will warn on first run.
  Verify the download against `SHA256SUMS.txt` if you want certainty. A signing
  certificate is the intended fix.
- **Signed apps expire after 7 days** and need re-signing. That is Apple's limit on free
  accounts, not ours — the Library and background refresh exist to make it painless.
- **Only three sideloaded apps can be installed at once**, per device. iOS enforces
  this itself, at install time, counting every app signed by any free Apple ID - so a
  second account does not add slots. Confirmed against an iPhone 8 Plus: the fourth
  install is refused with `ApplicationVerificationFailed`, and the three apps it
  named belonged to two different teams. Only a paid account lifts it.
- **App extensions are stripped**, so widgets, share sheets, keyboards and watch apps
  will not work. Free accounts cannot provision them.
- **App Store `.ipa` files are FairPlay-encrypted** and cannot be re-signed. iPASide
  detects this while inspecting and tells you rather than failing obscurely.
- **iPhone and iPad only.** An `.ipa` built for tvOS, watchOS or visionOS is
  indistinguishable from an iOS one until its Info.plist is read - same zip, same
  `Payload/<App>.app` - and signing one as iOS provisions cleanly, uploads, and is
  refused by the device at the last step. iPASide reads `CFBundleSupportedPlatforms`
  (falling back to `UIDeviceFamily`) and says which platform the file is for instead.
  Apple TV support would need the provisioning calls scoped to tvOS rather than the
  `ios/` paths every one of them currently uses, and from Windows only an Apple TV
  with a USB port is reachable in the first place.
- **Tested with a free Apple ID, on one phone.** A complete sideload has been verified
  over both USB and Wi-Fi. Paid accounts should work and avoid the limits above, and two
  phones through the device picker is covered by tests rather than by hardware, but a
  free account and a single device is what has actually been exercised.
- **Wi-Fi needs Wi-Fi sync enabled** for the device, which is what makes Windows advertise
  it over the network at all. If iPASide reports the phone as USB-only while it is plainly
  on the same network, restarting Bonjour Service and Apple Mobile Device Service is what
  makes it appear — Apple's service discovers devices at startup and does not always pick
  up a change made after it.
- **Windows only** at present. The shell was chosen with a macOS port in mind; the
  deferred work is written down in [docs/macos-port.md](docs/macos-port.md).
