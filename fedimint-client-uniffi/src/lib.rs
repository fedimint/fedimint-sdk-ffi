//! UniFFI SDK that exposes a high-level `FedimintSDK` and per-federation
//! `Client` objects to FFI consumers.
//!
//! The module functions themselves live in the `fedimint` workspace (e.g.
//! `fedimint-ln-client`, `fedimint-mint-client`, ...). This crate is the
//! thin cross-crate FFI bridge that composes them.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Arc;
#[cfg(target_os = "android")]
use std::sync::Once;

use anyhow::Context;
use fedimint_bip39::{Bip39RootSecretStrategy, Mnemonic};
use fedimint_client::secret::RootSecretStrategy;
use fedimint_client::{ClientHandle, ClientHandleArc, ClientPreview, RootSecret};
use fedimint_connectors::ConnectorRegistry;
use fedimint_core::config::FederationId;
use fedimint_core::db::{Database, IDatabaseTransactionOpsCoreTyped};
use fedimint_core::encoding::{Decodable, Encodable};
use fedimint_core::impl_db_record;
use fedimint_core::invite_code::InviteCode;
use fedimint_derive_secret::{ChildId, DerivableSecret};
use fedimint_ln_client::{LightningClientInit, LightningClientModule};
use fedimint_meta_client::MetaClientInit;
use fedimint_mint_client::MintClientInit;
use fedimint_wallet_client::WalletClientInit;
use log::{debug, error, info, warn};
use tokio::sync::Mutex;

/// Logging verbosity level exposed to FFI consumers.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum LogLevel {
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}

impl From<LogLevel> for log::LevelFilter {
    fn from(level: LogLevel) -> Self {
        match level {
            LogLevel::Error => log::LevelFilter::Error,
            LogLevel::Warn  => log::LevelFilter::Warn,
            LogLevel::Info  => log::LevelFilter::Info,
            LogLevel::Debug => log::LevelFilter::Debug,
            LogLevel::Trace => log::LevelFilter::Trace,
        }
    }
}

// Force the linker to pull in our strong sdallocx stub from sdallocx_stub.c.
// On Android, aws-lc declares sdallocx as a weak symbol. The Android linker
// resolves weak GLOB_DAT entries to the PLT stub (non-NULL) while JUMP_SLOT
// stays 0 → SIGSEGV. Our stub provides a strong definition that delegates to free().
#[cfg(target_os = "android")]
extern "C" {
    fn sdallocx(ptr: *mut std::ffi::c_void, size: usize, flags: i32);
}

#[cfg(target_os = "android")]
#[used]
static FORCE_SDALLOCX: unsafe extern "C" fn(*mut std::ffi::c_void, usize, i32) = sdallocx;

uniffi::setup_scaffolding!();

const DB_DIR_NAME: &str = "fedimint_db";

#[cfg(target_os = "android")]
fn install_android_panic_hook_with_level(level: log::LevelFilter) {
    static PANIC_HOOK_ONCE: Once = Once::new();

    PANIC_HOOK_ONCE.call_once(|| {
        android_logger::init_once(
            android_logger::Config::default()
                .with_tag("fedimint-uniffi")
                .with_max_level(level),
        );

        std::panic::set_hook(Box::new(|panic_info| {
            let location = panic_info
                .location()
                .map(|loc| format!("{}:{}:{}", loc.file(), loc.line(), loc.column()))
                .unwrap_or_else(|| "<unknown location>".to_string());

            let payload = if let Some(s) = panic_info.payload().downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = panic_info.payload().downcast_ref::<String>() {
                s.clone()
            } else {
                "<non-string panic payload>".to_string()
            };

            let backtrace = std::backtrace::Backtrace::force_capture();
            error!(
                "Rust panic in fedimint-client-uniffi at {}: {}\nBacktrace:\n{}",
                location, payload, backtrace
            );
        }));

        info!("fedimint-client-uniffi Android logging initialized");
    });
}

#[cfg(target_os = "android")]
fn install_android_panic_hook() {
    install_android_panic_hook_with_level(log::LevelFilter::Info);
}

#[cfg(not(target_os = "android"))]
fn install_android_panic_hook() {}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FedimintError {
    #[error("{msg}")]
    General { msg: String },
}

