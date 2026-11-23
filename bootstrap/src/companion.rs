//! Layout and first-run handoff for LiveContainer's bundled SideStore and SideInstaller.

use std::path::Path;

use idevice::afc::AfcClient;
use plist::{Dictionary, Value};

use crate::fail::{Fail, Result};
use crate::{seed, ui};

pub const INSTALLER_HOME: &str = "/Documents/SideInstaller";
const STORE_HOME: &str = "/Documents/SideStore";
const STORE_PREFS: &str = "/Documents/SideStore/Library/Preferences/com.SideStore.SideStore.plist";
const REMOTE_KEYS: [&str; 4] = ["private_key", "public_key", "identifier", "alt_irk"];
const LOCKDOWN_KEYS: [&str; 10] = [
    "WiFiMACAddress", "SystemBUID", "RootPrivateKey", "HostPrivateKey", "HostID",
    "RootCertificate", "UDID", "EscrowBag", "HostCertificate", "DeviceCertificate",
];

pub struct Layout {
    pub installer_bundle_id: String,
    pub certificate: Option<(String, String)>,
}

impl Layout {
    pub fn inspect(app: &Path) -> Result<Option<Self>> {
        let installer = app.join("Frameworks/SideInstallerApp.framework/Info.plist");
        if !installer.is_file() { return Ok(None) }
        let store = bundle_id(&app.join("Frameworks/SideStoreApp.framework/Info.plist"))?;
        let host = bundle_id(&app.join("Info.plist"))?;
        let installer_bundle_id = bundle_id(&installer)?;
        let livecontainer = host == "com.kdt.livecontainer" || host.starts_with("com.kdt.livecontainer.");
        if store != "com.SideStore.SideStore" || !livecontainer {
            return Err(Fail::new("The companion package has an unexpected host or SideStore identifier.", "invalid companion layout"));
        }
        if !["com.frizzlem.sideinstaller", "com.frizzle.sideinstaller"].contains(&installer_bundle_id.as_str()) {
            return Err(Fail::new("The bundled SideInstaller identifier is not supported.", "invalid companion identifier"));
        }
        Ok(Some(Self { installer_bundle_id, certificate: None }))
    }
}

fn bundle_id(info: &Path) -> Result<String> {
    let fields: Dictionary = plist::from_file(info)
        .map_err(|e| Fail::new("Couldn't inspect the companion package.", e.to_string()))?;
    fields.get("CFBundleIdentifier").and_then(Value::as_string).map(str::to_string)
        .ok_or_else(|| Fail::new("A companion bundle has no identifier.", info.display().to_string()))
}

struct PairingRecords {
    remote: Vec<u8>,
    lockdown: Option<Vec<u8>>,
}

fn split_pairing(bytes: &[u8], udid: &str) -> Result<PairingRecords> {
    let fields: Dictionary = plist::from_bytes(bytes)
        .map_err(|e| Fail::new("The pairing file isn't a dictionary.", e.to_string()))?;
    let remote: Dictionary = fields.iter().filter(|(key, _)| REMOTE_KEYS.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone())).collect();
    if !REMOTE_KEYS[..3].iter().all(|key| remote.contains_key(*key)) {
        return Err(Fail::new("The bootstrap pairing file has no complete remote pairing record.", "missing remote pairing fields"));
    }
    let mut lockdown: Dictionary = fields.into_iter().filter(|(key, _)| !REMOTE_KEYS.contains(&key.as_str())).collect();
    if !udid.is_empty() && !lockdown.contains_key("UDID") {
        lockdown.insert("UDID".into(), udid.into());
    }
    let lockdown = if LOCKDOWN_KEYS.iter().all(|key| lockdown.contains_key(*key)) {
        Some(xml(&lockdown)?)
    } else { None };
    Ok(PairingRecords { remote: xml(&remote)?, lockdown })
}

fn xml(fields: &Dictionary) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    plist::to_writer_xml(&mut bytes, fields)
        .map_err(|e| Fail::new("Couldn't encode the pairing handoff.", e.to_string()))?;
    Ok(bytes)
}

