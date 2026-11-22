//! Reuse the selected account's existing key, including one held by an
//! installed SideInstaller. Key bytes stay on this device throughout.

use std::io::Write;
use std::path::Path;
use std::time::Duration;

use idevice::{afc::AfcClient, house_arrest::HouseArrestClient, RsdService};
use isideload::dev::certificates::{CertificatesApi, DevelopmentCertificate};
use isideload::sideload::cert_identity::CertificateIdentity;
use rsa::{pkcs8::{DecodePrivateKey, EncodePrivateKey}, RsaPrivateKey};

use crate::account::Session;
use crate::fail::{Fail, Result};
use crate::{apple_session, seed, tunnel, ui, Args};

const MAX_KEY_BYTES: u64 = 16384;

pub async fn prepare(args: &Args, session: &mut Session) -> Result<()> {
    ui::status("checking for a reusable signing certificate");
    let certs = session.developer.list_ios_certs(&session.selected_team).await.map_err(|e| {
        Fail::new("Couldn't check Apple's certificates. Retry when the connection works; no certificate was requested or revoked.",
                  crate::error_text::report_text(&e))
    })?;
    if let Some(path) = &args.certificate {
        return import_archive(args, session, &certs, path);
    }
    if use_saved_key(session, &certs)? { return Ok(()) }
    if certs.is_empty() {
        ui::status("this team has no certificate yet; signing will create its first one");
        return Ok(());
    }
    match tokio::time::timeout(Duration::from_secs(25), from_installed_app(args, session, &certs)).await {
        Ok(Ok(true)) => return Ok(()),
        Ok(Ok(false)) => (),
        Ok(Err(error)) => ui::detail(&error.advice),
        Err(_) => ui::detail("The installed SideInstaller did not answer in time."),
    }
    ui::note("This account already has a certificate. To reuse it, import the .p12 exported by SideInstaller or SideStore, including its private key. Nothing will be revoked.");
    let path = ui::ask_text("Reuse an existing certificate", "P12 path in Open Minis", "/root/certificate.p12",
                            "Path to the existing .p12 (empty to stop): ")
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| Fail::by_user("No reusable private key was available. Export the existing certificate as .p12, copy it into Open Minis, then run siboot --certificate /path/certificate.p12. No certificate was revoked."))?;
    import_archive(args, session, &certs, Path::new(path.trim()))
}

fn matches(key: &RsaPrivateKey, certs: &[DevelopmentCertificate]) -> Result<bool> {
    CertificateIdentity::matching_certificate(key, certs)
        .map(|found| found.is_some())
        .map_err(|e| Fail::new("Couldn't read Apple's certificate list. No certificate was replaced.",
                               crate::error_text::report_text(&e)))
}

fn use_saved_key(session: &Session, certs: &[DevelopmentCertificate]) -> Result<bool> {
    let directory = apple_session::account_dir(&session.storage, &session.apple_id);
    let current = directory.join("key");
    if let Some(key) = read_key(&current)? {
        if matches(&key, certs)? {
            ui::ok("reusing the saved signing certificate");
            return Ok(true);
        }
    }
    let backups = match std::fs::read_dir(&directory) {
        Ok(entries) => entries.filter_map(|e| e.ok()).map(|e| e.path())
            .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("key.replaced-")))
            .collect::<Vec<_>>(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(Fail::new("Couldn't read the saved signing identities.", e.to_string())),
    };
    for backup in backups.iter().take(32) {
        let Some(key) = read_key(backup)? else { continue };
        if matches(&key, certs)? {
            save_key(&current, &key)?;
            ui::ok("restored the private key for the existing certificate");
            return Ok(true);
        }
    }
    Ok(false)
}

fn read_key(path: &Path) -> Result<Option<RsaPrivateKey>> {
    let metadata = match std::fs::metadata(path) {
        Ok(value) => value,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(Fail::new("Couldn't read the saved signing key.", e.to_string())),
    };
    if !metadata.is_file() || metadata.len() > MAX_KEY_BYTES {
        return Err(Fail::new("The saved signing key has an invalid size; it was left unchanged.", "invalid key file"));
    }
    let data = std::fs::read(path).map_err(|e| Fail::new("Couldn't read the saved signing key.", e.to_string()))?;
    RsaPrivateKey::from_pkcs8_der(&data).map(Some)
        .map_err(|e| Fail::new("The saved signing key is damaged; it was left unchanged.", e.to_string()))
}

