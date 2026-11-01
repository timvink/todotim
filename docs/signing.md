# Developer ID signing and notarization

Releases are ad-hoc signed until the repository has five signing secrets. With them, the release workflow signs
`TodoTim.app` with a Developer ID certificate, has Apple notarize it, staples the ticket, and checks it with
Gatekeeper. Users can then open the app without **Open Anyway**.

How it works:

- `scripts/bundle.sh` signs with `SIGN_IDENTITY` when it is set (hardened runtime, secure timestamp), and ad-hoc
  otherwise. The app needs no entitlements file: it is not sandboxed and uses no hardened-runtime exceptions.
- `.github/workflows/release.yml` (build job) checks for the secrets. With all five, it imports the certificate
  into a temporary keychain, signs, notarizes with `notarytool`, staples, zips, runs `spctl`, and deletes the
  keychain. With none, it builds an ad-hoc release as before. With only some, the release fails.

## 1. Create the Developer ID Application certificate

Only the **Account Holder** of the Apple Developer account can create Developer ID certificates.

1. On your Mac, open **Keychain Access › Keychain Access menu › Certificate Assistant › Request a Certificate
   From a Certificate Authority**.
   - **User Email Address**: any address; it does not end up in the certificate.
   - **Common Name**: anything, for example `TodoTim Developer ID`.
   - Choose **Saved to disk** and save the `.certSigningRequest` file. Keychain Access keeps the matching
     private key in your login keychain.