fn update_settings(prefs: &mut Dictionary, server: &str, device_ip: &str) {
    prefs.insert("isPairingReset".into(), false.into());
    prefs.insert("activePairingProtocol".into(), "rppairing".into());
    if prefs.get("LCCombinedBootstrapSeeded").and_then(Value::as_boolean) != Some(true) {
        prefs.insert("LCCombinedBootstrapPending".into(), true.into());
        prefs.insert("LCCombinedBootstrapSeeded".into(), true.into());
    }
    if !prefs.contains_key("menuAnisetteURL") {
        prefs.insert("menuAnisetteURL".into(), server.into());
        prefs.insert("useOnDeviceAnisette".into(), false.into());
        prefs.insert("disableAnisetteRotation".into(), true.into());
    }
    if !prefs.contains_key("tunnelOverridePeerIp") {
        prefs.insert("tunnelOverridePeerIp".into(), device_ip.into());
    }
}

fn update_certificate(prefs: &mut Dictionary, serial: &str, password: &str) {
    let changed = prefs.get("LCCombinedBootstrapLastCertificateSerial").and_then(Value::as_string)
        .is_some_and(|previous| previous != serial);
    if changed { prefs.insert("LCCombinedBootstrapPending".into(), true.into()); }
    prefs.insert("LCCombinedBootstrapLastCertificateSerial".into(), serial.into());
    if prefs.get("LCCombinedBootstrapPending").and_then(Value::as_boolean) == Some(true) {
        prefs.insert("LCCombinedBootstrapCertificateSerial".into(), serial.into());
        prefs.insert("LCCombinedBootstrapCertificatePassword".into(), password.into());
    } else {
        prefs.remove("LCCombinedBootstrapCertificateSerial");
        prefs.remove("LCCombinedBootstrapCertificatePassword");
    }
}

pub async fn hand_over_store(afc: &mut AfcClient, pairing: &[u8], udid: &str,
                             server: &str, device_ip: &str, layout: &Layout) -> Result<()> {
    let records = split_pairing(pairing, udid)?;
    let docs = format!("{STORE_HOME}/Documents");
    seed::create_directories(afc, &docs).await?;
    seed::write_atomic(afc, &format!("{docs}/PairingFile_RemoteRP.plist"), &records.remote).await?;
    seed::write_atomic(afc, &format!("{docs}/ALTPairingFile.mobiledevicepairing"), pairing).await?;
    if let Some(lockdown) = records.lockdown {
        seed::write_atomic(afc, &format!("{docs}/PairingFile_Lockdown.plist"), &lockdown).await?;
    }
    let mut prefs = seed::read_preferences(afc, STORE_PREFS).await?;
    update_settings(&mut prefs, server, device_ip);
    let (serial, password) = layout.certificate.as_ref()
        .ok_or_else(|| Fail::new("The signing identity was not retained for SideStore setup.", "missing certificate handoff"))?;
    update_certificate(&mut prefs, serial, password);
    seed::write_preferences(afc, STORE_PREFS, &prefs).await?;
    save_server(afc, &docs, server).await?;
    ui::ok("SideStore has the pairing; sign in there to take over renewal with the bundled certificate");
    Ok(())
}