fn err<E: std::fmt::Display>(e: E) -> FedimintError {
    FedimintError::General { msg: e.to_string() }
}

#[repr(u8)]
#[derive(Clone, Copy, Debug)]
enum DbKeyPrefix {
    ClientDatabase = 0x00,
    Mnemonic = 0x01,
    JoinedFederations = 0x02,
    LastActiveFederation = 0x03,
}

#[derive(Debug, Clone, Encodable, Decodable, Eq, PartialEq, Hash)]
struct MnemonicKey;

impl_db_record!(
    key = MnemonicKey,
    value = Vec<u8>,
    db_prefix = DbKeyPrefix::Mnemonic,
);

#[derive(Debug, Clone, Encodable, Decodable, Eq, PartialEq, Hash)]
struct JoinedFederationsKey;

impl_db_record!(
    key = JoinedFederationsKey,
    value = Vec<FederationId>,
    db_prefix = DbKeyPrefix::JoinedFederations,
);

#[derive(Debug, Clone, Encodable, Decodable, Eq, PartialEq, Hash)]
struct LastActiveFederationKey;

impl_db_record!(
    key = LastActiveFederationKey,
    value = FederationId,
    db_prefix = DbKeyPrefix::LastActiveFederation,
);

#[derive(Debug, uniffi::Object)]
pub struct Client {
    handle: ClientHandleArc,
    federation_id: FederationId,
}

#[uniffi::export]
impl Client {
    /// Federation ID as a hex string.
    pub fn federation_id(&self) -> String {
        let id = self.federation_id.to_string();
        debug!("Client::federation_id -> {}", id);
        id
    }

    /// Generic client handle FFI for the underlying federation client.
    pub fn client(&self) -> Arc<ClientHandle> {
        self.handle.clone()
    }

    /// Typed Lightning module client for this federation.
    pub fn lightning(&self) -> Result<Arc<LightningClientModule>, FedimintError> {
        debug!("Client::lightning federation_id={}", self.federation_id);
        self.handle
            .get_first_module_arc::<LightningClientModule>()
            .map_err(|e| { error!("Client::lightning error federation_id={}: {}", self.federation_id, e); err(e) })
    }

    /// Typed Mint module client for this federation.
    pub fn mint(&self) -> Result<Arc<fedimint_mint_client::MintClientModule>, FedimintError> {
        debug!("Client::mint federation_id={}", self.federation_id);
        self.handle
            .get_first_module_arc::<fedimint_mint_client::MintClientModule>()
            .map_err(|e| { error!("Client::mint error federation_id={}: {}", self.federation_id, e); err(e) })
    }

    /// Typed Wallet module client for this federation.
    pub fn wallet(&self) -> Result<Arc<fedimint_wallet_client::WalletClientModule>, FedimintError> {
        debug!("Client::wallet federation_id={}", self.federation_id);
        self.handle
            .get_first_module_arc::<fedimint_wallet_client::WalletClientModule>()
            .map_err(|e| { error!("Client::wallet error federation_id={}: {}", self.federation_id, e); err(e) })
    }

    /// Typed Meta module client for this federation.
    pub fn meta(&self) -> Result<Arc<fedimint_meta_client::MetaClientModule>, FedimintError> {
        debug!("Client::meta federation_id={}", self.federation_id);
        self.handle
            .get_first_module_arc::<fedimint_meta_client::MetaClientModule>()
            .map_err(|e| { error!("Client::meta error federation_id={}: {}", self.federation_id, e); err(e) })
    }
}