2. Go to [developer.apple.com/account](https://developer.apple.com/account) › **Certificates, IDs & Profiles ›
   Certificates**, and click **+**.
3. Choose **Developer ID Application**, then the **G2 Sub-CA** profile type, and upload the CSR.
4. Download the `.cer` file and double-click it. It appears in Keychain Access under **login › My
   Certificates**, with the private key nested under it.
5. Select the certificate (with its key), choose **File › Export Items**, and save it as `.p12`
   (for example `TodoTim-DeveloperID.p12`) with a strong password.

The certificate is named `Developer ID Application: <team name> (<TEAMID>)`. Apple fills in the team or legal
name of the account, not your own name or the email in the CSR. This account belongs to the company, so macOS
shows **GetHumanDesign** as the developer of TodoTim.

## 2. Create an App Store Connect API key for notarization

1. Go to [App Store Connect](https://appstoreconnect.apple.com) › **Users and Access › Integrations ›
   App Store Connect API › Team Keys**. (The first time, the Account Holder has to request API access.)
2. Click **+** (Generate API Key), name it `TodoTim notarization`, and give it the **Developer** role. That is
   enough for `notarytool`.
3. Download the `.p8` file. Apple lets you download it only once.
4. Note the **Key ID** (in the key's row) and the **Issuer ID** (above the table).

## 3. Back up the files

Back up the `.p12`, its password, and the `.p8` (with key ID and issuer ID) in your vault. Then delete the loose
copies from your Downloads folder.

## 4. Add the repository secrets

From the folder that holds the files:

    base64 -i TodoTim-DeveloperID.p12 | gh secret set MACOS_CERT_P12_BASE64 -R timvink/todotim
    gh secret set MACOS_CERT_PASSWORD -R timvink/todotim          # prompts for the .p12 password
    base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64 -R timvink/todotim
    gh secret set NOTARY_KEY_ID -R timvink/todotim                # the Key ID, e.g. XXXXXXXXXX
    gh secret set NOTARY_ISSUER_ID -R timvink/todotim             # the Issuer ID (a UUID)

Check with `gh secret list -R timvink/todotim`.

## 5. Cut a release

Tag and push as described in [CONTRIBUTING.md](../CONTRIBUTING.md#releases). In the build job, the log of
**Check signing secrets** should say "Signing with Developer ID and notarizing", and **Check Gatekeeper**
should print `source=Notarized Developer ID`. Notarization usually takes a few minutes.

To check a downloaded release yourself:

    spctl -a -vv -t exec /Applications/TodoTim.app
    codesign -dv --verbose=2 /Applications/TodoTim.app 2>&1 | grep Authority

## 6. Update the install instructions

Once a notarized release is out, update **Install** in `README.md` and the signing paragraph in
`CONTRIBUTING.md` to cover both cases:

- Releases from vX.Y.Z on are signed with a Developer ID and notarized, and open normally.
- Older, ad-hoc signed releases still need **System Settings › Privacy & Security › Open Anyway**.

Keep the `gh attestation verify` step: it ties the zip to this repository, which the Developer ID does not.

## Why ad-hoc builds trigger repeated Keychain prompts

TodoTim stores the Nextcloud app password as a generic password in the login keychain. When an app creates such an
item, macOS adds the app to the item's access list by its *designated requirement*: the rule that identifies
"the same app" in later versions.

- An ad-hoc signature has no certificate, so its designated requirement is the hash of the code itself
  (`cdhash H"…"`). Every build, and so every release, has a different hash. The new build no longer matches the
  access list, and macOS asks "TodoTim wants to use your confidential information stored in…" again. Clicking
  **Always Allow** adds only that exact build.
- A Developer ID signature has a designated requirement based on the bundle ID and team ID
  (`identifier "nl.timvink.todotim" and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" …`).
  It stays the same across builds, so updates keep access without a prompt.

The first Developer ID release prompts once, because the existing item still lists the ad-hoc build. After
**Always Allow** (or after the password is saved again), later releases do not prompt.

## Keychain API: recommendation once signing is stable

`KeychainCredentialStore` (`Sources/TodoCore/Sync/Keychain.swift`) uses the file-based (legacy) login keychain
with the default access list. Do not change it yet:

- **Access policy (`kSecAttrAccess` / `SecAccessCreate`)**: not needed. The default access list (the creating
  app) is right, and stable Developer ID signing is what makes it work across updates. These APIs are
  deprecated, and a wider list would let other apps read the password.
- **`kSecUseDataProtectionKeychain`**: this is the modern keychain (per-app access groups, no access-list
  prompts, `kSecAttrAccessible`). Outside the App Store it needs a `keychain-access-groups` entitlement, which
  needs an embedded Developer ID provisioning profile. Without one, calls fail with `errSecMissingEntitlement`
  (-34018), and ad-hoc builds can never use it.

Recommendation: after Developer ID releases work, keep the legacy keychain; the prompts stop. Move to the data
protection keychain only if you add a provisioning profile for another reason. Then add the entitlement
(`<TEAMID>.nl.timvink.todotim`), set `kSecUseDataProtectionKeychain` and
`kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock`, and migrate once: read the legacy item, write it to the
data protection keychain, then delete the legacy item. Keep ad-hoc local builds on the legacy keychain, or
they cannot store the password.

## Android APK signing

Android installs an update only when it is signed with the same key as the installed app, so every APK must use
one long-lived key. The release workflow builds `TodoTim-vX.Y.Z.apk` only when the repository has two secrets;
without them the release has the macOS app only.

The key is `android/todotim-release.keystore` (PKCS12, alias `todotim`, store and key password equal), with
`android/keystore.properties` next to it for local release builds. Both are gitignored and backed up in the
vault (`file-backup:todotim/android/...`). Never replace the key: a new one means uninstalling the app (and
its unsynced data) on every phone.

Add the secrets once, from `android/`:

    base64 -i todotim-release.keystore | gh secret set ANDROID_KEYSTORE_BASE64
    sed -n 's/^storePassword=//p' keystore.properties | tr -d '\n' | gh secret set ANDROID_KEYSTORE_PASSWORD

The workflow writes them to a temporary `keystore.properties`, builds with `-PtodotimVersion=X.Y.Z` (version
name `X.Y.Z`, version code `X*10000 + Y*100 + Z`), and deletes the key file before uploading the APK.