async fn save_server(afc: &mut AfcClient, docs: &str, server: &str) -> Result<()> {
    let path = format!("{docs}/anisette-servers.json");
    let mut servers: Vec<serde_json::Value> = match seed::read_if_present(afc, &path).await? {
        Some(bytes) => serde_json::from_slice(&bytes)
            .map_err(|e| Fail::new("The saved SideStore anisette list is invalid; it was not replaced.", e.to_string()))?,
        None => Vec::new(),
    };
    if servers.iter().any(|item| item["address"].as_str() == Some(server)) { return Ok(()) }
    servers.push(serde_json::json!({"name": "Bootstrap signing server", "address": server, "isHidden": false}));
    let bytes = serde_json::to_vec_pretty(&servers)
        .map_err(|e| Fail::new("Couldn't encode the anisette server list.", e.to_string()))?;
    seed::write_atomic(afc, &path, &bytes).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn remote() -> Dictionary {
        let mut fields = Dictionary::new();
        fields.insert("private_key".into(), Value::Data(vec![1; 32]));
        fields.insert("public_key".into(), Value::Data(vec![2; 32]));
        fields.insert("identifier".into(), "test-host".into());
        fields.insert("alt_irk".into(), Value::Data(vec![3; 16]));
        fields
    }

    #[test]
    fn splits_combined_pairing_without_mixing_protocols() {
        let mut fields = remote();
        for key in LOCKDOWN_KEYS { fields.insert(key.into(), "test".into()); }
        fields.remove("UDID");
        let records = split_pairing(&xml(&fields).unwrap(), "test-udid").unwrap();
        let rp: Dictionary = plist::from_bytes(&records.remote).unwrap();
        let ld: Dictionary = plist::from_bytes(records.lockdown.as_ref().unwrap()).unwrap();
        assert_eq!(rp.len(), 4);
        assert!(!rp.contains_key("HostID"));
        assert!(!ld.contains_key("private_key"));
        assert_eq!(ld["UDID"].as_string(), Some("test-udid"));
    }

    #[test]
    fn remote_only_pairing_never_creates_a_lockdown_file() {
        let records = split_pairing(&xml(&remote()).unwrap(), "test-udid").unwrap();
        assert!(records.lockdown.is_none());
        let mut fields = remote();
        fields.remove("private_key");
        assert!(split_pairing(&xml(&fields).unwrap(), "test-udid").is_err());
    }

    #[test]
    fn a_completed_takeover_is_not_requested_again() {
        let mut prefs = Dictionary::new();
        update_settings(&mut prefs, "https://first.example", "10.7.0.1");
        assert_eq!(prefs["LCCombinedBootstrapPending"].as_boolean(), Some(true));
        prefs.remove("LCCombinedBootstrapPending");
        prefs.insert("preferredPairingProtocol".into(), "rppairing".into());
        update_settings(&mut prefs, "https://next.example", "10.7.0.2");
        assert!(!prefs.contains_key("LCCombinedBootstrapPending"));
        assert_eq!(prefs["menuAnisetteURL"].as_string(), Some("https://first.example"));
        assert_eq!(prefs["preferredPairingProtocol"].as_string(), Some("rppairing"));
    }

    #[test]
    fn certificate_handoff_is_temporary_and_rotating_the_certificate_requests_takeover() {
        let mut prefs = Dictionary::new();
        update_settings(&mut prefs, "https://first.example", "10.7.0.1");
        update_certificate(&mut prefs, "TEST01", "");
        assert_eq!(prefs["LCCombinedBootstrapCertificatePassword"].as_string(), Some(""));
        prefs.remove("LCCombinedBootstrapPending");
        update_settings(&mut prefs, "https://first.example", "10.7.0.1");
        update_certificate(&mut prefs, "TEST01", "");
        assert!(!prefs.contains_key("LCCombinedBootstrapPending"));
        assert!(!prefs.contains_key("LCCombinedBootstrapCertificatePassword"));
        update_certificate(&mut prefs, "TEST02", "fixture-only");
        assert_eq!(prefs["LCCombinedBootstrapPending"].as_boolean(), Some(true));
        assert_eq!(prefs["LCCombinedBootstrapCertificateSerial"].as_string(), Some("TEST02"));
    }

    #[test]
    fn detects_the_companion_without_reinterpreting_standalone_installs() {
        let directory = std::env::temp_dir().join(format!("siboot-layout-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        assert!(Layout::inspect(&directory).unwrap().is_none());
        for (relative, identifier) in [
            ("", "com.kdt.livecontainer.TEAMID1234"),
            ("Frameworks/SideStoreApp.framework", "com.SideStore.SideStore"),
            ("Frameworks/SideInstallerApp.framework", "com.frizzlem.sideinstaller"),
        ] {
            let folder = directory.join(relative);
            std::fs::create_dir_all(&folder).unwrap();
            let mut info = Dictionary::new();
            info.insert("CFBundleIdentifier".into(), identifier.into());
            plist::to_file_binary(folder.join("Info.plist"), &info).unwrap();
        }
        let layout = Layout::inspect(&directory).unwrap().unwrap();
        assert_eq!(layout.installer_bundle_id, "com.frizzlem.sideinstaller");
        std::fs::remove_file(directory.join("Frameworks/SideStoreApp.framework/Info.plist")).unwrap();
        assert!(Layout::inspect(&directory).is_err());
        std::fs::remove_dir_all(directory).unwrap();
    }
}
