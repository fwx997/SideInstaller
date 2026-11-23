//! Step 7: hand the newly installed SideInstaller this pairing, as Side by Side
//! hands one to SideInstaller on another iPhone
//! (`SideBySideView.handOffToSideInstaller`): the file goes where SideInstaller
//! keeps its own (`PrivateStore.pairingFile`), a merged file from an older
//! pairing is deleted, and the file is marked as imported, so SideInstaller
//! connects with it from its first launch instead of pairing itself.
//!
//! house_arrest vends the whole container because the app is signed for
//! development; Application Support is outside Documents, and SideInstaller
//! only moves a pairing file out of Documents when it has none of its own.

use std::path::Path;

use idevice::afc::opcode::AfcFopenMode;
use idevice::afc::AfcClient;
use idevice::house_arrest::HouseArrestClient;
use idevice::RsdService;

use crate::fail::{chain, Fail, Result};
use crate::tunnel::Connection;
use crate::ui;

pub const PAIRING_PATH: &str = "/Library/Application Support/rp_pairing_file.plist";
const MERGED_PATH: &str = "/Library/Application Support/combined_pairing_file.plist";
/// `Engine.importedPairingNameKey`.
const IMPORTED_NAME_KEY: &str = "importedPairingFileName";
/// The name SideInstaller shows the file under, as it shows "SideBySide.plist"
/// for one Side by Side hands over.
const HANDED_OVER_NAME: &str = "siboot.plist";

pub async fn hand_over(
    connection: &mut Connection,
    bundle_id: &str,
    pairing_path: &Path,
    session: &crate::account::Session,
    companion: Option<&crate::companion::Layout>,
    udid: &str,
    device_ip: &str,
) -> Result<()> {
    ui::activity("opening the installed app's container");
    let pairing = std::fs::read(pairing_path).map_err(|e| {
        Fail::new(
            format!("Couldn't read {}.", pairing_path.display()),
            e.to_string(),
        )
    })?;

    let house_arrest =
        HouseArrestClient::connect_rsd(&mut connection.adapter, &mut connection.handshake)
            .await
            .map_err(|e| Fail::new("Couldn't reach house_arrest on this iPhone.", chain(&e)))?;
    let mut afc = house_arrest.vend_container(bundle_id).await.map_err(|e| {
        Fail::new(
            format!("Couldn't open {bundle_id}'s container. Run siboot again to complete setup; the pairing and signing key remain in ~/.siboot."),
            chain(&e),
        )
    })?;

    let installer_home = companion.map(|_| crate::companion::INSTALLER_HOME).unwrap_or("");
    create_directories(&mut afc, &format!("{installer_home}/Library/Application Support")).await?;
    ui::activity("writing the pairing file into it");
    let written = write_atomic(&mut afc, &format!("{installer_home}{PAIRING_PATH}"), &pairing).await?;
    ui::ok(&format!(
        "pairing file written into SideInstaller ({written} bytes, read back and checked)"
    ));
    crate::identity::hand_over(&mut afc, session, installer_home).await?;

    // There's none on a fresh install; one from an older pairing would hand
    // other apps that pairing.
    let _ = afc.remove(format!("{installer_home}{MERGED_PATH}")).await;

    let installer_id = companion.map(|layout| layout.installer_bundle_id.as_str()).unwrap_or(bundle_id);
    let prefs_path = format!("{installer_home}/Library/Preferences/{installer_id}.plist");
    match mark_imported(&mut afc, &prefs_path, &session.anisette_server, device_ip).await {
        Ok(()) => ui::detail(&format!(
            "marked it as the imported file \"{HANDED_OVER_NAME}\" ({prefs_path})"
        )),
        Err(e) => {
            ui::warn(
                "Couldn't mark the pairing file as imported. SideInstaller still connects with it, \
                 but may offer to pair again.",
            );
            ui::detail(&e.raw);
        }
    }
    if let Some(layout) = companion {
        crate::companion::hand_over_store(&mut afc, &pairing, udid, &session.anisette_server, device_ip, layout).await?;
    }
    Ok(())
}

/// Set `importedPairingFileName` in SideInstaller's preferences, keeping what's
/// there. Written beside the file and renamed over it, so a broken upload can't
/// leave a half-written preferences file.
async fn mark_imported(afc: &mut AfcClient, prefs_path: &str, server: &str, device_ip: &str) -> Result<()> {
    let mut prefs = read_preferences(afc, prefs_path).await?;
    prefs.insert(IMPORTED_NAME_KEY.into(), HANDED_OVER_NAME.into());
    if !prefs.contains_key("anisetteServerURL") {
        prefs.insert("anisetteServerURL".into(), server.into());
    }
    if !prefs.contains_key("deviceIP") {
        prefs.insert("deviceIP".into(), device_ip.into());
    }
    write_preferences(afc, prefs_path, &prefs).await
}