#[derive(uniffi::Object)]
pub struct FedimintSDK {
    db: Database,
    connectors: ConnectorRegistry,
    clients: Mutex<HashMap<FederationId, Arc<Client>>>,
    preview_cache: std::sync::Mutex<Option<ClientPreview>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl FedimintSDK {
    /// Initialize the SDK, opening the unified database at `db_path`. A
    /// mnemonic must be set explicitly via `set_mnemonic` or `generate_mnemonic`
    /// before joining federations.
    #[uniffi::constructor]
    pub async fn new(db_path: String) -> Result<Arc<Self>, FedimintError> {
        install_android_panic_hook();

        debug!("FedimintSDK::new(db_path={})", db_path);

        let db = open_database(&db_path).await.map_err(err)?;

        debug!("FedimintSDK::new building connector registry");
        let connectors = ConnectorRegistry::build_from_client_env()
            .map_err(err)?
            .bind()
            .await
            .map_err(err)?;

        let sdk = Self {
            db,
            connectors,
            clients: Mutex::new(HashMap::new()),
            preview_cache: std::sync::Mutex::new(None),
        };

        info!("FedimintSDK::new completed successfully");
        Ok(Arc::new(sdk))
    }

    /// Set the 12-word mnemonic backing all federation wallets.
    ///
    /// This can only be called once for a given database.
    pub async fn set_mnemonic(&self, words: Vec<String>) -> Result<(), FedimintError> {
        let phrase = words.join(" ");
        let mnemonic = Mnemonic::from_str(&phrase)
            .context("Invalid mnemonic phrase")
            .map_err(|e| {
                error!("FedimintSDK::set_mnemonic invalid phrase: {}", e);
                err(e)
            })?;

        self.write_mnemonic(&mnemonic).await.map_err(|e| {
            error!("FedimintSDK::set_mnemonic write failed: {}", e);
            err(e)
        })
    }

    /// Generate a new 12-word BIP39 mnemonic for the SDK.
    pub async fn generate_mnemonic(&self) -> Result<Vec<String>, FedimintError> {
        if let Some(existing) = self.read_mnemonic().await.map_err(err)? {
            debug!("FedimintSDK::generate_mnemonic returning existing mnemonic");
            return Ok(mnemonic_to_words(&existing));
        }

        let mnemonic = Bip39RootSecretStrategy::<12>::random(&mut rand::thread_rng());
        if let Err(write_error) = self.write_mnemonic(&mnemonic).await {
            // A concurrent initializer may have already written the mnemonic.
            if let Some(existing) = self.read_mnemonic().await.map_err(err)? {
                warn!("FedimintSDK::Mnemonic already exists {}", write_error);
                return Ok(mnemonic_to_words(&existing));
            }
            error!("FedimintSDK::generate_mnemonic write failed: {}", write_error);
            return Err(err(write_error));
        }

        info!("FedimintSDK::generate_mnemonic new mnemonic generated and persisted");
        Ok(mnemonic_to_words(&mnemonic))
    }

    /// Check whether the SDK mnemonic has already been set.
    pub async fn has_mnemonic_set(&self) -> Result<bool, FedimintError> {
        let result = self.read_mnemonic().await.map_err(err)?.is_some();
        Ok(result)
    }

    /// Return the 12-word mnemonic backing all federation wallets.
    pub async fn get_mnemonic(&self) -> Result<Vec<String>, FedimintError> {
        let mnemonic = self
            .read_mnemonic()
            .await
            .map_err(err)?
            .context("No mnemonic set")
            .map_err(|e| { error!("FedimintSDK::get_mnemonic not set: {}", e); err(e) })?;
        Ok(mnemonic.words().map(|w| w.to_string()).collect())
    }

    async fn preview_federation(&self, invite_code: String) -> Result<String, FedimintError> {
        info!("FedimintSDK::preview_federation");
        let invite = InviteCode::from_str(&invite_code)
            .map_err(|e| { error!("FedimintSDK::preview_federation invalid invite code: {}", e); err(e) })?;
        let federation_id = invite.federation_id();
        debug!("FedimintSDK::preview_federation federation_id={}", federation_id);

        let builder = client_builder().await.map_err(err)?;
        let preview = builder
            .preview(self.connectors.clone(), &invite)
            .await
            .map_err(|e| { error!("FedimintSDK::preview_federation network error federation_id={}: {}", federation_id, e); err(e) })?;

        let json_config = preview.config().to_json();
        *self.preview_cache.lock().unwrap() = Some(preview);

        let result = serde_json::json!({
            "config": json_config,
            "federation_id": federation_id.to_string(),
        });
        info!("FedimintSDK::preview_federation completed federation_id={}", federation_id);
        Ok(result.to_string())
    }

    /// Join (or recover) a federation from an invite code. Returns the
    /// resulting per-federation `Wallet`. If a wallet for that federation is
    /// already loaded, it is returned directly.
    pub async fn join_federation(&self, invite_code: String) -> Result<Arc<Client>, FedimintError> {
        info!("FedimintSDK::join_federation");
        let invite = InviteCode::from_str(&invite_code)
            .map_err(|e| { error!("FedimintSDK::join_federation invalid invite code: {}", e); err(e) })?;
        let federation_id = invite.federation_id();
        info!("FedimintSDK::join_federation federation_id={}", federation_id);

        // Fast path: already loaded.
        {
            let clients = self.clients.lock().await;
            if let Some(c) = clients.get(&federation_id) {
                warn!(
                    "FedimintSDK::join_federation already joined, reusing cached client federation_id={}",
                    federation_id
                );
                return Ok(c.clone());
            }
        }

        let mnemonic = self
            .read_mnemonic()
            .await
            .map_err(err)?
            .context("No mnemonic set")
            .map_err(|e| { error!("FedimintSDK::join_federation no mnemonic: {}", e); err(e) })?;

        let federation_secret = derive_federation_secret(&mnemonic, &federation_id);
        let client_db = self.client_db(&federation_id);

        let builder = client_builder().await.map_err(err)?;

        let client: ClientHandleArc = if fedimint_client::Client::is_initialized(&client_db).await {
            info!("FedimintSDK::join_federation reopening existing client federation_id={}", federation_id);
            Arc::new(
                builder
                    .open(
                        self.connectors.clone(),
                        client_db,
                        RootSecret::StandardDoubleDerive(federation_secret),
                    )
                    .await
                    .map_err(|e| { error!("FedimintSDK::join_federation open error federation_id={}: {}", federation_id, e); err(e) })?,
            )
        } else {
            info!("FedimintSDK::join_federation fresh join, downloading backup federation_id={}", federation_id);
            let preview = builder
                .preview(self.connectors.clone(), &invite)
                .await
                .map_err(|e| { error!("FedimintSDK::join_federation preview error federation_id={}: {}", federation_id, e); err(e) })?;

            #[allow(deprecated)]
            let backup = preview
                .download_backup_from_federation(RootSecret::StandardDoubleDerive(
                    federation_secret.clone(),
                ))
                .await
                .map_err(|e| { error!("FedimintSDK::join_federation backup download error federation_id={}: {}", federation_id, e); err(e) })?;

            if backup.is_some() {
                info!("FedimintSDK::join_federation backup found, recovering federation_id={}", federation_id);
                Arc::new(
                    preview
                        .recover(
                            client_db,
                            RootSecret::StandardDoubleDerive(federation_secret),
                            backup,
                        )
                        .await
                        .map_err(|e| { error!("FedimintSDK::join_federation recover error federation_id={}: {}", federation_id, e); err(e) })?,
                )
            } else {
                info!("FedimintSDK::join_federation no backup, joining fresh federation_id={}", federation_id);
                Arc::new(
                    preview
                        .join(
                            client_db,
                            RootSecret::StandardDoubleDerive(federation_secret),
                        )
                        .await
                        .map_err(|e| { error!("FedimintSDK::join_federation join error federation_id={}: {}", federation_id, e); err(e) })?,
                )
            }
        };  

        let client = Arc::new(Client {
            handle: client,
            federation_id,
        });

        let mut clients = self.clients.lock().await;
        clients.insert(federation_id, client.clone());
        drop(clients);
        self.persist_joined_federation(&federation_id)
            .await
            .map_err(err)?;
        self.write_last_active_federation(&federation_id)
            .await
            .map_err(err)?;
        info!("FedimintSDK::join_federation success federation_id={}", federation_id);
        Ok(client)
    }

    /// List all previously joined federation IDs from the database.
    /// This is instant — no network or client initialization happens.
    /// Call `open_client` to actually connect to a specific federation.
    pub async fn list_clients(&self) -> Vec<String> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let ids: Vec<String> = dbtx
            .get_value(&JoinedFederationsKey)
            .await
            .unwrap_or_default()
            .iter()
            .map(|id| id.to_string())
            .collect();
        info!("FedimintSDK::list_clients count={}", ids.len());
        ids
    }