fn import_archive(args: &Args, session: &Session, certs: &[DevelopmentCertificate], path: &Path) -> Result<()> {
    let metadata = std::fs::metadata(path).map_err(|e| Fail::new("Couldn't read that .p12 file in Open Minis.", e.to_string()))?;
    if !metadata.is_file() || metadata.len() > 1024 * 1024 {
        return Err(Fail::new("Choose a .p12 certificate file smaller than 1 MB.", "invalid certificate file size"));
    }
    let data = std::fs::read(path).map_err(|e| Fail::new("Couldn't read that .p12 file.", e.to_string()))?;
    let keys = match &args.certificate_password_file {
        Some(path) => {
            let password = std::fs::read_to_string(path).map_err(|e| Fail::new("Couldn't read the certificate password file.", e.to_string()))?;
            crate::p12::signing_keys(&data, password.trim_end_matches(['\r', '\n']))
        }
        None => open_archive(&data)?,
    }.map_err(|e| Fail::new("Couldn't open the .p12. Check its password and that it includes the private key.", e))?;
    for archived in keys {
        if matches(&archived.key, certs)? {
            let path = apple_session::account_dir(&session.storage, &session.apple_id).join("key");
            save_key(&path, &archived.key)?;
            ui::ok("imported the existing certificate's private key; nothing was revoked");
            return Ok(());
        }
    }
    Err(Fail::new("That .p12 does not match an existing certificate on the selected team. It may have been revoked or belong to another account; the current key was left unchanged.", "No matching certificate on the selected team"))
}

fn open_archive(data: &[u8]) -> Result<std::result::Result<Vec<crate::p12::ArchiveKey>, String>> {
    if let Ok(keys) = crate::p12::signing_keys(data, "") { return Ok(Ok(keys)) }
    let password = ui::ask_secret("Certificate export password", "P12 password", "", "P12 password: ")
        .map_err(|e| Fail::new("Couldn't read the certificate password.", e.to_string()))?
        .ok_or_else(|| Fail::by_user("Certificate import cancelled; nothing was changed."))?;
    Ok(crate::p12::signing_keys(data, &password))
}

async fn from_installed_app(args: &Args, session: &Session, certs: &[DevelopmentCertificate]) -> Result<bool> {
    ui::status("looking for the existing key in SideInstaller on this device");
    let mut connection = tunnel::open(args.device, &args.pairing_path()).await?;
    let account = relative_key(session)?;
    for base in ["com.frizzlem.sideinstaller", "com.frizzle.sideinstaller"] {
        let bundle_id = format!("{base}.{}", session.selected_team.team_id);
        let house = HouseArrestClient::connect_rsd(&mut connection.adapter, &mut connection.handshake).await;
        let Ok(house) = house else { continue };
        let Ok(mut afc) = house.vend_container(&bundle_id).await else { continue };
        if adopt_from_container(&mut afc, session, certs, &account).await? { return Ok(true) }
    }
    Ok(false)
}

async fn adopt_from_container(afc: &mut AfcClient, session: &Session, certs: &[DevelopmentCertificate], relative: &str) -> Result<bool> {
    for root in ["/Library/Application Support/isideload", "/Documents/isideload"] {
        let path = format!("{root}/{relative}");
        let Some(data) = read_remote_key(afc, &path).await? else { continue };
        let Ok(key) = RsaPrivateKey::from_pkcs8_der(&data) else { continue };
        if matches(&key, certs)? {
            let local = session.storage.join(relative);
            save_key(&local, &key)?;
            ui::ok("reusing SideInstaller's existing signing certificate");
            return Ok(true);
        }
    }
    Ok(false)
}

async fn read_remote_key(afc: &mut AfcClient, path: &str) -> Result<Option<Vec<u8>>> {
    let Ok(info) = afc.get_file_info(path.to_string()).await else { return Ok(None) };
    if info.size as u64 > MAX_KEY_BYTES { return Ok(None) }
    seed::read_if_present(afc, path).await
}

fn relative_key(session: &Session) -> Result<String> {
    let directory = apple_session::account_dir(&session.storage, &session.apple_id);
    let account = directory.file_name().and_then(|n| n.to_str())
        .ok_or_else(|| Fail::new("Couldn't locate the account's signing key.", "invalid account directory"))?;
    Ok(format!("{account}/key"))
}

fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|e| Fail::new("Couldn't save the signing key.", e.to_string()))?;
    file.write_all(bytes).and_then(|_| file.sync_all())
        .map_err(|e| Fail::new("Couldn't save the signing key.", e.to_string()))
}