pub(crate) async fn read_preferences(afc: &mut AfcClient, path: &str) -> Result<plist::Dictionary> {
    match read_if_present(afc, path).await? {
        Some(bytes) if !bytes.is_empty() => plist::from_bytes::<plist::Dictionary>(&bytes)
            .map_err(|e| Fail::new("The app's preferences aren't a plist; they were not replaced.", e.to_string())),
        _ => Ok(plist::Dictionary::new()),
    }
}

pub(crate) async fn write_preferences(afc: &mut AfcClient, prefs_path: &str, prefs: &plist::Dictionary) -> Result<()> {
    let mut bytes = Vec::new();
    plist::to_writer_binary(&mut bytes, prefs).map_err(|e| {
        Fail::new(
            "Couldn't encode SideInstaller's preferences.",
            e.to_string(),
        )
    })?;
    let directory = prefs_path.rsplit_once('/').map(|(parent, _)| parent).unwrap_or("/");
    create_directories(afc, directory).await?;
    let staging = format!("{prefs_path}.siboot");
    write_verified(afc, &staging, &bytes).await?;
    afc.rename(staging, prefs_path)
        .await
        .map_err(|e| Fail::new("Couldn't save SideInstaller's preferences.", chain(&e)))?;
    Ok(())
}

pub(crate) async fn create_directories(afc: &mut AfcClient, path: &str) -> Result<()> {
    let mut current = String::new();
    for part in path.split('/').filter(|part| !part.is_empty()) {
        current.push('/');
        current.push_str(part);
        if let Err(error) = afc.mk_dir(current.clone()).await {
            if afc.get_file_info(current.clone()).await.is_err() {
                return Err(Fail::new(format!("Couldn't create {current}."), chain(&error)));
            }
        }
    }
    Ok(())
}

pub(crate) async fn read_if_present(afc: &mut AfcClient, path: &str) -> Result<Option<Vec<u8>>> {
    match afc.get_file_info(path).await {
        Ok(_) => (),
        Err(idevice::IdeviceError::Afc(idevice::afc::errors::AfcError::ObjectNotFound)) => return Ok(None),
        Err(error) => return Err(Fail::new(format!("Couldn't inspect {path}. It was not replaced."), chain(&error))),
    }
    let mut file = afc
        .open(path, AfcFopenMode::RdOnly)
        .await
        .map_err(|e| Fail::new(format!("Couldn't open {path}."), chain(&e)))?;
    let bytes = file
        .read_entire()
        .await
        .map_err(|e| Fail::new(format!("Couldn't read {path}."), chain(&e)))?;
    let _ = file.close().await;
    Ok(Some(bytes))
}

pub(crate) async fn write_atomic(afc: &mut AfcClient, path: &str, data: &[u8]) -> Result<usize> {
    let pending = format!("{path}.pending-siboot-{}", uuid::Uuid::new_v4());
    let written = write_verified(afc, &pending, data).await?;
    afc.rename(&pending, path).await
        .map_err(|e| Fail::new(format!("Couldn't activate {path}; the previous copy was retained."), chain(&e)))?;
    Ok(written)
}

/// Write `data` to `path`, then read it back and compare. Returns its length.
pub(crate) async fn write_verified(afc: &mut AfcClient, path: &str, data: &[u8]) -> Result<usize> {
    let mut file = afc
        .open(path, AfcFopenMode::WrOnly)
        .await
        .map_err(|e| Fail::new(format!("Couldn't create {path}."), chain(&e)))?;
    file.write_entire(data)
        .await
        .map_err(|e| Fail::new(format!("Couldn't write {path}."), chain(&e)))?;
    file.close()
        .await
        .map_err(|e| Fail::new(format!("Couldn't write {path}."), chain(&e)))?;
    match read_if_present(afc, path).await? {
        Some(back) if back == data => Ok(data.len()),
        Some(back) => Err(Fail::new(
            format!("{path} reads back different from what was written."),
            format!("wrote {} bytes, read {}", data.len(), back.len()),
        )),
        None => Err(Fail::new(format!("{path} vanished after writing."), "")),
    }
}
