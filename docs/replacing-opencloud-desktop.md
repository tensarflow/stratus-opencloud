# Replacing the official OpenCloud Desktop client

Once Stratus works for you, the official OpenCloud Desktop app can go. This page is for people who
run both on one Mac. Every step is yours to run; nothing here is automated. The main point:
**do not delete the old local sync folder until you know everything in it is on the server.**

Paths below are the defaults of OpenCloud Desktop 4.x on macOS. Yours may differ (the sync folder
is whatever you chose when you added the account), so check before you delete anything.

## What the old client leaves on a Mac

| Item | Default path |
|---|---|
| App | `/Applications/OpenCloud.app` (contains `Contents/PlugIns/FinderSyncExt.appex`) |
| Config and account | `~/Library/Preferences/OpenCloud/opencloud.cfg` |
| Sync folders | `~/OpenCloud/<space>/`, one per space (the exact paths are the `localPath` entries in `opencloud.cfg`) |
| Sync journal | `.sync_journal.db` inside each sync folder |
| Sync log | `.OpenCloudSync.log` inside each sync folder |
| Autostart | `~/Library/LaunchAgents/eu.opencloud.desktop.plist` |
| Finder extension container | `~/Library/Containers/eu.opencloud.desktop.FinderSyncExt` |
| Group container | `~/Library/Group Containers/eu.opencloud.desktop` |
| Cache | `~/Library/Caches/OpenCloud` |

## 1. Quit the app

```sh
osascript -e 'tell application "OpenCloud" to quit'
```

If it was not running, nothing happens. Check that no OpenCloud icon remains in the menu bar. The
LaunchAgent is deleted in step 4, so do not log out or reboot before then, or the app will start
again.

## 2. Check nothing is waiting to upload

Read the sync journal of each sync folder. This is read-only: `immutable=1` makes sqlite open the
file without creating lock or WAL files.

```sh
for db in ~/OpenCloud/*/.sync_journal.db; do
  echo "== $db"
  sqlite3 "file:$db?immutable=1" \
    "select 'pending uploads', count(*) from uploadinfo
     union all select 'conflicts', count(*) from conflicts
     union all select 'blacklisted', count(*) from blacklist
     union all select 'partial downloads', count(*) from downloadinfo"
done
```

`pending uploads` and `conflicts` should both be 0. `blacklisted` entries and `partial downloads`
are usually download problems, not unsent changes; the `errorstring` column of `blacklist` says
which. In the sync log, lines containing `SyncFileItem::Up` are uploads and `SyncFileItem::Down`
are downloads.

Do not rely on the journal alone: it only knows what the client had already scanned. Step 3 is the
real check.

## 3. Confirm everything in the local folder is on the server

Compare the local folder with the space on the server using a read-only tool. [rclone](https://rclone.org)
does this well: `rclone check --one-way` reports every local file that is missing on the server or
differs from it, and changes nothing on either side.

Set up a WebDAV remote once with `rclone config` (interactive, so the token does not land in your
shell history):

- type `webdav`, name it for example `opencloud`
- url `https://<server>/dav/spaces/<space id>`
- vendor `owncloud` (or `other` if your rclone version has no such choice)
- user: your user name; password: an app token (the OpenCloud "app token" feature), not your password

The space id is the `spaceId` in `opencloud.cfg` for that sync folder, or the `id` from
`GET /graph/v1.0/me/drives`. Then:

```sh
rclone check --one-way ~/OpenCloud/<space> opencloud: \
  --exclude '.sync_journal.db*' --exclude '.OpenCloudSync.log' --exclude '.~*' --exclude '.DS_Store' \
  --missing-on-dst missing.txt --differ differ.txt
```

The excludes skip the old client's own files (journal, log, half-finished download temp files `.~*`)
and macOS `.DS_Store` files, which the server usually does not have. Add more `--exclude` patterns
for other junk you know about.

Read the summary: `0 differences found` means every local file is on the server. Otherwise
`missing.txt` lists local files the server lacks and `differ.txt` files whose size (or checksum)
differs. rclone compares checksums when both sides offer a common one and falls back to sizes;
it prints "No common hash found" when it can only compare sizes. Look at each listed file before
copying anything: a file that differs may be newer on the server. If the old client's initial
download was interrupted, partly downloaded files are the likely cause.

A rough independent check: compare file counts and total sizes, for example
`find ~/OpenCloud/<space> -type f | wc -l` against the same count under the Stratus folder in
`~/Library/CloudStorage` (try a small subfolder first, since listing is on demand), or against what
the web UI shows.

## 4. Remove the account and delete the app

When step 3 reports nothing missing:

1. Open OpenCloud, open the account menu and choose **Remove account**. This should also drop its
   stored login; check Keychain Access afterwards for a leftover "OpenCloud" entry. If you cannot
   open the app, skip this and delete the config in the next step.
2. Quit the app again, then delete it and its leftovers. Review each path first.

```sh
rm -rf /Applications/OpenCloud.app            # the FinderSync extension is inside it and goes with it
rm -rf ~/Library/Preferences/OpenCloud
rm -f  ~/Library/LaunchAgents/eu.opencloud.desktop.plist
rm -rf ~/Library/Caches/OpenCloud
rm -rf ~/Library/Containers/eu.opencloud.desktop.FinderSyncExt
rm -rf ~/Library/Group\ Containers/eu.opencloud.desktop
```

If `/Applications/OpenCloud.app` is owned by root you will need `sudo`. Finder may keep showing the
old badge extension until you log out and back in, or run `killall Finder`.

## 5. The old local sync folder

Removing the app does not touch the sync folders. Keep them for a while. After Stratus has worked
for a week or so and a check (step 3) is clean, delete the folder, or move it somewhere outside
any synced location if you want a backup. It holds copies of server data plus the client's journal
and log files.

## 6. Afterwards

- Open Stratus and check that your spaces show up in Finder.
- Stratus v1 does not show the Shares space. If you used it in the old client, use the web UI for
  those files until a later version.
