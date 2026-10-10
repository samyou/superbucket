# SuperBucket

A small native macOS app: drag files or folders onto the window and they upload straight to a
[Tigris](https://www.tigrisdata.com) bucket.

- Drag and drop (or ⌘O) files and folders. Folders keep their relative paths as object keys.
- Drop files on the menu bar icon too, even when the window is closed.
- Parallel uploads with per-file progress, cancel, retry. Files over 64 MB use multipart upload (32 MB parts, 4 in
  flight, per-part retries), so there is no practical size limit.
- Skips files that already exist in the bucket with the same size (configurable), with a one-click "upload anyway".
- Copy a public URL or a 7-day presigned link for each uploaded object.
- Credentials are stored in the macOS Keychain. S3 SigV4 is implemented in `SuperBucketCore`; the only dependency is
  [Sparkle](https://sparkle-project.org) for auto-updates.
- `open -a SuperBucket <files>` uploads from the command line or a Shortcuts quick action.

## Build and run

Requires Xcode 15+ / macOS 14+.

```sh
make run        # builds build/SuperBucket.app and opens it
```

Or open `Package.swift` in Xcode and run the `SuperBucket` scheme.

## Configure

1. Create a bucket-scoped access key:
   ```sh
   tigris access-keys create superbucket -b <your-bucket> -r ReadWrite
   ```
2. Launch the app. The settings sheet opens on first run. Enter the bucket name, `tid_…` access key ID and `tsec_…` secret.
3. Click **Test Connection**, then **Done**. Drop files.

Optional settings: a key prefix (e.g. `uploads/`), the endpoint (default `https://t3.storage.dev`), path-style URLs, and
the number of parallel uploads.

## Tests

```sh
make test
```

Unit tests cover the SigV4 signer against the AWS test vector. If a `.env` with `TIGRIS_STORAGE_ACCESS_KEY_ID`,
`TIGRIS_STORAGE_SECRET_ACCESS_KEY` and `TIGRIS_STORAGE_BUCKET` is present, an integration test uploads, downloads via
presigned URL, and deletes a real object.

## Distributing

`scripts/release.sh` builds a universal (Apple silicon + Intel) app, signs it with your Developer ID using the
hardened runtime, notarizes it with Apple, staples the ticket and produces `dist/SuperBucket-<version>.dmg`.

One-time setup:

1. Join the [Apple Developer Program](https://developer.apple.com/programs/).
2. In Xcode > Settings > Accounts > your team > Manage Certificates, add a **Developer ID Application** certificate.
3. Create an app-specific password at <https://appleid.apple.com> and store it for notarytool:
   ```sh
   xcrun notarytool store-credentials superbucket --apple-id <you@example.com> --team-id <TEAMID>
   ```

Then:

```sh
scripts/release.sh --version 0.1.0      # => dist/SuperBucket-0.1.0.dmg, notarized and stapled
scripts/release.sh --adhoc              # unsigned local test build, no notarization
```

### Releases from GitHub Actions

Pushing a tag like `v0.1.0` runs `.github/workflows/release.yml`, which signs, notarizes and attaches the DMG to a
GitHub release. Add these repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | `base64 -i cert.p12` of your Developer ID Application certificate + private key (export from Keychain Access) |
| `DEVELOPER_ID_P12_PASSWORD` | password you set when exporting the .p12 |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_APP_PASSWORD` | app-specific password |
| `SPARKLE_PRIVATE_KEY` | contents of the file written by `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x key.txt` |

### Auto-updates (Sparkle)

Installed apps check `https://raw.githubusercontent.com/samyou/superbucket/main/appcast.xml` (the `SUFeedURL` in
`Resources/Info.plist`). The release script signs the DMG with your Sparkle EdDSA key and regenerates `appcast.xml`;
the workflow commits it to `main`. The matching public key is `SUPublicEDKey` in `Info.plist`. The private key lives in
your login keychain ("Private key for signing Sparkle updates"); export it once with `generate_keys -x` for CI.

### Finder quick action

In Shortcuts, create a shortcut that receives files from Quick Actions and runs the shell script
`open -a SuperBucket "$@"` with input passed as arguments. It then appears in Finder's right-click Quick Actions menu.

`homebrew/superbucket.rb` is a Homebrew cask template; drop it into a tap repo and fill in the URL and sha256
printed by the release script.

## Notes

- Files under 64 MB use a single streamed `PUT`; larger files use multipart upload and are aborted server-side if cancelled.
- "Copy Public URL" only resolves if the bucket is public (`tigris buckets set <bucket> --access public`); otherwise use the presigned link.