    /// Open (or reuse) a previously joined federation by its ID string.
    /// Caches the open client so subsequent calls are instant.
    /// Also records this as the last-active federation for auto-restore on
    /// the next app launch.
    pub async fn open_client(&self, federation_id: String) -> Result<Arc<Client>, FedimintError> {
        info!("FedimintSDK::open_client federation_id={}", federation_id);
        let id = FederationId::from_str(&federation_id)
            .map_err(|e| { error!("FedimintSDK::open_client invalid federation_id={}: {}", federation_id, e); err(e) })?;

        // Fast path: already open in memory.
        {
            let clients = self.clients.lock().await;
            if let Some(c) = clients.get(&id) {
                debug!("FedimintSDK::open_client cache hit federation_id={}", federation_id);
                return Ok(c.clone());
            }
        }

        let mnemonic = self
            .read_mnemonic()
            .await
            .map_err(err)?
            .context("No mnemonic set")
            .map_err(|e| { error!("FedimintSDK::open_client no mnemonic: {}", e); err(e) })?;

        let client_db = self.client_db(&id);
        if !fedimint_client::Client::is_initialized(&client_db).await {
            let msg = format!("Federation {} not found in local database", federation_id);
            error!("FedimintSDK::open_client {}", msg);
            return Err(err(msg));
        }

        let federation_secret = derive_federation_secret(&mnemonic, &id);
        let builder = client_builder().await.map_err(err)?;
        info!("FedimintSDK::open_client opening client from DB federation_id={}", federation_id);
        let client: ClientHandleArc = Arc::new(
            builder
                .open(
                    self.connectors.clone(),
                    client_db,
                    RootSecret::StandardDoubleDerive(federation_secret),
                )
                .await
                .map_err(|e| { error!("FedimintSDK::open_client open error federation_id={}: {}", federation_id, e); err(e) })?,
        );

        let wallet = Arc::new(Client {
            handle: client,
            federation_id: id,
        });

        let mut clients = self.clients.lock().await;
        clients.insert(id, wallet.clone());
        drop(clients);

        self.write_last_active_federation(&id)
            .await
            .map_err(err)?;

        info!("FedimintSDK::open_client success federation_id={}", federation_id);
        Ok(wallet)
    }

