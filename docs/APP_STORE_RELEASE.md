# App Store Release Configuration

| Setting | Value / Policy |
| --- | --- |
| App Store ID | `6826986771` (`com.roamtty.app.ios`, Share Extension `com.roamtty.app.ios.share`) |
| Min iOS | iOS 16.0 (`IPHONEOS_DEPLOYMENT_TARGET = 16.0`) |
| Encryption | Standard algorithms only (`libssh2`, OpenSSL, mosh, desktop UDP); no proprietary crypto |
| `ITSAppUsesNonExemptEncryption` | `false` — exempt from documentation per App Store Connect questionnaire (setting `true` without a compliance code triggers upload error **90592**) |
| Excluded Territories | France, mainland China, and EU territories (EU pending trader-status verification) |
| Privacy & Support URLs | `https://roamtty.com/privacy/` · `https://roamtty.com/support/` (`/en/support/`) |

## Guardrails

- Do **not** expand territories automatically.
- Re-run the App Store Connect encryption questionnaire before changing cryptographic protocols or enabling France.
- Reference: [Apple Export Compliance Documentation](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/).
