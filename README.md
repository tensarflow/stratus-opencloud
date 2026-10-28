# Stratus for OpenCloud

A small native macOS app that shows your [OpenCloud](https://opencloud.eu) spaces in Finder as
on-demand files, the way iCloud Drive and Dropbox do. Folders browse without downloading anything,
a file downloads when you open it, and edits upload back.

Stratus is a menu-bar app plus a File Provider extension (`NSFileProviderReplicatedExtension`).
It is written from scratch, has no third-party dependencies, and is MIT licensed.

> Not affiliated with or endorsed by the OpenCloud project; OpenCloud is a trademark of its respective owner.

## Why

The official OpenCloud Desktop client for macOS syncs by downloading everything. It has no
on-demand files, so a large space eats your disk. Two community attempts to add a File Provider to
the Qt client upstream (opencloud-eu/desktop #848 and #1128) are large and unmerged. Stratus takes
the other route: a separate, small, well-tested app (about 3,100 lines of Swift in the app, extension
and StratusKit, plus about 2,400 lines of tests) that talks to the server's WebDAV and Graph APIs
directly.

## Status

v0.1, development build. Verified on macOS 27 (arm64) against OpenCloud 7.2.4:

- The Personal space appears in Finder. Folders browse without downloading anything (0 B on disk).
- Files download when opened. Edits upload.
- New file, new folder, rename, move and delete round-trip to the server. Delete goes to the server trash.
- Conflicts keep both versions (see [Conflicts](#conflicts-and-known-limitations)).
- Unicode names round-trip.
- A 150 MiB file uploads through Cloudflare via TUS in about 46 s.
- 140 unit tests (`cd StratusKit && swift test`).

Not in v1: the Shares space, push updates (SSE), multiple accounts, Mac App Store.

## Install

Signed and notarized builds are published on the
[Releases page](https://github.com/tensarflow/stratus-opencloud/releases) (the first release is still
being prepared; until then, build from source as described below).

- **Homebrew:** `brew install --cask tensarflow/tap/stratus-opencloud`
- **Manually:** download `Stratus-<version>.dmg`, open it and drag **Stratus** to **Applications**.

Then follow [First run](#first-run). Stratus has to be running for server changes to reach Finder;
it offers to start at login after you sign in.

## Building from source

### Requirements

- macOS 14 or later (built and tested on macOS 27, Apple silicon).
- Xcode (built with Xcode 27 / Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`). The `.xcodeproj` is generated from `project.yml` and is not committed.
- An Apple Developer team. File Provider extensions need an App Group entitlement, so a signed
  build with a provisioning profile is required; an unsigned build will not load.
- An OpenCloud server you can sign in to with a browser.

### Build and install

```sh
scripts/build.sh            # generates the project, builds Debug with automatic signing,
                            # copies Stratus.app to ~/Applications and opens it
scripts/build.sh --no-open  # same, without launching
```

The script uses `xcodebuild -allowProvisioningUpdates`, so Xcode must be signed in to the team
named in `Config/Signing.xcconfig`. To build with your own team and bundle id, see
[Forking and re-signing](#forking-and-re-signing).

### Release builds (maintainers)

`scripts/release.sh <version>` archives a Release build, exports it with the team's Developer ID
Application certificate, packages `build/release/Stratus-<version>.dmg`, notarizes and staples it,
and prints the SHA-256 for the Homebrew cask (`packaging/homebrew/stratus-opencloud.rb`).
Notarization reads an App Store Connect API key from `ASC_KEY_PATH`, `ASC_KEY_ID` and
`ASC_ISSUER_ID`. `--archive-only` checks the build without a Developer ID certificate.

## First run

1. Open Stratus. A cloud icon appears in the menu bar and the Settings window opens.
2. Enter your server URL (for example `https://drive.example.com`) and click **Sign in with browser**.
   Finish the login in your browser.
3. **Turn the location on.** After sign-in macOS adds each space's Finder location *switched off*.
   The Stratus menu then lists the space as **Personal — turned off**; its **Turn on in System
   Settings…** item opens System Settings, General, Login Items & Extensions, File Providers
   (on macOS 14 the extension list is under Privacy & Security, Extensions, or similar). Switch
   **Stratus** on there (or click **Enable** next to it in Finder's sidebar). Until you do, listing
   the folder hangs and times out. The menu picks up the change within 30 seconds.
4. The Personal space shows up in Finder's sidebar under Locations; each project space you belong
   to gets its own location. The folders live under `~/Library/CloudStorage/Stratus-<space>`.
5. The first sign-in also adds Stratus to your login items. Keep it that way: **Stratus must be
   running for changes made on the server to reach Finder** (the app is what notices them). Your own
   edits upload either way. Settings, **Start Stratus at login** turns it off or on again.

## Sign-in

OIDC authorization code flow with PKCE (S256) against OpenCloud's built-in identity provider:

- Stratus opens the authorize URL in your default browser and listens for the redirect on a loopback
  address, `http://127.0.0.1:<random port>`, for the duration of the login only.
- The default client id is `OpenCloudDesktop`, the public client that every stock OpenCloud server
  registers (redirect URIs `http://127.0.0.1` and `http://localhost`). Admins who registered their
  own client can change it in Settings, Advanced. A dedicated client id for Stratus is something to
  agree with upstream; see the publishing checklist.
- Tokens live in the data-protection Keychain, shared between the app and the extension through a
  keychain access group. Nothing is written to plain files or `UserDefaults`.
- Token refresh is coordinated across the app and the extension processes with a file lock, so two
  processes never spend the same refresh token, and concurrent requests in one process share one
  refresh. If refresh fails (`invalid_grant`), the extension reports "not authenticated" and the
  menu and Settings offer **Sign in again**. That reruns the browser login and replaces only the
  tokens of the same account (same server, same user); your spaces and Finder locations stay as
  they are. A login as a different user is refused; sign out first to switch accounts.

## Architecture

```
Stratus.app (menu-bar app, SwiftUI)                 StratusFileProvider.appex
 ├─ Sign in: OIDC PKCE, browser + loopback           ├─ NSFileProviderReplicatedExtension
 ├─ One NSFileProviderDomain per space                ├─ item operations -> WebDAV / TUS, by file id
 ├─ Polls /graph/v1.0/me/drives every 30 s            ├─ enumerators: folders + working set
 └─ Menu: account, spaces, Show in Finder, errors     └─ per-space SQLite item cache (app group)
                    └──────────── StratusKit (Swift package) ────────────┘
   OIDC/PKCE · account store (shared Keychain) · OpenCloudClient (Graph, WebDAV, TUS) · PROPFIND parser
   · ItemCache (SQLite) · ChangeWalker (ETag diff) · sync rules (excluded names, conflict names)
```

All logic lives in `StratusKit` and is unit-tested with plain `swift test`, with no Xcode project or
File Provider needed. `App/` and `FileProvider/` are thin shells over it.

- **Identity.** One File Provider domain per space. An item's identifier is its `oc:fileid`; the
  space root is `.rootContainer`. Capabilities come from `oc:permissions`.
- **Change detection.** The menu-bar app polls `GET /graph/v1.0/me/drives` every 30 seconds (one
  request covers all spaces). When a space's root ETag changes it signals the working set. The
  extension then walks only the changed folders that have already been listed and reports
  additions, edits, deletions and moves. Folders you never opened are not touched.
- **Cache.** Per space, an SQLite file in the app group container holds what the system has been told
  (`id, parent, name, etag, size, mtime, listed`). The extension updates it after its own writes, so
  its own changes do not come back as remote changes.
- **Spaces come and go carefully.** A new space gets a domain on the next poll. A domain is removed
  only when the server answers 404 for its space (`GET /graph/v1.0/drives/<id>`), never because one
  listing lacked it, and the Personal space is never removed automatically. Removal (and sign-out)
  keeps local edits that never reached the server; Settings shows where, with **Show in Finder**.

## How it talks to OpenCloud

Quirks of the server (and of putting Cloudflare in front of it) that the client works around:

- **Files are addressed by file id**, `/dav/spaces/<fileid>`, not by path. A rename or move keeps the
  id, so Finder never sees a rename as a delete plus create. Responses to PUT, MOVE and TUS carry
  `OC-FileId` and `ETag`.
- **`PUT` needs `Content-Length`.** Chunked transfer encoding gets a 400.
- **0-byte files** go through TUS creation.
- **Uploads over 64 MiB use TUS** in 32 MiB `PATCH` chunks, because Cloudflare rejects request bodies
  over 100 MB. Smaller files are a single PUT.
- **The server ignores `If-None-Match: *`**, so creating a file first checks whether the name is
  already taken. A small race window remains between the check and the upload.
- **`If-Match` is honored** on PUT and on the TUS creation request, and returns 412 when the server
  copy changed. That is what detects conflicts.
- **Deletes go to the server's trash**, where they can be restored.
- Scratch files (`.DS_Store`, `._*`, `.~lock.*#`, `~$*` and similar) are excluded from sync and
  never reach the server.
- **Thumbnails come from the server** (`GET /dav/spaces/<fileid>?preview=1&x=…&y=…&a=1`), so
  Finder's gallery, icon and preview column views never download a file just to draw it. The
  server previews images, PDFs and text; for other types (it answers 404) Finder shows the generic
  icon until the file is downloaded.
- **The ETag only changes once per second.** OpenCloud derives it from the modification time in
  whole seconds, so two saves within one second keep the same ETag. An upload is therefore judged
  by the `OC-FileId` the server sends back, not by whether the ETag moved.

### Conflicts and known limitations

If an upload gets a 412, or a create collides with a name that appeared on the server in the
meantime, your local content is uploaded next to the original as
`name (conflict yyyy-MM-dd HHmm).ext`, and the original item is refreshed to the server version.
The same happens when an upload turns out to have landed on a different file than the one edited
(the original was moved or replaced on the server meanwhile), and when the edited file was deleted
on the server: then the copy is all that remains, next to where the file was (in the space root if
that folder was deleted too). If the copy cannot be saved anywhere, the local edit is kept and the
upload is retried later. Both versions survive; nothing is silently overwritten. The design goal is that a conflict may be
annoying but never loses data.

Known limitations:

- The create-collision race above (check then upload) is not atomic.
- No Shares space, no push updates (changes made elsewhere show up within about 30 to 60 seconds),
  one account only.
- Thumbnails only for the types the server can preview (images, PDFs, text); other files show a
  generic icon until downloaded.
- Changes made on the server reach Finder only while the menu-bar app runs (see First run).

## Testing

**Unit tests**, no server needed:

```sh
cd StratusKit && swift test
```

**Live tests** run against a real server and only touch `/fp-test/` in the Personal space. They are
skipped unless the environment is set. Use an app token (the OpenCloud "app token" feature), not
your password:

```sh
cd StratusKit
OC_URL=https://drive.example.com OC_USER=you OC_TOKEN=<app token> swift test
OC_LIVE_LARGE=1 ...   # also runs the 150 MiB TUS upload
```

**End to end** exercises the real Finder path (File Provider folder) with shell commands and
checks the result on the server over WebDAV. It needs the same `OC_*` variables, the location enabled,
and only touches `fp-test/e2e-<timestamp>/`, which it removes afterwards (it lands in the server trash):

```sh
OC_URL=... OC_USER=... OC_TOKEN=... \
  scripts/e2e.sh ~/Library/CloudStorage/Stratus-Personal [--large]
```

The token is passed to `curl` and never printed. The script looks up your personal space id with
`GET /graph/v1.0/me/drives`; set `OC_SPACE` to use another space id.

## Troubleshooting

Logs use the subsystem `com.arteq.stratus`. In zsh `log` can be shadowed, so use the full path:

```sh
/usr/bin/log show --last 10m --predicate 'subsystem == "com.arteq.stratus"'
/usr/bin/log stream --predicate 'subsystem == "com.arteq.stratus"'
```

Inspect what macOS thinks of the domain:

```sh
fileproviderctl dump com.arteq.stratus.FileProvider
```

Look for `user-disabled` or File Provider error `-2011`. That means the location is switched off in
System Settings; the Stratus menu shows the space as "— turned off" with a **Turn on in System
Settings…** item (see First run). Other things to check:

- The folder opens but stays empty or times out: the location is switched off, or the session ended
  (the menu shows **Sign in again**).
- A change made in the web UI has not appeared: wait up to a minute; the app polls every 30 s. Check
  that Stratus is running (cloud icon in the menu bar); without it server changes do not arrive.
- A build that will not launch with the extension: check that the team and bundle ids in
  `Config/Signing.xcconfig` match a provisioning profile Xcode can create for you.

## Forking and re-signing

Every signing value lives in `Config/Signing.xcconfig`: the team (`DEVELOPMENT_TEAM`), the bundle ids
(`STRATUS_BUNDLE_ID`, and the extension id derived from it), the app group (`APP_GROUP`) and the
keychain access group (`KEYCHAIN_GROUP`). Change the team and the bundle id there, run
`scripts/build.sh`. The Info.plists and entitlements read these values.

Two names are not derived from `STRATUS_BUNDLE_ID`: the `os.Logger` subsystem and the Keychain
service name are the literal string `com.arteq.stratus` in the Swift sources. A fork may change
them (search for the literal), but the log predicates in Troubleshooting use the literal, so adjust
those too if you do.

## Roadmap

- Push updates over OpenCloud's SSE endpoint instead of polling.
- The Shares space ("Shared with me").
- In-app updates (Sparkle) in addition to Homebrew.
- A dedicated OIDC client id agreed with OpenCloud upstream, instead of the stock `OpenCloudDesktop` one.

## Replacing the official OpenCloud Desktop

See [docs/replacing-opencloud-desktop.md](docs/replacing-opencloud-desktop.md) for how to retire the
official client safely once Stratus is working.

## Repository layout

```
App/                 menu-bar app (SwiftUI): sign-in, domains, polling, menu, settings
FileProvider/        the File Provider extension
StratusKit/          Swift package: auth, networking, cache, change walker, tests
Config/Signing.xcconfig   all signing values
project.yml          XcodeGen spec
scripts/build.sh     build, install, launch
scripts/e2e.sh       Finder-level round-trip test
docs/                guides
```

## Contributing

Issues and pull requests are welcome. Please run `cd StratusKit && swift test` before sending a
change; anything that touches sync behaviour should also pass `scripts/e2e.sh` against a test space.
Keep the code small and dependency-free.

## Security

Please report security problems privately via
[GitHub Security Advisories](https://github.com/tensarflow/stratus-opencloud/security/advisories/new)
rather than in a public issue.

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 ARTEQ ARGE VE MÜHENDİSLİK LTD. ŞTİ.
