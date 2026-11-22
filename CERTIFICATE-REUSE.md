# Personal certificate reuse build

This fork starts from SideInstaller 2.1.1 (2e7bfe9) and includes FrizzleM's
siboot 0.20.1 (5f36332) as `bootstrap/`. Both projects retain their upstream
licenses and attribution. This is a personal build, not an upstream release.

- Certificate lookup errors stop signing before any new certificate request.
- Certificate matching uses the private key, including certificates without
  an Apple machine identifier.
- siboot reuses its saved key, then checks the selected account's key inside
  the installed SideInstaller. It can import a PKCS#12 export if needed.
- Existing certificates without an available private key cause an import
  prompt, never a revocation. A first certificate can still be created when
  the selected team has no certificates.
- After installation siboot hands only that account's signing key to the app,
  with read-back verification and a backup of any different existing key.
- The native app keeps signing keys in a device-only, nonsynchronizing
  Keychain item and restores them when its data directory has been removed.
  Keys belonging to Side by Side's temporary guest sessions are excluded.

The inherited `checks.yml` validates Rust, bootstrap and Swift tests. The
inherited `release-sideinstaller.yml` is run with `dry_run=true`; it publishes
no release. Its single artifact includes `CertificateReuseBuild/` outside the
IPA payload. The personal packaging script extracts the bootstrap and removes
those build-only members before delivering the standalone IPA.

`build-support/certificate-reuse.yml` is an optional build recipe, not an
enabled workflow. The current GitHub credential cannot add workflows.

No Apple password, pairing record, user certificate or private key belongs in
this repository or the downloadable package. A private key that was never
available locally cannot be reconstructed from an Apple certificate; it must
be exported from the tool that still holds it. Revoked certificates cannot be
reused. Keychain recovery requires the same signing team and app identifier.
