# Packaging & distribution

How oort's GUI is packaged, what's deliverable today, and the path to a fully
standalone, notarized app.

## Build the artifacts

```bash
./make-app.sh    # → build/oort.app   (the SwiftUI app)
./make-dmg.sh    # → build/oort-<version>.dmg  (drag-to-Applications)
```

`oort gui` runs `make-app.sh` then opens the app.

## Signing

- **Default: ad-hoc** (`codesign -s -`). Fine for local use; Gatekeeper will warn
  on another Mac (right-click → Open, or `xattr -dr com.apple.quarantine oort.app`).
- **Distributable: Developer ID** — set the identity and re-run:
  ```bash
  CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./make-app.sh
  ```
  then **notarize** (needs an Apple Developer account):
  ```bash
  ./make-dmg.sh
  xcrun notarytool submit build/oort-<v>.dmg --apple-id you@example.com \
        --team-id TEAMID --password <app-specific-pw> --wait
  xcrun stapler staple build/oort-<v>.dmg
  ```

## What's deliverable today (honest)

The `.app` is a **native front-end that drives a local oort install** — its
`OORT_HOME` is baked to the repo it was built from, so it finds the `oort` CLI +
engine even when dragged to `/Applications`. You still need that repo present and a
golden image built (`oort build-image`). So today's `.dmg` distributes the GUI, not
a one-click, self-contained product.

## Path to a fully standalone app (future)

To ship a single notarized `.app` a user can just open:

1. **Bundle the runtime** into `Contents/Resources/`: the `oort` engine binary
   (codesigned with `com.apple.security.virtualization`), `oort`, `oort-guest`,
   `cloud-init/`, `make-image.sh`, and optionally `gvproxy`.
2. **Move writable state out of the bundle** (a signed bundle is read-only): put
   `images/`, the golden, and `share/` under `~/Library/Application Support/oort`.
   This means parameterizing `oort`'s `DISK`/`SEED`/`GOLDEN`/`SHARE`/engine paths
   (they already honor `OORT_*` env overrides) to that location.
3. **Build the golden on first launch** (download the Ubuntu cloud image +
   provision), with progress in the GUI.
4. Developer ID + notarization (above), plus a **brew cask** ([`Casks/oort.rb`](../Casks/oort.rb))
   and optionally Sparkle for auto-update.

This is ordinary (if sizable) engineering; it's deferred because it needs an Apple
Developer ID and a chunk of path-plumbing, not research.
