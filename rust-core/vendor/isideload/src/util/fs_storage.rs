use std::path::{Path, PathBuf};

use rootcause::prelude::*;
use rsa::{pkcs8::DecodePrivateKey, RsaPrivateKey};

use crate::util::storage::SideloadingStorage;

pub struct FsStorage {
    path: PathBuf,
}

impl FsStorage {
    pub fn new(path: PathBuf) -> Self {
        FsStorage { path }
    }

    fn sync_signing_key(&self, key: &str, mode: i32) -> Result<(), Report> {
        #[cfg(target_os = "ios")]
        {
            use std::ffi::CString;
            unsafe extern "C" {
                fn si_signing_key_sync(
                    root: *const std::ffi::c_char,
                    key: *const std::ffi::c_char,
                    mode: i32,
                ) -> i32;
            }
            if !is_signing_key(key) {
                return Ok(());
            }
            let root = CString::new(self.path.to_string_lossy().as_bytes())?;
            let key = CString::new(key)?;
            let status = unsafe { si_signing_key_sync(root.as_ptr(), key.as_ptr(), mode) };
            if status != 0 {
                bail!("Couldn't restore or preserve the signing key in this device's Keychain (error {status}); unlock this device and retry instead of replacing its certificate");
            }
        }
        #[cfg(not(target_os = "ios"))]
        let _ = (key, mode);
        Ok(())
    }
}

fn is_signing_key(key: &str) -> bool {
    let Some((account, name)) = key.split_once('/') else { return false };
    name == "key" && account.len() == 64 && account.bytes().all(|b| b.is_ascii_hexdigit())
}

fn validate_signing_key(key: &str, data: &[u8]) -> Result<(), Report> {
    if is_signing_key(key) {
        RsaPrivateKey::from_pkcs8_der(data).context("The saved signing key is damaged; it was not replaced")?;
    }
    Ok(())
}

impl Default for FsStorage {
    fn default() -> Self {
        Self::new(PathBuf::from("."))
    }
}

impl SideloadingStorage for FsStorage {
    fn store_data(&self, key: &str, data: &[u8]) -> Result<(), Report> {
        validate_signing_key(key, data)?;
        let path = self.path.join(key);
        let parent = path.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(parent).context("Failed to create storage directory")?;
        std::fs::write(&path, data).context("Failed to write data to file")?;
        self.sync_signing_key(key, 2)?;

        Ok(())
    }

    fn retrieve_data(&self, key: &str) -> Result<Option<Vec<u8>>, Report> {
        self.sync_signing_key(key, 1)?;
        let path = self.path.join(key);
        match std::fs::read(&path) {
            Ok(data) => {
                validate_signing_key(key, &data)?;
                // Also adopts an existing installation or a key handed over
                // by siboot. Invalid bytes never overwrite the Keychain copy.
                self.sync_signing_key(key, 2)?;
                Ok(Some(data))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(report!(e).context("Failed to read data from file").into()),
        }
    }

    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.store_data(key, value.as_bytes())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        match self.retrieve_data(key) {
            Ok(Some(data)) => Ok(Some(String::from_utf8_lossy(&data).into_owned())),
            Ok(None) => Ok(None),
            Err(e) => Err(e),
        }
    }
}