    /// Returns the federation ID that was last set as active, if any.
    /// Use this on startup to auto-open the previously active wallet.
    pub async fn get_last_active_federation(&self) -> Option<String> {
        debug!("FedimintSDK::get_last_active_federation");
        let mut dbtx = self.db.begin_transaction_nc().await;
        let result = dbtx
            .get_value(&LastActiveFederationKey)
            .await
            .map(|id| id.to_string());
        info!("FedimintSDK::get_last_active_federation -> {:?}", result);
        result
    }
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn create_fedimint_sdk(db_path: String) -> Result<Arc<FedimintSDK>, FedimintError> {
    FedimintSDK::new(db_path).await
}

/// Set the minimum log level for the fedimint-uniffi logger.
///
/// On Android this reconfigures the `android_logger` filter so logcat reflects
/// the chosen level immediately. On other platforms it adjusts the global
/// `log` max-level filter used by whatever logger the host application has
/// installed (e.g. `env_logger`).
///
/// Call this before `create_fedimint_sdk` to ensure the SDK init messages are
/// captured at the desired verbosity. Defaults to `Info` if never called.
///
/// # Viewing logs on Android via adb
///
/// All SDK logs are tagged `fedimint-uniffi` in logcat. Useful commands:
///
/// ```text
/// # Stream all SDK logs (any level):
/// adb logcat -s fedimint-uniffi
///
/// # Stream only errors:
/// adb logcat -s fedimint-uniffi:E
///
/// # Stream info and above (I, W, E):
/// adb logcat -s fedimint-uniffi:I
///
/// # Stream debug and above (D, I, W, E):
/// adb logcat -s fedimint-uniffi:D
///
/// # Clear logcat buffer first, then stream:
/// adb logcat -c && adb logcat -s fedimint-uniffi
///
/// # Save to file:
/// adb logcat -s fedimint-uniffi > fedimint.log
/// ```
///
/// Note: `android_logger::init_once` only runs once per process. To capture
/// the SDK's own init messages at a finer level, call `set_log_level` with
/// the desired level *before* calling `create_fedimint_sdk`.
#[uniffi::export]
pub fn set_log_level(level: LogLevel) {
    let filter: log::LevelFilter = level.into();

    #[cfg(target_os = "android")]
    {
        // android_logger's init_once only runs once; after that we can only
        // change the max level via the global log filter.
        install_android_panic_hook_with_level(filter);
    }

    // Always update the global max-level so the log macros gate correctly.
    log::set_max_level(filter);
    info!("FedimintSDK::set_log_level -> {:?}", filter);
}

impl FedimintSDK {
    fn client_db(&self, federation_id: &FederationId) -> Database {
        let mut prefix = vec![DbKeyPrefix::ClientDatabase as u8];
        prefix.extend_from_slice(&federation_id.consensus_encode_to_vec());
        self.db.with_prefix(prefix)
    }

