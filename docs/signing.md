# Mac app signing

The release workflow signs `TodoTim.app` with the certificate in two repository secrets, `MACOS_CERT_P12_BASE64`
and `MACOS_CERT_PASSWORD`. Without them the app is ad-hoc signed.

- **Self-signed certificate (current).** Free, and enough to keep Keychain access across updates (see
  [Why ad-hoc builds trigger repeated Keychain prompts](#why-ad-hoc-builds-trigger-repeated-keychain-prompts)).
  macOS does not trust it, so the app is not notarized and users still click **Open Anyway** once.
- **Developer ID certificate plus three notary secrets.** The workflow also has Apple notarize the app, staples
  the ticket and checks it with Gatekeeper; users open it without **Open Anyway**. Needs a paid Apple Developer
  account. Switching from the self-signed certificate changes the designated requirement once, so the Keychain
  asks once more.

How it works:

- `scripts/bundle.sh` signs with `SIGN_IDENTITY` (a name or SHA-1 hash) when it is set, with a secure timestamp
  unless `SIGN_TIMESTAMP=0`, and ad-hoc otherwise. The app needs no entitlements file: it is not sandboxed and
  uses no hardened-runtime exceptions.
- `.github/workflows/release.yml` (build job) imports the certificate into a temporary keychain and signs. A
  Developer ID certificate gets a secure timestamp; a self-signed one does not (Apple's timestamp service serves
  only Apple-issued certificates). With the notary secrets it then notarizes with `notarytool`, staples, zips and
  runs `spctl`. A group of secrets that is only partly set fails the release, as do notary secrets with a
  certificate that is not a Developer ID.

## Self-signed release certificate

The current certificate is `CN=TodoTim Release Signing` (RSA 3072, code signing only, valid until 2051, SHA-1
`7128BF48CB44EF7937684754BE8D243D9FFF7A64`). The `.p12` and its password are
`signing/macos-release.p12` and `signing/macos-release.password` (gitignored), backed up in the vault as
`file-backup:todotim/signing/...` (restore with the vault skill's `file-vault-sync.sh restore`). Keep using it:
a new certificate gives the app a new designated requirement, and the Keychain asks once more after that update.

Check a release with `codesign -d -r- /Applications/TodoTim.app`; it should print
`designated => identifier "nl.timvink.todotim" and certificate leaf = H"7128bf48…"`.

To create a new one (only if the old one is lost):

    cat > cert.cnf <<'EOF'
    [req]
    distinguished_name = dn
    x509_extensions = ext
    prompt = no
    [dn]
    CN = TodoTim Release Signing
    [ext]
    basicConstraints = critical, CA:false
    keyUsage = critical, digitalSignature
    extendedKeyUsage = critical, codeSigning
    subjectKeyIdentifier = hash
    EOF
    openssl req -x509 -newkey rsa:3072 -noenc -keyout key.pem -out cert.pem -days 9125 -config cert.cnf
    # -legacy: `security import` cannot read OpenSSL 3's default PKCS#12 encryption.
    openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "TodoTim Release Signing" -out signing.p12
    base64 -i signing.p12 | gh secret set MACOS_CERT_P12_BASE64 -R timvink/todotim
    gh secret set MACOS_CERT_PASSWORD -R timvink/todotim          # prompts for the .p12 password

Store the `.p12` and its password under `signing/`, back both up with `file-vault-sync.sh update`, then delete
`key.pem` and the other loose files.

The sections below set up a Developer ID instead.

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

This replaces the self-signed certificate. From the folder that holds the files:

    base64 -i TodoTim-DeveloperID.p12 | gh secret set MACOS_CERT_P12_BASE64 -R timvink/todotim
    gh secret set MACOS_CERT_PASSWORD -R timvink/todotim          # prompts for the .p12 password
    base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64 -R timvink/todotim
    gh secret set NOTARY_KEY_ID -R timvink/todotim                # the Key ID, e.g. XXXXXXXXXX
    gh secret set NOTARY_ISSUER_ID -R timvink/todotim             # the Issuer ID (a UUID)

Check with `gh secret list -R timvink/todotim`.

## 5. Cut a release

Tag and push as described in [CONTRIBUTING.md](../CONTRIBUTING.md#releases). In the build job, the log of
**Import signing certificate** should say "Developer ID: signing with a secure timestamp", and **Check Gatekeeper**
should print `source=Notarized Developer ID`. Notarization usually takes a few minutes.

To check a downloaded release yourself:

    spctl -a -vv -t exec /Applications/TodoTim.app
    codesign -dv --verbose=2 /Applications/TodoTim.app 2>&1 | grep Authority

## 6. Update the install instructions

Once a notarized release is out, update **Install** in `README.md` and the signing paragraph in
`CONTRIBUTING.md` to cover both cases:

- Releases from vX.Y.Z on are signed with a Developer ID and notarized, and open normally.
- Older releases (self-signed or ad-hoc) still need **System Settings › Privacy & Security › Open Anyway**.

Keep the `gh attestation verify` step: it ties the zip to this repository, which the Developer ID does not.

## Why ad-hoc builds trigger repeated Keychain prompts

TodoTim stores the Nextcloud app password as a generic password in the login keychain. When an app creates such an
item, macOS adds the app to the item's access list by its *designated requirement*: the rule that identifies
"the same app" in later versions.

- An ad-hoc signature has no certificate, so its designated requirement is the hash of the code itself
  (`cdhash H"…"`). Every build, and so every release, has a different hash. The new build no longer matches the
  access list, and macOS asks "TodoTim wants to use your confidential information stored in…" again. Clicking
  **Always Allow** adds only that exact build.
- A signature with a certificate has a designated requirement based on the bundle ID and that certificate. For
  the self-signed certificate it is `identifier "nl.timvink.todotim" and certificate leaf = H"<SHA-1>"`; for a
  Developer ID it is based on the team ID
  (`identifier "nl.timvink.todotim" and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" …`).
  It stays the same across builds, so updates keep access without a prompt.

The first release with a new certificate prompts once, because the existing item still lists the previous
designated requirement. After
**Always Allow** (or after the password is saved again), later releases do not prompt.

## Keychain API

`KeychainCredentialStore` (`Sources/TodoCore/Sync/Keychain.swift`) uses the file-based (legacy) login keychain
with the default access list. Keep it that way:

- **Access policy (`kSecAttrAccess` / `SecAccessCreate`)**: not needed. The default access list (the creating
  app) is right, and a stable signing certificate is what makes it work across updates. These APIs are
  deprecated, and a wider list would let other apps read the password.
- **`kSecUseDataProtectionKeychain`**: this is the modern keychain (per-app access groups, no access-list
  prompts, `kSecAttrAccessible`). Outside the App Store it needs a `keychain-access-groups` entitlement, which
  needs an embedded Developer ID provisioning profile. Without one, calls fail with `errSecMissingEntitlement`
  (-34018), and ad-hoc builds can never use it.

Recommendation: keep the legacy keychain; with a stable certificate the prompts stop. Move to the data
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
