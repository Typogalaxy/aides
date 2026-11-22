# macOS packaging

Run `scripts/macos/package.sh` from a macOS checkout to build an ad-hoc-signed
development disk image in `dist/`. Pull request builds upload the same kind of
disk image as a GitHub Actions artifact. The development build excludes the
automatic update feed. Install the app by dragging Aides into Applications
before starting its server.

The app includes `AidesServer` and a per-user launch agent helper. The helper's
commands are `start`, `stop`, `status`, and `invite`. The running background
service owns its own lifecycle. Closing or updating the desktop app does not
stop server tasks. After updating the host Mac, restart the background service
once active work reaches a safe stopping point so it loads the new executable.

## Optional cloud coding tools on the server Mac

Sign in to your installed official tool using its own sign-in flow. If the
background service is already running, stop it once active jobs are finished.
Start it from Terminal with the executable paths you want it to use:

```sh
helper="/Applications/Aides.app/Contents/Resources/aides-service"
AIDES_CODEX_PATH="$(command -v codex)" \
  AIDES_CLAUDE_CODE_PATH="$(command -v claude)" "$helper" start
```

Omit either variable if you only use one tool. The paths come from the server
Mac's environment and are stored in its per-user launch agent. Use the locally
installed executables you trust. Login credentials remain under each official
tool's control.

## Signed releases

Configure a protected GitHub Actions environment named `macos-release`. It
should allow only trusted release tags. Give the environment these secrets:

| Secret | Contents |
| --- | --- |
| `AIDES_DEVELOPER_ID_P12` | Base64-encoded Developer ID Application certificate and private key exported as a password-protected PKCS#12 file |
| `AIDES_DEVELOPER_ID_PASSWORD` | Password for that PKCS#12 export |
| `AIDES_NOTARY_P8` | Base64-encoded App Store Connect team API key file used by the Apple notary service |
| `AIDES_SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key exported using Sparkle's `generate_keys` tool |

Set these environment variables under GitHub's Variables tab:

| Variable | Contents |
| --- | --- |
| `AIDES_CODESIGN_IDENTITY` | Developer ID Application certificate name |
| `AIDES_NOTARY_KEY_ID` | App Store Connect team API key ID |
| `AIDES_NOTARY_ISSUER` | App Store Connect issuer ID |
| `AIDES_UPDATE_PUBLIC_KEY` | Public EdDSA key from the same Sparkle key pair |

Use a stable tag such as `v0.1.0` on a commit already merged into the default
branch. The workflow builds both products, bundles Sparkle, signs the
disk image, notarizes and staples it, then publishes the disk image,
`appcast.xml`, and `SHA256SUMS.txt` together. The public appcast links to the
exact versioned DMG. Keep the Sparkle signing key stable across releases so
installed apps can verify future updates. The workflow assigns the stable
update feed to the latest public GitHub Release. Publish stable tags in version
order.