fn save_key(path: &Path, key: &RsaPrivateKey) -> Result<()> {
    let data = key.to_pkcs8_der().map_err(|e| Fail::new("Couldn't encode the signing key.", e.to_string()))?;
    let directory = path.parent().ok_or_else(|| Fail::new("Couldn't save the signing key.", "missing directory"))?;
    std::fs::create_dir_all(directory).map_err(|e| Fail::new("Couldn't create the signing key folder.", e.to_string()))?;
    match std::fs::read(path) {
        Ok(old) if old == data.as_bytes() => return Ok(()),
        Ok(old) => write_private(&directory.join(format!("key.replaced-{}", uuid::Uuid::new_v4())), &old)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
        Err(e) => return Err(Fail::new("Couldn't preserve the previous signing key.", e.to_string())),
    }
    let temporary = directory.join(format!("key.pending-{}", uuid::Uuid::new_v4()));
    write_private(&temporary, data.as_bytes())?;
    std::fs::rename(&temporary, path).map_err(|e| Fail::new("Couldn't activate the imported signing key.", e.to_string()))
}

pub async fn hand_over(afc: &mut AfcClient, session: &Session) -> Result<()> {
    let relative = relative_key(session)?;
    let local = session.storage.join(&relative);
    let key = read_key(&local)?.ok_or_else(|| Fail::new("The signing key is missing after signing.", "missing key"))?;
    let data = key.to_pkcs8_der().map_err(|e| Fail::new("Couldn't encode the signing key.", e.to_string()))?;
    let root = "/Library/Application Support/isideload";
    let directory = format!("{root}/{}", relative.trim_end_matches("/key"));
    let target = format!("{root}/{relative}");
    let _ = afc.mk_dir(root).await;
    let _ = afc.mk_dir(directory.clone()).await;
    if let Some(existing) = read_remote_key(afc, &target).await? {
        if existing == data.as_bytes() {
            ui::ok("SideInstaller already has the shared signing key");
            return Ok(());
        }
        let backup = format!("{directory}/key.replaced-siboot-{}", uuid::Uuid::new_v4());
        seed::write_verified(afc, &backup, &existing).await?;
    }
    let pending = format!("{directory}/key.pending-{}", uuid::Uuid::new_v4());
    seed::write_verified(afc, &pending, data.as_bytes()).await?;
    afc.rename(&pending, &target).await.map_err(|e| Fail::new("Couldn't hand SideInstaller its signing key.", crate::fail::chain(&e)))?;
    ui::ok("signing key handed to SideInstaller; future installs can reuse this certificate");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use plist::Dictionary;

    fn portal_certificate() -> DevelopmentCertificate {
        let mut fields = Dictionary::new();
        fields.insert("certContent".into(), plist::Value::Data(include_bytes!("../../rust-core/testdata/p12/cert.der").to_vec()));
        plist::from_value(&plist::Value::Dictionary(fields)).unwrap()
    }

    #[test]
    fn reuses_a_certificate_without_a_machine_id_but_never_another_private_key() {
        let key = RsaPrivateKey::from_pkcs8_der(include_bytes!("../../rust-core/testdata/p12/key.pk8")).unwrap();
        let other = RsaPrivateKey::from_pkcs8_der(include_bytes!("../../rust-core/testdata/p12/other-key.pk8")).unwrap();
        let certificates = vec![portal_certificate()];
        assert!(matches(&key, &certificates).unwrap());
        assert!(!matches(&other, &certificates).unwrap());
        assert!(!matches(&key, &[]).unwrap());
    }

    #[test]
    fn replacing_a_key_keeps_the_old_one_and_reusing_it_does_not_add_backups() {
        let root = std::env::temp_dir().join(format!("siboot-key-{}", uuid::Uuid::new_v4()));
        let path = root.join("key");
        let first = RsaPrivateKey::from_pkcs8_der(include_bytes!("../../rust-core/testdata/p12/key.pk8")).unwrap();
        let second = RsaPrivateKey::from_pkcs8_der(include_bytes!("../../rust-core/testdata/p12/other-key.pk8")).unwrap();
        save_key(&path, &first).unwrap();
        save_key(&path, &second).unwrap();
        save_key(&path, &second).unwrap();
        let files = std::fs::read_dir(&root).unwrap().map(|e| e.unwrap().path()).collect::<Vec<_>>();
        assert_eq!(files.len(), 2);
        let backup = files.iter().find(|p| **p != path).unwrap();
        assert_eq!(read_key(backup).unwrap().unwrap().to_public_key(), first.to_public_key());
        assert_eq!(read_key(&path).unwrap().unwrap().to_public_key(), second.to_public_key());
        std::fs::remove_dir_all(root).unwrap();
    }
}