    async fn read_mnemonic(&self) -> anyhow::Result<Option<Mnemonic>> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        match dbtx.get_value(&MnemonicKey).await {
            Some(entropy) => Ok(Some(Mnemonic::from_entropy(&entropy)?)),
            None => Ok(None),
        }
    }

    async fn write_mnemonic(&self, mnemonic: &Mnemonic) -> anyhow::Result<()> {
        let mut dbtx = self.db.begin_transaction().await;
        if dbtx.get_value(&MnemonicKey).await.is_some() {
            anyhow::bail!("Mnemonic already exists");
        }
        dbtx.insert_new_entry(&MnemonicKey, &mnemonic.to_entropy())
            .await;
        dbtx.commit_tx().await;
        Ok(())
    }

    async fn persist_joined_federation(&self, federation_id: &FederationId) -> anyhow::Result<()> {
        let mut dbtx = self.db.begin_transaction().await;
        let mut ids = dbtx.get_value(&JoinedFederationsKey).await.unwrap_or_default();
        if !ids.contains(federation_id) {
            ids.push(*federation_id);
            dbtx.insert_entry(&JoinedFederationsKey, &ids).await;
            dbtx.commit_tx().await;
        }
        Ok(())
    }

    async fn write_last_active_federation(&self, federation_id: &FederationId) -> anyhow::Result<()> {
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(&LastActiveFederationKey, federation_id).await;
        dbtx.commit_tx().await;
        Ok(())
    }
}

async fn client_builder() -> anyhow::Result<fedimint_client::ClientBuilder> {
    let mut builder = fedimint_client::Client::builder().await?;
    builder.with_module(MintClientInit);
    builder.with_module(LightningClientInit::default());
    builder.with_module(WalletClientInit(None));
    builder.with_module(MetaClientInit);
    Ok(builder)
}

fn derive_federation_secret(mnemonic: &Mnemonic, federation_id: &FederationId) -> DerivableSecret {
    let global_root_secret = Bip39RootSecretStrategy::<12>::to_root_secret(mnemonic);
    let multi_federation_root_secret = global_root_secret.child_key(ChildId(0));
    let federation_root_secret = multi_federation_root_secret.federation_key(federation_id);
    let federation_wallet_root_secret = federation_root_secret.child_key(ChildId(0));
    federation_wallet_root_secret.child_key(ChildId(0))
}

fn mnemonic_to_words(mnemonic: &Mnemonic) -> Vec<String> {
    mnemonic.words().map(|word| word.to_string()).collect()
}

#[cfg(not(target_arch = "wasm32"))]
async fn open_database(path: &str) -> anyhow::Result<Database> {
    tokio::fs::create_dir_all(path).await?;
    let db_path = std::path::Path::new(path).join(DB_DIR_NAME);
    let db = fedimint_rocksdb::RocksDb::build(db_path).open().await?;
    Ok(Database::new(db, Default::default()))
}

#[cfg(target_arch = "wasm32")]
async fn open_database(path: &str) -> anyhow::Result<Database> {
    // The wasm `MemAndRedb` requires a `FileSystemSyncAccessHandle` rather
    // than a path. Until we wire that through, error out so callers know to
    // use the native build for now.
    let _ = path;
    anyhow::bail!(
        "wasm database backend (fedimint-cursed-redb) requires a file handle; \
         construct it externally and pass via a wasm-specific constructor"
    )
}
