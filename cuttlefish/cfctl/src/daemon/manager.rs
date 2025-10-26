use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{self, Child, Command, Stdio},
    sync::{mpsc, Arc},
    thread,
    time::{Duration, Instant},
};

use anyhow::{anyhow, Context, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use tracing::{debug, info, warn};

use crate::protocol::{
    AdbInfo, BootVerificationResult, CleanupSummary, CreateInstanceResponse, DestroyOptions,
    ErrorDetail, InstanceActionResponse, InstanceId, InstanceState, InstanceSummary, LogsOptions,
    LogsResponse, Request, Response, StartOptions,
};

use super::config::CfctlDaemonConfig;
use super::guest::{ExitStatusInfo, GuestHandle, GuestRegistry};
use super::util::{epoch_secs, run_command_allow_failure, run_command_capture, tail_file};

const ID_ALLOC_FILE: &str = "next_id";
const METADATA_FILE: &str = "metadata.json";

struct InstancePaths {
    root: PathBuf,
    artifacts: PathBuf,
    metadata: PathBuf,
    run_log: PathBuf,
}

impl InstancePaths {
    fn new(config: &CfctlDaemonConfig, id: InstanceId) -> Self {
        let root = config.state_dir.join("instances").join(id.to_string());
        Self {
            artifacts: root.join("artifacts"),
            metadata: root.join(METADATA_FILE),
            run_log: root.join("cfctl-run.log"),
            root,
        }
    }

    fn env_file(&self, config: &CfctlDaemonConfig) -> PathBuf {
        config
            .etc_instances_dir
            .join(format!("{}.env", self.id_string()))
    }

    fn id_string(&self) -> String {
        self.root
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default()
            .to_string()
    }

    fn run_log_path(&self) -> &PathBuf {
        &self.run_log
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use tempfile::TempDir;

    fn test_config(root: &Path) -> CfctlDaemonConfig {
        CfctlDaemonConfig {
            socket_path: root.join("sock"),
            state_dir: root.join("state"),
            etc_instances_dir: root.join("etc"),
            default_boot_image: root.join("images/boot.img"),
            default_init_boot_image: root.join("images/init_boot.img"),
            start_timeout: Duration::from_secs(5),
            adb_wait_timeout: Duration::from_secs(2),
            journal_lines: 20,
            adb_host: "127.0.0.1".to_string(),
            base_adb_port: 6500,
            cuttlefish_fhs: PathBuf::from("/bin/true"),
            cuttlefish_instances_dir: root.join("cf_instances"),
            cuttlefish_assembly_dir: root.join("cf_assembly"),
            cuttlefish_system_image_dir: root.join("images"),
            disable_host_gpu: true,
        }
    }

    fn init_metadata(manager: &mut InstanceManager, id: InstanceId) -> Result<InstanceMetadata> {
        let mut metadata = InstanceMetadata {
            id,
            purpose: Some("test".to_string()),
            adb_port: manager.config.base_adb_port,
            state: InstanceState::Starting,
            boot_image: manager.config.default_boot_image.clone(),
            init_boot_image: manager.config.default_init_boot_image.clone(),
            created_at: epoch_secs()?,
            updated_at: epoch_secs()?,
            held: false,
        };
        let paths = manager.paths(id);
        fs::create_dir_all(&paths.root)?;
        fs::create_dir_all(&paths.artifacts)?;
        manager.write_metadata(&paths, &metadata)?;
        manager.write_env_file(&paths, &metadata)?;
        {
            let mut log = manager.prepare_run_log(&paths)?;
            writeln!(log, "first line")?;
            writeln!(log, "launch failed marker")?;
            log.sync_all()?;
        }
        metadata.state = InstanceState::Starting;
        metadata.updated_at = epoch_secs()?;
        Ok(metadata)
    }

    fn setup_manager() -> Result<(TempDir, InstanceManager)> {
        let temp = tempfile::tempdir()?;
        let config = test_config(temp.path());
        fs::create_dir_all(&config.state_dir)?;
        fs::create_dir_all(&config.etc_instances_dir)?;
        fs::create_dir_all(&config.cuttlefish_instances_dir)?;
        fs::create_dir_all(&config.cuttlefish_assembly_dir)?;
        fs::create_dir_all(&config.cuttlefish_system_image_dir)?;
        if let Some(parent) = config.default_boot_image.parent() {
            fs::create_dir_all(parent)?;
        }
        if let Some(parent) = config.default_init_boot_image.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&config.default_boot_image, b"boot")?;
        fs::write(&config.default_init_boot_image, b"init")?;
        let registry = Arc::new(GuestRegistry::new());
        Ok((temp, InstanceManager::new(config, registry)))
    }

    #[test]
    fn wait_for_adb_returns_error_when_guest_exits_quickly() -> Result<()> {
        let (_temp, mut manager) = setup_manager()?;
        let id = 1;
        let _metadata = init_metadata(&mut manager, id)?;

        let child = Command::new("sh")
            .arg("-c")
            .arg("exit 42")
            .spawn()
            .context("spawning short-lived child")?;
        let handle = Arc::new(GuestHandle::new(child));
        manager.guest_registry.insert(id, Arc::clone(&handle));

        let err = manager
            .wait_for_adb(id, Some(2))
            .expect_err("expected failure");
        assert_eq!(err.code, "wait_for_adb_guest_exit");
        let message = err.message.as_deref().unwrap_or_default();
        assert!(
            message.contains("exited before adb became ready"),
            "unexpected message: {message}"
        );
        assert!(
            message.contains("cfctl-run.log tail"),
            "log tail missing from message: {message}"
        );
        assert!(
            message.contains("launch failed marker"),
            "log content missing: {message}"
        );

        let metadata_after = manager.metadata(id)?;
        assert_eq!(metadata_after.state, InstanceState::Failed);
        assert!(handle.try_wait()?.is_some(), "child should be reaped");
        Ok(())
    }

    #[test]
    fn wait_for_adb_times_out_when_adb_never_appears() -> Result<()> {
        let (_temp, mut manager) = setup_manager()?;
        let id = 2;
        let _metadata = init_metadata(&mut manager, id)?;

        let child = Command::new("sh")
            .arg("-c")
            .arg("sleep 30")
            .spawn()
            .context("spawning long-running child")?;
        let handle = Arc::new(GuestHandle::new(child));
        manager.guest_registry.insert(id, Arc::clone(&handle));

        let err = manager
            .wait_for_adb(id, Some(0))
            .expect_err("expected timeout");
        assert_eq!(err.code, "wait_for_adb_timeout");
        let message = err.message.as_deref().unwrap_or_default();
        assert!(
            message.contains("timeout waiting for adb"),
            "timeout message missing: {message}"
        );
        assert!(
            message.contains("cfctl-run.log tail"),
            "log tail missing from timeout message: {message}"
        );

        let metadata_after = manager.metadata(id)?;
        assert_eq!(metadata_after.state, InstanceState::Failed);
        assert!(
            handle.try_wait()?.is_some(),
            "timeout path should terminate the child"
        );
        Ok(())
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
struct InstanceMetadata {
    id: InstanceId,
    #[serde(default)]
    purpose: Option<String>,
    #[serde(default)]
    adb_port: u16,
    #[serde(default)]
    state: InstanceState,
    #[serde(default)]
    boot_image: PathBuf,
    #[serde(default)]
    init_boot_image: PathBuf,
    #[serde(default)]
    created_at: u64,
    #[serde(default)]
    updated_at: u64,
    #[serde(default)]
    held: bool,
}

impl InstanceMetadata {
    fn summary(&self, host: &str) -> InstanceSummary {
        InstanceSummary {
            id: self.id,
            adb: Some(AdbInfo {
                host: host.to_string(),
                port: self.adb_port,
                serial: format!("{host}:{}", self.adb_port),
            }),
            state: self.state.clone(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct CleanupOutcome {
    pub guest_processes_killed: bool,
    pub remaining_pids: Vec<i32>,
    pub steps: Vec<String>,
}

impl CleanupOutcome {
    fn from_parts(remaining_pids: Vec<i32>, steps: Vec<String>) -> Self {
        let guest_processes_killed = remaining_pids.is_empty();
        Self {
            guest_processes_killed,
            remaining_pids,
            steps,
        }
    }

    fn summary(&self) -> CleanupSummary {
        CleanupSummary {
            guest_processes_killed: self.guest_processes_killed,
            remaining_pids: self.remaining_pids.clone(),
            steps: self.steps.clone(),
        }
    }
}

fn error_detail(code: &str, message: impl Into<String>) -> ErrorDetail {
    ErrorDetail {
        code: code.to_string(),
        message: Some(message.into()),
    }
}

fn deadline_from_timeout(timeout_secs: Option<u64>) -> Option<Instant> {
    timeout_secs.map(|secs| Instant::now() + Duration::from_secs(secs))
}

fn secs_remaining(deadline: Option<Instant>) -> Option<u64> {
    deadline.map(|deadline| {
        if let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
            remaining.as_secs()
        } else {
            0
        }
    })
}

pub struct InstanceManager {
    config: CfctlDaemonConfig,
    metadata_cache: HashMap<InstanceId, InstanceMetadata>,
    guest_registry: Arc<GuestRegistry>,
}

impl InstanceManager {
    pub fn new(config: CfctlDaemonConfig, guest_registry: Arc<GuestRegistry>) -> Self {
        Self {
            config,
            metadata_cache: HashMap::new(),
            guest_registry,
        }
    }

    pub fn handle(&mut self, request: Request) -> Result<Response> {
        info!(target: "cfctl", "handle: beginning request processing: {:?}", request);
        match request {
            Request::CreateInstance { purpose } => {
                info!(target: "cfctl", "handle: CreateInstance with purpose: {:?}", purpose);
                let response = self.create_instance(purpose)?;
                info!(target: "cfctl", "handle: CreateInstance completed successfully for instance {}", response.summary.id);
                Ok(Response {
                    ok: true,
                    message: None,
                    create: Some(response),
                    action: None,
                    logs: None,
                    instances: None,
                    error: None,
                })
            }
            Request::StartInstance { id, options } => {
                info!(target: "cfctl", "handle: StartInstance for instance {}", id);
                match self.start_instance(id, options) {
                    Ok(response) => {
                        info!(target: "cfctl", "handle: StartInstance completed successfully for instance {}", response.summary.id);
                        Ok(Response {
                            ok: true,
                            message: None,
                            create: None,
                            action: Some(response),
                            logs: None,
                            instances: None,
                            error: None,
                        })
                    }
                    Err(detail) => {
                        warn!(target: "cfctl", "handle: StartInstance failed for {}: {:?}", id, detail);
                        Ok(Response::error_with_detail(detail))
                    }
                }
            }
            Request::CreateStartInstance { purpose, options } => {
                info!(target: "cfctl", "handle: CreateStartInstance purpose={:?}", purpose);
                match self.create_and_start_instance(purpose, options) {
                    Ok(response) => {
                        info!(target: "cfctl", "handle: CreateStartInstance completed successfully for instance {}", response.summary.id);
                        Ok(Response {
                            ok: true,
                            message: None,
                            create: None,
                            action: Some(response),
                            logs: None,
                            instances: None,
                            error: None,
                        })
                    }
                    Err(detail) => {
                        warn!(target: "cfctl", "handle: CreateStartInstance failed: {:?}", detail);
                        Ok(Response::error_with_detail(detail))
                    }
                }
            }
            Request::StopInstance { id } => {
                info!(target: "cfctl", "handle: StopInstance for instance {}", id);
                let response = self.stop_instance(id)?;
                info!(target: "cfctl", "handle: StopInstance completed successfully for instance {}", response.summary.id);
                Ok(Response {
                    ok: true,
                    message: None,
                    create: None,
                    action: Some(response),
                    logs: None,
                    instances: None,
                    error: None,
                })
            }
            Request::HoldInstance { id } => {
                info!(target: "cfctl", "handle: HoldInstance for instance {}", id);
                let response = self.hold_instance(id)?;
                info!(target: "cfctl", "handle: HoldInstance completed successfully for instance {}", response.summary.id);
                Ok(Response {
                    ok: true,
                    message: None,
                    create: None,
                    action: Some(response),
                    logs: None,
                    instances: None,
                    error: None,
                })
            }
            Request::DestroyInstance { id, options } => {
                info!(target: "cfctl", "handle: DestroyInstance for instance {}", id);
                match self.destroy_instance(id, options) {
                    Ok(response) => {
                        info!(target: "cfctl", "handle: DestroyInstance completed successfully for instance {}", response.summary.id);
                        Ok(Response {
                            ok: true,
                            message: None,
                            create: None,
                            action: Some(response),
                            logs: None,
                            instances: None,
                            error: None,
                        })
                    }
                    Err(detail) => {
                        warn!(target: "cfctl", "handle: DestroyInstance failed for {}: {:?}", id, detail);
                        Ok(Response::error_with_detail(detail))
                    }
                }
            }
            Request::Deploy(req) => {
                self.deploy(req)?;
                Ok(Response::ok().with_message("deploy updated"))
            }
            Request::WaitForAdb { id, timeout_secs } => match self.wait_for_adb(id, timeout_secs) {
                Ok(response) => Ok(Response {
                    ok: true,
                    message: None,
                    create: None,
                    action: Some(response),
                    logs: None,
                    instances: None,
                    error: None,
                }),
                Err(detail) => Ok(Response::error_with_detail(detail)),
            },
            Request::Logs { id, lines, options } => match self.logs(id, lines, options) {
                Ok(logs) => Ok(Response {
                    ok: true,
                    message: None,
                    create: None,
                    action: None,
                    logs: Some(logs),
                    instances: None,
                    error: None,
                }),
                Err(detail) => Ok(Response::error_with_detail(detail)),
            },
            Request::Status { id } => {
                let response = self.status(id)?;
                Ok(Response {
                    ok: true,
                    message: None,
                    create: None,
                    action: Some(response),
                    logs: None,
                    instances: None,
                    error: None,
                })
            }
            Request::ListInstances => {
                let instances = self.list_instances()?;
                Ok(Response {
                    ok: true,
                    message: None,
                    create: None,
                    action: None,
                    logs: None,
                    instances: Some(instances),
                    error: None,
                })
            }
            Request::PruneExpired { max_age_secs } => {
                let (pruned, retained) = self.prune_expired_instances(max_age_secs)?;
                let msg = if retained > 0 {
                    format!(
                        "pruned {} expired instances; {} still running",
                        pruned, retained
                    )
                } else {
                    format!("pruned {} expired instances", pruned)
                };
                Ok(Response::ok().with_message(msg))
            }
            Request::PruneAll => {
                let (pruned, retained) = self.prune_all_instances()?;
                let msg = if retained > 0 {
                    format!("pruned {} instances; {} still running", pruned, retained)
                } else {
                    format!("pruned {} instances", pruned)
                };
                Ok(Response::ok().with_message(msg))
            }
        }
    }

    fn list_instances(&mut self) -> Result<Vec<InstanceSummary>> {
        let instances_dir = self.config.state_dir.join("instances");
        let entries_iter = match fs::read_dir(&instances_dir) {
            Ok(iter) => iter,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
            Err(err) => return Err(err.into()),
        };

        let mut entries = Vec::new();
        let mut found_count = 0;
        let mut skipped_count = 0;

        for entry in entries_iter {
            let entry = entry?;
            if !entry.path().is_dir() {
                continue;
            }
            let file_name = match entry.file_name().into_string() {
                Ok(name) => name,
                Err(_) => continue,
            };
            let id: InstanceId = match file_name.parse() {
                Ok(value) => value,
                Err(_) => continue,
            };
            let metadata = match self.metadata(id) {
                Ok(metadata) => metadata,
                Err(err) => {
                    debug!(target: "cfctl", "list_instances: failed to load metadata for {}: {}", id, err);
                    continue;
                }
            };
            if metadata.state == InstanceState::Destroyed {
                debug!(
                    target: "cfctl",
                    "list_instances: skipping instance {} because state is Destroyed",
                    id
                );
                skipped_count += 1;
                continue;
            }

            debug!(
                target: "cfctl",
                "list_instances: metadata for instance {} ready; adding summary",
                id
            );
            entries.push(metadata.summary(&self.config.adb_host));
            found_count += 1;
        }

        entries.sort_by_key(|summary| summary.id);
        info!(
            target: "cfctl",
            "list_instances: found {} instances, skipped {} entries",
            found_count,
            skipped_count
        );
        Ok(entries)
    }

    fn prune_expired_instances(&mut self, max_age_secs: u64) -> Result<(usize, usize)> {
        let instances_dir = self.config.state_dir.join("instances");
        let entries_iter = match fs::read_dir(&instances_dir) {
            Ok(iter) => iter,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok((0, 0)),
            Err(err) => return Err(err.into()),
        };

        let now = epoch_secs()?;
        let cutoff = now.saturating_sub(max_age_secs);
        let mut pruned = 0;
        let mut retained = 0;

        for entry in entries_iter {
            let entry = entry?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let file_name = match entry.file_name().into_string() {
                Ok(name) => name,
                Err(_) => continue,
            };
            let id: InstanceId = match file_name.parse() {
                Ok(value) => value,
                Err(_) => continue,
            };
            let metadata = match self.metadata(id) {
                Ok(metadata) => metadata,
                Err(err) => {
                    debug!(target: "cfctl", "prune_expired: failed to load metadata for {}: {}", id, err);
                    continue;
                }
            };
            if metadata.state == InstanceState::Destroyed {
                continue;
            }
            if metadata.held {
                debug!(target: "cfctl", "prune_expired: skipping held instance {}", id);
                continue;
            }
            if metadata.updated_at > cutoff {
                continue;
            }
            match self.prune_instance(id) {
                Ok(true) => pruned += 1,
                Ok(false) => {
                    retained += 1;
                }
                Err(err) => {
                    warn!(
                        target: "cfctl",
                        "prune_expired: failed to prune instance {}: {:#}",
                        id,
                        err
                    );
                    retained += 1;
                }
            }
        }

        Ok((pruned, retained))
    }

    fn prune_all_instances(&mut self) -> Result<(usize, usize)> {
        let instances_dir = self.config.state_dir.join("instances");
        let entries_iter = match fs::read_dir(&instances_dir) {
            Ok(iter) => iter,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok((0, 0)),
            Err(err) => return Err(err.into()),
        };

        let mut pruned = 0;
        let mut retained = 0;

        for entry in entries_iter {
            let entry = entry?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let file_name = match entry.file_name().into_string() {
                Ok(name) => name,
                Err(_) => continue,
            };
            let id: InstanceId = match file_name.parse() {
                Ok(value) => value,
                Err(_) => continue,
            };
            let metadata = match self.metadata(id) {
                Ok(metadata) => metadata,
                Err(err) => {
                    debug!(target: "cfctl", "prune_all: failed to load metadata for {}: {}", id, err);
                    continue;
                }
            };
            if metadata.state == InstanceState::Destroyed {
                continue;
            }
            if metadata.held {
                debug!(target: "cfctl", "prune_all: skipping held instance {}", id);
                retained += 1;
                continue;
            }
            match self.prune_instance(id) {
                Ok(true) => pruned += 1,
                Ok(false) => retained += 1,
                Err(err) => {
                    warn!(
                        target: "cfctl",
                        "prune_all: failed to prune instance {}: {:#}",
                        id,
                        err
                    );
                    retained += 1;
                }
            }
        }

        Ok((pruned, retained))
    }

    fn prune_instance(&mut self, id: InstanceId) -> Result<bool> {
        debug!(target: "cfctl", "prune_instance: begin for {}", id);
        self.prepare_destroy(id)?;
        let mut cleanup_manager =
            InstanceManager::new(self.config.clone(), self.guest_registry.clone());
        match cleanup_manager.finish_destroy(id) {
            Ok(outcome) => {
                if outcome.guest_processes_killed {
                    debug!(
                        target: "cfctl",
                        "prune_instance: instance {} cleaned up successfully",
                        id
                    );
                    Ok(true)
                } else {
                    if let Ok(metadata) = cleanup_manager.metadata(id) {
                        self.metadata_cache.insert(id, metadata);
                    }
                    warn!(
                        target: "cfctl",
                        "prune_instance: instance {} still running after prune (pids: {:?})",
                        id,
                        outcome.remaining_pids
                    );
                    Ok(false)
                }
            }
            Err(err) => {
                warn!(
                    target: "cfctl",
                    "prune_instance: cleanup error for {}: {:#}",
                    id,
                    err
                );
                let _ = cleanup_manager.mark_metadata_state(id, InstanceState::Failed);
                Err(err)
            }
        }
    }

    pub(super) fn allocate_id(&self) -> Result<InstanceId> {
        let id_dir = self.config.state_dir.join("control");
        fs::create_dir_all(&id_dir)?;
        let path = id_dir.join(ID_ALLOC_FILE);
        let mut file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&path)?;
        file.lock_exclusive()?;
        let mut buf = String::new();
        file.read_to_string(&mut buf)?;
        let mut next: InstanceId = buf.trim().parse().unwrap_or(1);
        if next == 0 {
            next = 1;
        }

        let mut candidate = next;
        let mut selected: Option<InstanceId> = None;
        for _ in 0..99 {
            if candidate == 0 || candidate > 99 {
                candidate = 1;
            }
            let paths = self.paths(candidate);
            if !paths.metadata.exists() && !paths.root.exists() {
                selected = Some(candidate);
                candidate = candidate % 99 + 1;
                break;
            }
            candidate = candidate % 99 + 1;
        }

        let id = selected.ok_or_else(|| anyhow!("no available instance slots (1-99)"))?;

        file.set_len(0)?;
        file.seek(SeekFrom::Start(0))?;
        write!(file, "{}", candidate)?;
        file.sync_all()?;
        file.unlock()?;
        Ok(id)
    }

    fn create_instance(&mut self, purpose: Option<String>) -> Result<CreateInstanceResponse> {
        let id = self.allocate_id()?;
        let adb_port = self.config.base_adb_port + id as u16 - 1;
        let paths = self.paths(id);

        fs::create_dir_all(&paths.root)
            .with_context(|| format!("creating instance dir {}", paths.root.display()))?;
        fs::create_dir_all(&paths.artifacts)
            .with_context(|| format!("creating artifacts dir {}", paths.artifacts.display()))?;

        let now = epoch_secs()?;
        let metadata = InstanceMetadata {
            id,
            purpose,
            adb_port,
            state: InstanceState::Created,
            boot_image: self.config.default_boot_image.clone(),
            init_boot_image: self.config.default_init_boot_image.clone(),
            created_at: now,
            updated_at: now,
            held: false,
        };

        self.write_metadata(&paths, &metadata)?;
        self.write_env_file(&paths, &metadata)?;

        let summary = metadata.summary(&self.config.adb_host);
        self.metadata_cache.insert(id, metadata);
        Ok(CreateInstanceResponse { summary })
    }

    fn create_and_start_instance(
        &mut self,
        purpose: Option<String>,
        options: StartOptions,
    ) -> Result<InstanceActionResponse, ErrorDetail> {
        let create = self
            .create_instance(purpose)
            .map_err(|err| error_detail("create_start_create_failed", err.to_string()))?;
        self.start_instance(create.summary.id, options)
    }

    fn start_instance(
        &mut self,
        id: InstanceId,
        options: StartOptions,
    ) -> Result<InstanceActionResponse, ErrorDetail> {
        info!(
            target: "cfctl",
            "start_instance: beginning start for instance {}",
            id
        );

        if options.skip_adb_wait && options.verify_boot {
            return Err(error_detail(
                "start_instance_invalid_options",
                "cannot use both skip_adb_wait and verify_boot (boot verification requires ADB)".to_string(),
            ));
        }

        if self.guest_registry.contains(id) {
            warn!(
                target: "cfctl",
                "start_instance: instance {} already has an active guest handle",
                id
            );
            return Err(error_detail(
                "start_instance_already_running",
                format!("instance {} already running", id),
            ));
        }

        let mut metadata = self
            .metadata(id)
            .map_err(|err| error_detail("start_instance_metadata", err.to_string()))?;
        info!(
            target: "cfctl",
            "start_instance: loaded metadata for instance {}, current state: {:?}",
            id,
            metadata.state
        );

        metadata.state = InstanceState::Starting;
        metadata.updated_at = epoch_secs()
            .map_err(|err| error_detail("start_instance_timestamp", err.to_string()))?;
        let paths = self.paths(id);
        info!(
            target: "cfctl",
            "start_instance: writing updated metadata with state Starting"
        );
        self.write_metadata(&paths, &metadata)
            .map_err(|err| error_detail("start_instance_write_metadata", err.to_string()))?;
        self.write_env_file(&paths, &metadata)
            .map_err(|err| error_detail("start_instance_write_env", err.to_string()))?;
        self.metadata_cache.insert(id, metadata.clone());

        self.preflight_cleanup(id)
            .map_err(|err| error_detail("start_instance_preflight", err.to_string()))?;

        info!(
            target: "cfctl",
            "start_instance: preparing host directories for instance {}",
            id
        );
        self.prepare_host_directories(id)
            .map_err(|err| error_detail("start_instance_prepare_dirs", err.to_string()))?;
        self.ensure_qemu_datadir()
            .map_err(|err| error_detail("start_instance_ensure_qemu", err.to_string()))?;

        let run_log = self
            .prepare_run_log(&paths)
            .map_err(|err| error_detail("start_instance_prepare_log", err.to_string()))?;
        let child = match self.spawn_guest_process(id, &metadata, run_log, !options.disable_webrtc, options.track.as_deref())
        {
            Ok(child) => child,
            Err(err) => {
                warn!(
                    target: "cfctl",
                    "start_instance: failed to spawn guest {}: {:#}",
                    id,
                    err
                );
                metadata.state = InstanceState::Failed;
                metadata.updated_at = epoch_secs().map_err(|err| {
                    error_detail("start_instance_failed_timestamp", err.to_string())
                })?;
                if let Err(write_err) = self.write_metadata(&paths, &metadata) {
                    warn!(
                        target: "cfctl",
                        "start_instance: failed to write failed metadata for {}: {:#}",
                        id,
                        write_err
                    );
                }
                self.metadata_cache.insert(id, metadata.clone());
                return Err(error_detail(
                    "start_instance_spawn_failed",
                    format!("launching cuttlefish guest: {err:#}"),
                ));
            }
        };
        let handle = Arc::new(GuestHandle::new(child));

        if let Some(existing) = self.guest_registry.insert(id, Arc::clone(&handle)) {
            warn!(
                target: "cfctl",
                "start_instance: replaced existing guest handle for instance {}, pid {}",
                id,
                existing.pid()
            );
        }

        if options.skip_adb_wait {
            info!(
                target: "cfctl",
                "start_instance: skipping adb wait for instance {} (skip_adb_wait enabled)",
                id
            );
            
            let mut metadata = self
                .metadata(id)
                .map_err(|err| error_detail("start_instance_metadata_after_skip", err.to_string()))?;
            metadata.state = InstanceState::Running;
            metadata.updated_at = epoch_secs()
                .map_err(|err| error_detail("start_instance_timestamp_after_skip", err.to_string()))?;
            let paths = self.paths(id);
            self.write_metadata(&paths, &metadata)
                .map_err(|err| error_detail("start_instance_write_metadata_after_skip", err.to_string()))?;
            self.metadata_cache.insert(id, metadata.clone());
            
            info!(
                target: "cfctl",
                "start_instance: instance {} started without adb wait; registering exit watcher",
                id
            );
            self.spawn_exit_watcher(id, handle);
            
            Ok(InstanceActionResponse {
                summary: metadata.summary(&self.config.adb_host),
                journal_tail: None,
                verification: None,
                cleanup: None,
            })
        } else {
            let effective_timeout = options
                .timeout_secs
                .or_else(|| Some(self.config.start_timeout.as_secs()));
            let deadline = deadline_from_timeout(effective_timeout);

            let mut response = match self.wait_for_adb(id, secs_remaining(deadline)) {
                Ok(resp) => resp,
                Err(detail) => {
                    warn!(
                        target: "cfctl",
                        "start_instance: wait_for_adb failed for instance {}: {:?}",
                        id,
                        detail
                    );
                    let _ = self.terminate_guest(id, Duration::from_secs(5));
                    return Err(detail);
                }
            };

            if options.verify_boot {
                match self.verify_boot_completed(id, secs_remaining(deadline)) {
                    Ok(verification) => {
                        response.verification = Some(verification);
                    }
                    Err(detail) => {
                        warn!(
                            target: "cfctl",
                            "start_instance: boot verification failed for {}: {:?}",
                            id,
                            detail
                        );
                        return Err(detail);
                    }
                }
            }

            info!(
                target: "cfctl",
                "start_instance: instance {} reported adb ready; registering exit watcher",
                id
            );
            self.spawn_exit_watcher(id, handle);

            Ok(response)
        }
    }

    fn stop_instance(&mut self, id: InstanceId) -> Result<InstanceActionResponse> {
        let mut metadata = self.metadata(id)?;
        let exit = self.terminate_guest(id, Duration::from_secs(10))?;
        metadata.state = match exit {
            Some(info) if info.success() => InstanceState::Stopped,
            Some(_) => InstanceState::Failed,
            None => InstanceState::Stopped,
        };
        metadata.updated_at = epoch_secs()?;
        let paths = self.paths(id);
        self.write_metadata(&paths, &metadata)?;
        self.metadata_cache.insert(id, metadata.clone());
        let cleanup = self.cleanup_host_state(id);
        if !cleanup.guest_processes_killed {
            warn!(
                target: "cfctl",
                "stop_instance: instance {} still has running processes after cleanup (pids: {:?})",
                id,
                cleanup.remaining_pids
            );
            let now = epoch_secs()?;
            metadata.state = InstanceState::Failed;
            metadata.updated_at = now;
            self.write_metadata(&paths, &metadata)?;
            self.metadata_cache.insert(id, metadata.clone());
        }
        let cleanup_summary = cleanup.summary();
        Ok(InstanceActionResponse {
            summary: metadata.summary(&self.config.adb_host),
            journal_tail: None,
            verification: None,
            cleanup: Some(cleanup_summary),
        })
    }

    fn hold_instance(&mut self, id: InstanceId) -> Result<InstanceActionResponse> {
        let mut metadata = self.metadata(id)?;
        metadata.held = true;
        metadata.updated_at = epoch_secs()?;
        let paths = self.paths(id);
        self.write_metadata(&paths, &metadata)?;
        self.metadata_cache.insert(id, metadata.clone());
        info!(target: "cfctl", "hold_instance: instance {} marked as held", id);
        Ok(InstanceActionResponse {
            summary: metadata.summary(&self.config.adb_host),
            journal_tail: None,
            verification: None,
            cleanup: None,
        })
    }

    fn destroy_instance(
        &mut self,
        id: InstanceId,
        options: DestroyOptions,
    ) -> Result<InstanceActionResponse, ErrorDetail> {
        debug!(target: "cfctl", "destroy_instance: entering prepare_destroy for {}", id);
        let summary = self
            .prepare_destroy(id)
            .map_err(|err| error_detail("destroy_prepare_failed", err.to_string()))?;
        debug!(
            target: "cfctl",
            "destroy_instance: prepare_destroy completed for {}",
            id
        );

        let config = self.config.clone();
        let registry = self.guest_registry.clone();
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let mut manager = InstanceManager::new(config.clone(), registry.clone());
            let result = manager.finish_destroy(id);
            let _ = tx.send(result);
        });

        let deadline = deadline_from_timeout(options.timeout_secs);
        info!(
            target: "cfctl",
            "destroy_instance: waiting for cleanup completion for {}",
            id
        );

        let outcome = match deadline {
            Some(deadline) => {
                let now = Instant::now();
                let remaining = deadline.saturating_duration_since(now);
                match rx.recv_timeout(remaining) {
                    Ok(result) => result,
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        return Err(error_detail(
                            "destroy_timeout",
                            format!("destroy {} exceeded timeout", id),
                        ))
                    }
                    Err(err) => {
                        return Err(error_detail(
                            "destroy_recv_failed",
                            format!("destroy {} recv failed: {}", id, err),
                        ))
                    }
                }
            }
            None => match rx.recv() {
                Ok(result) => result,
                Err(err) => {
                    return Err(error_detail(
                        "destroy_recv_failed",
                        format!("destroy {} recv failed: {}", id, err),
                    ))
                }
            },
        };

        let outcome = outcome.map_err(|err| {
            error_detail(
                "destroy_cleanup_failed",
                format!("cleanup for {} failed: {:#}", id, err),
            )
        })?;

        if !outcome.guest_processes_killed {
            return Err(error_detail(
                "destroy_incomplete",
                format!(
                    "guest processes still running for {}: {:?}",
                    id, outcome.remaining_pids
                ),
            ));
        }

        let cleanup_summary = outcome.summary();

        info!(
            target: "cfctl",
            "destroy_instance: cleanup completed for {} (remaining_pids={:?})",
            id,
            cleanup_summary.remaining_pids
        );

        Ok(InstanceActionResponse {
            summary,
            journal_tail: None,
            verification: None,
            cleanup: Some(cleanup_summary),
        })
    }

    pub(super) fn prepare_destroy(&mut self, id: InstanceId) -> Result<InstanceSummary> {
        debug!(target: "cfctl", "prepare_destroy: begin for {}", id);
        let paths = self.paths(id);

        let mut metadata = match self.metadata(id) {
            Ok(metadata) => metadata,
            Err(_) => InstanceMetadata {
                id,
                purpose: None,
                adb_port: self.config.base_adb_port + id as u16 - 1,
                state: InstanceState::Destroyed,
                boot_image: self.config.default_boot_image.clone(),
                init_boot_image: self.config.default_init_boot_image.clone(),
                created_at: 0,
                updated_at: 0,
                held: false,
            },
        };

        metadata.state = InstanceState::Destroyed;
        metadata.updated_at = epoch_secs()?;
        debug!(
            target: "cfctl",
            "prepare_destroy: updated metadata timestamps for {}",
            id
        );
        if metadata.created_at == 0 {
            metadata.created_at = metadata.updated_at;
        }

        if paths.metadata.exists() {
            debug!(
                target: "cfctl",
                "prepare_destroy: writing metadata for {} to {}",
                id,
                paths.metadata.display()
            );
            self.write_metadata(&paths, &metadata)?;
        }

        self.metadata_cache.remove(&id);
        debug!(
            target: "cfctl",
            "prepare_destroy: terminating guest process for {}",
            id
        );
        self.terminate_guest(id, Duration::from_secs(5))?;
        debug!(
            target: "cfctl",
            "prepare_destroy: guest termination complete for {}",
            id
        );
        if !self.kill_guest_processes(id) {
            warn!(
                target: "cfctl",
                "prepare_destroy: force kill pass left processes running for {}",
                id
            );
        }

        Ok(InstanceSummary {
            id,
            adb: None,
            state: InstanceState::Destroyed,
        })
    }

    pub(super) fn finish_destroy(&mut self, id: InstanceId) -> Result<CleanupOutcome> {
        let outcome = self.cleanup_host_state(id);
        if outcome.guest_processes_killed {
            if let Err(err) = self.remove_instance_artifacts(id) {
                warn!(
                    target: "cfctl",
                    "finish_destroy: failed to remove artifacts for {}: {:#}",
                    id,
                    err
                );
            } else {
                self.metadata_cache.remove(&id);
            }
        } else {
            self.mark_metadata_state(id, InstanceState::Failed)?;
        }
        Ok(outcome)
    }

    fn deploy(&mut self, req: crate::protocol::DeployRequest) -> Result<()> {
        let mut metadata = self.metadata(req.id)?;
        let paths = self.paths(req.id);
        if let Some(boot) = req.boot_image {
            let dest = paths.artifacts.join("boot.img");
            fs::copy(&boot, &dest)
                .with_context(|| format!("copy boot image {} -> {}", boot, dest.display()))?;
            metadata.boot_image = dest;
        }
        if let Some(init_boot) = req.init_boot_image {
            let dest = paths.artifacts.join("init_boot.img");
            fs::copy(&init_boot, &dest).with_context(|| {
                format!("copy init_boot image {} -> {}", init_boot, dest.display())
            })?;
            metadata.init_boot_image = dest;
        }
        metadata.updated_at = epoch_secs()?;
        self.write_metadata(&paths, &metadata)?;
        self.write_env_file(&paths, &metadata)?;
        self.metadata_cache.insert(req.id, metadata);
        Ok(())
    }

    fn remove_instance_artifacts(&self, id: InstanceId) -> Result<()> {
        let paths = self.paths(id);

        let env_path = paths.env_file(&self.config);
        if env_path.exists() {
            fs::remove_file(&env_path)
                .with_context(|| format!("removing env file {}", env_path.display()))?;
        }

        if paths.root.exists() {
            fs::remove_dir_all(&paths.root)
                .with_context(|| format!("removing instance dir {}", paths.root.display()))?;
        }

        Ok(())
    }

    fn wait_for_adb(
        &mut self,
        id: InstanceId,
        timeout_secs: Option<u64>,
    ) -> Result<InstanceActionResponse, ErrorDetail> {
        let mut metadata = self
            .metadata(id)
            .map_err(|err| error_detail("wait_for_adb_metadata", err.to_string()))?;
        let timeout = timeout_secs
            .map(Duration::from_secs)
            .unwrap_or(self.config.adb_wait_timeout);
        let deadline = Instant::now() + timeout;
        let serial = format!("{}:{}", self.config.adb_host, metadata.adb_port);
        let connect_serial = format!("0.0.0.0:{}", metadata.adb_port);
        let addr = format!("{}:{}", self.config.adb_host, metadata.adb_port);

        loop {
            let handle = match self.guest_registry.get(id) {
                Some(handle) => handle,
                None => {
                    let message = match self.record_launch_failure(
                        id,
                        &mut metadata,
                        anyhow!("instance {} lost guest handle before adb became ready", id),
                    ) {
                        Ok(err) => format!("{err:#}"),
                        Err(err) => format!(
                            "instance {} lost guest handle and record failed: {:#}",
                            id, err
                        ),
                    };
                    return Err(error_detail("wait_for_adb_handle_lost", message));
                }
            };

            if let Some(exit) = handle
                .try_wait()
                .map_err(|err| error_detail("wait_for_adb_wait", err.to_string()))?
            {
                self.guest_registry.remove_if_handle(id, &handle);
                let message = match self.record_launch_failure(
                    id,
                    &mut metadata,
                    anyhow!(
                        "instance {} exited before adb became ready ({})",
                        id,
                        exit.describe()
                    ),
                ) {
                    Ok(err) => format!("{err:#}"),
                    Err(err) => format!(
                        "instance {} exited before adb and record failed: {:#}",
                        id, err
                    ),
                };
                return Err(error_detail("wait_for_adb_guest_exit", message));
            }

            if let Err(err) = self.adb_connect(&connect_serial) {
                if Instant::now() >= deadline {
                    let _ = self.terminate_guest(id, Duration::from_secs(2));
                    let message = match self.record_launch_failure(
                        id,
                        &mut metadata,
                        anyhow!("timeout waiting for adb on {}: {}", addr, err),
                    ) {
                        Ok(err) => format!("{err:#}"),
                        Err(record_err) => format!(
                            "timeout waiting for adb on {} and record failed: {:#}",
                            addr, record_err
                        ),
                    };
                    return Err(error_detail("wait_for_adb_timeout", message));
                }
                drop(handle);
                thread::sleep(Duration::from_secs(1));
                continue;
            }

            match self.resolve_active_adb_serial(&serial, &connect_serial) {
                Ok(Some(_active_serial)) => {
                    metadata.state = InstanceState::Running;
                    metadata.updated_at = epoch_secs()
                        .map_err(|err| error_detail("wait_for_adb_time", err.to_string()))?;
                    let paths = self.paths(id);
                    self.write_metadata(&paths, &metadata).map_err(|err| {
                        error_detail("wait_for_adb_write_metadata", err.to_string())
                    })?;
                    self.metadata_cache.insert(id, metadata.clone());
                    let summary = metadata.summary(&self.config.adb_host);
                    return Ok(InstanceActionResponse {
                        summary,
                        journal_tail: None,
                        verification: None,
                        cleanup: None,
                    });
                }
                Ok(None) => {
                    if Instant::now() >= deadline {
                        let _ = self.terminate_guest(id, Duration::from_secs(2));
                        let message = match self.record_launch_failure(
                            id,
                            &mut metadata,
                            anyhow!("timeout waiting for adb device {}", serial),
                        ) {
                            Ok(err) => format!("{err:#}"),
                            Err(record_err) => format!(
                                "timeout waiting for adb device {} and record failed: {:#}",
                                serial, record_err
                            ),
                        };
                        return Err(error_detail("wait_for_adb_timeout", message));
                    }
                    drop(handle);
                    thread::sleep(Duration::from_secs(1));
                }
                Err(err) => {
                    if Instant::now() >= deadline {
                        let _ = self.terminate_guest(id, Duration::from_secs(2));
                        let message = match self.record_launch_failure(
                            id,
                            &mut metadata,
                            anyhow!("adb devices never succeeded for {}: {:#}", serial, err),
                        ) {
                            Ok(err) => format!("{err:#}"),
                            Err(record_err) => format!(
                                "adb devices failed for {} and record failed: {:#}",
                                serial, record_err
                            ),
                        };
                        return Err(error_detail("wait_for_adb_timeout", message));
                    }
                    drop(handle);
                    thread::sleep(Duration::from_secs(1));
                }
            }
        }
    }

    fn verify_boot_completed(
        &mut self,
        id: InstanceId,
        timeout_secs: Option<u64>,
    ) -> Result<BootVerificationResult, ErrorDetail> {
        let metadata = self
            .metadata(id)
            .map_err(|err| error_detail("verify_boot_metadata", err.to_string()))?;
        let serial = format!("{}:{}", self.config.adb_host, metadata.adb_port);
        let connect_serial = format!("0.0.0.0:{}", metadata.adb_port);
        let timeout = timeout_secs
            .filter(|secs| *secs > 0)
            .map(Duration::from_secs)
            .unwrap_or_else(|| Duration::from_secs(120));
        let deadline = Instant::now() + timeout;

        loop {
            if let Err(err) = self.adb_connect(&connect_serial) {
                let msg = format!("{:#}", err);
                debug!(
                    target: "cfctl",
                    "verify_boot: adb connect transient failure for {} (serial {}): {}",
                    id,
                    connect_serial,
                    msg
                );
                if Instant::now() >= deadline {
                    return Err(error_detail(
                        "verify_boot_adb_failed",
                        format!("adb connect never succeeded for instance {}: {}", id, msg),
                    ));
                }
                thread::sleep(Duration::from_millis(500));
                continue;
            }

            let active_serial = match self.resolve_active_adb_serial(&serial, &connect_serial) {
                Ok(Some(serial)) => serial,
                Ok(None) => {
                    if Instant::now() >= deadline {
                        return Err(error_detail(
                            "verify_boot_adb_failed",
                            format!(
                                "adb device {} never appeared in device list",
                                connect_serial
                            ),
                        ));
                    }
                    thread::sleep(Duration::from_millis(500));
                    continue;
                }
                Err(err) => {
                    let msg = format!("{:#}", err);
                    debug!(
                        target: "cfctl",
                        "verify_boot: adb devices transient failure for {}: {}",
                        id,
                        msg
                    );
                    if Instant::now() >= deadline {
                        return Err(error_detail(
                            "verify_boot_adb_failed",
                            format!("adb devices never succeeded for instance {}: {}", id, msg),
                        ));
                    }
                    thread::sleep(Duration::from_millis(500));
                    continue;
                }
            };

            let value =
                match self.adb_shell_getprop(&active_serial, "VIRTUAL_DEVICE_BOOT_COMPLETED") {
                    Ok(value) => value.trim().to_string(),
                    Err(err) => {
                        let msg = format!("{:#}", err);
                        debug!(
                        target: "cfctl",
                            "verify_boot: adb getprop transient failure for {}: {}",
                            id,
                            msg
                        );
                        if self.console_log_has_boot_marker(id) {
                            info!(
                                target: "cfctl",
                                "verify_boot: console log contained boot marker for {}",
                                id
                            );
                            return Ok(BootVerificationResult {
                                adb_ready: true,
                                boot_marker_observed: true,
                                failure_reason: None,
                            });
                        }
                        if self.run_log_has_boot_marker(id) {
                            info!(
                                target: "cfctl",
                                "verify_boot: run log contained boot marker for {}",
                                id
                            );
                            return Ok(BootVerificationResult {
                                adb_ready: true,
                                boot_marker_observed: true,
                                failure_reason: None,
                            });
                        }
                        if Instant::now() >= deadline {
                            return Err(error_detail(
                                "verify_boot_adb_failed",
                                format!("adb getprop never succeeded for instance {}: {}", id, msg),
                            ));
                        }
                        thread::sleep(Duration::from_millis(500));
                        continue;
                    }
                };

            if matches!(value.as_str(), "1" | "true" | "TRUE") {
                return Ok(BootVerificationResult {
                    adb_ready: true,
                    boot_marker_observed: true,
                    failure_reason: None,
                });
            }

            if self.console_log_has_boot_marker(id) {
                info!(
                    target: "cfctl",
                    "verify_boot: console log contained boot marker for {}",
                    id
                );
                return Ok(BootVerificationResult {
                    adb_ready: true,
                    boot_marker_observed: true,
                    failure_reason: None,
                });
            }

            if self.run_log_has_boot_marker(id) {
                info!(
                    target: "cfctl",
                    "verify_boot: run log contained boot marker for {}",
                    id
                );
                return Ok(BootVerificationResult {
                    adb_ready: true,
                    boot_marker_observed: true,
                    failure_reason: None,
                });
            }

            if Instant::now() >= deadline {
                return Err(error_detail(
                    "verify_boot_marker_missing",
                    format!(
                        "VIRTUAL_DEVICE_BOOT_COMPLETED not observed for instance {} (last value: {:?})",
                        id, value
                    ),
                ));
            }

            thread::sleep(Duration::from_secs(1));
        }
    }

    fn console_log_has_boot_marker(&self, id: InstanceId) -> bool {
        let path = self.console_log_path(id);
        if !path.exists() {
            return false;
        }
        match tail_file(&path, self.config.journal_lines) {
            Ok(content) => content.contains("VIRTUAL_DEVICE_BOOT_COMPLETED"),
            Err(err) => {
                debug!(
                    target: "cfctl",
                    "verify_boot: failed to read console log {}: {}",
                    path.display(),
                    err
                );
                false
            }
        }
    }

    fn run_log_has_boot_marker(&self, id: InstanceId) -> bool {
        let paths = self.paths(id);
        let run_log = paths.run_log_path();
        if !run_log.exists() {
            return false;
        }
        match tail_file(run_log, self.config.journal_lines) {
            Ok(content) => content.contains("VIRTUAL_DEVICE_BOOT_COMPLETED"),
            Err(err) => {
                debug!(
                    target: "cfctl",
                    "verify_boot: failed to read run log {}: {}",
                    run_log.display(),
                    err
                );
                false
            }
        }
    }

    fn adb_shell_getprop(&self, serial: &str, property: &str) -> Result<String> {
        let mut cmd = Command::new(&self.config.cuttlefish_fhs);
        cmd.arg("--")
            .arg("adb")
            .arg("-s")
            .arg(serial)
            .arg("shell")
            .arg("getprop")
            .arg(property);
        let output = cmd
            .output()
            .with_context(|| format!("invoking adb getprop {} for {}", property, serial))?;
        if !output.status.success() {
            return Err(anyhow!(
                "adb returned {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn adb_connect(&self, serial: &str) -> Result<()> {
        let mut cmd = Command::new(&self.config.cuttlefish_fhs);
        cmd.arg("--").arg("adb").arg("connect").arg(serial);
        let output = cmd
            .output()
            .with_context(|| format!("invoking adb connect {}", serial))?;
        if !output.status.success() {
            return Err(anyhow!(
                "adb connect returned {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        info!(
            target: "cfctl",
            "verify_boot: adb connect succeeded for {}",
            serial
        );
        Ok(())
    }

    fn resolve_active_adb_serial(&self, serial_a: &str, serial_b: &str) -> Result<Option<String>> {
        let mut cmd = Command::new(&self.config.cuttlefish_fhs);
        cmd.arg("--").arg("adb").arg("devices");
        let output = cmd
            .output()
            .with_context(|| "invoking adb devices".to_string())?;
        if !output.status.success() {
            return Err(anyhow!(
                "adb devices returned {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines().skip(1) {
            let mut parts = line.split_whitespace();
            let Some(entry) = parts.next() else {
                continue;
            };
            let status = parts.next().unwrap_or("");
            let matches_serial = entry == serial_a || entry == serial_b;
            if !matches_serial {
                continue;
            }
            if status == "device" {
                return Ok(Some(entry.to_string()));
            }
        }
        Ok(None)
    }

    fn console_log_path(&self, id: InstanceId) -> PathBuf {
        self.host_instance_dir(id)
            .join("instances")
            .join(format!("cvd-{}", id))
            .join("console_log")
    }

    fn logs(
        &mut self,
        id: InstanceId,
        lines: Option<usize>,
        options: LogsOptions,
    ) -> Result<LogsResponse, ErrorDetail> {
        if matches!(options.timeout_secs, Some(0)) {
            return Err(error_detail(
                "logs_timeout",
                "timeout expired before logs retrieved",
            ));
        }
        let journal = self
            .guest_log_tail(id, lines.unwrap_or(self.config.journal_lines))
            .map_err(|err| error_detail("logs_fetch_failed", err.to_string()))?;
        let console_path = format!(
            "/var/lib/cuttlefish/instances/{}/instances/cvd-{}/console_log",
            id, id
        );
        let response = LogsResponse {
            journal,
            console_log_path: Some(console_path),
        };
        Ok(response)
    }

    fn record_launch_failure(
        &mut self,
        id: InstanceId,
        metadata: &mut InstanceMetadata,
        mut err: anyhow::Error,
    ) -> Result<anyhow::Error> {
        metadata.state = InstanceState::Failed;
        metadata.updated_at = epoch_secs()?;
        let paths = self.paths(id);
        self.write_metadata(&paths, &metadata)?;
        self.write_env_file(&paths, &metadata)?;
        self.metadata_cache.insert(id, metadata.clone());
        if let Some(log_tail) = self.guest_log_tail(id, self.config.journal_lines)? {
            err = err.context(format!("cfctl-run.log tail:\n{}", log_tail));
        }
        Ok(err)
    }

    fn status(&mut self, id: InstanceId) -> Result<InstanceActionResponse> {
        let metadata = self.metadata(id)?;
        let summary = metadata.summary(&self.config.adb_host);
        Ok(InstanceActionResponse {
            summary,
            journal_tail: None,
            verification: None,
            cleanup: None,
        })
    }

    fn mark_metadata_state(
        &mut self,
        id: InstanceId,
        state: InstanceState,
    ) -> Result<InstanceMetadata> {
        let now = epoch_secs()?;
        let metadata = match self.metadata(id) {
            Ok(mut metadata) => {
                metadata.state = state.clone();
                metadata.updated_at = now;
                if metadata.created_at == 0 {
                    metadata.created_at = now;
                }
                metadata
            }
            Err(_) => InstanceMetadata {
                id,
                purpose: None,
                adb_port: self.config.base_adb_port + id as u16 - 1,
                state: state.clone(),
                boot_image: self.config.default_boot_image.clone(),
                init_boot_image: self.config.default_init_boot_image.clone(),
                created_at: now,
                updated_at: now,
                held: false,
            },
        };

        let paths = self.paths(id);
        fs::create_dir_all(&paths.root)?;
        fs::create_dir_all(&paths.artifacts).ok();
        self.write_metadata(&paths, &metadata)?;
        if let Err(err) = self.write_env_file(&paths, &metadata) {
            debug!(
                target: "cfctl",
                "mark_metadata_state: ignoring env file update for {}: {}",
                id,
                err
            );
        }
        self.metadata_cache.insert(id, metadata.clone());
        Ok(metadata)
    }

    fn metadata(&mut self, id: InstanceId) -> Result<InstanceMetadata> {
        if let Some(cached) = self.metadata_cache.get(&id) {
            return Ok(cached.clone());
        }
        let paths = self.paths(id);
        let mut file = File::open(&paths.metadata)
            .with_context(|| format!("opening metadata file {}", paths.metadata.display()))?;
        let mut buf = String::new();
        file.read_to_string(&mut buf)?;
        let metadata: InstanceMetadata =
            serde_json::from_str(&buf).context("parsing metadata JSON")?;
        Ok(metadata)
    }

    fn write_metadata(&self, paths: &InstancePaths, metadata: &InstanceMetadata) -> Result<()> {
        if let Some(parent) = paths.metadata.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = paths.metadata.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(metadata)?)
            .with_context(|| format!("writing metadata tmp {}", tmp.display()))?;
        fs::rename(&tmp, &paths.metadata)
            .with_context(|| format!("renaming metadata {}", paths.metadata.display()))?;
        Ok(())
    }

    fn write_env_file(&self, paths: &InstancePaths, metadata: &InstanceMetadata) -> Result<()> {
        let env_path = paths.env_file(&self.config);
        let tmp = env_path.with_extension("tmp");
        let mut file = File::create(&tmp)?;
        writeln!(
            file,
            "# Autogenerated by cfctl at {}",
            epoch_secs()? // note: may fail; propagate
        )?;
        writeln!(
            file,
            "CUTTLEFISH_BOOT_IMAGE={}",
            metadata.boot_image.display()
        )?;
        writeln!(
            file,
            "CUTTLEFISH_INIT_BOOT_IMAGE={}",
            metadata.init_boot_image.display()
        )?;
        writeln!(file, "CUTTLEFISH_BASE_INSTANCE_NUM={}", metadata.id)?;
        writeln!(file, "CUTTLEFISH_ADB_TCP_PORT={}", metadata.adb_port)?;
        file.sync_all()?;
        fs::rename(&tmp, &env_path)?;
        fs::set_permissions(env_path, fs::Permissions::from_mode(0o640))?;
        Ok(())
    }

    fn paths(&self, id: InstanceId) -> InstancePaths {
        InstancePaths::new(&self.config, id)
    }

    fn prepare_host_directories(&self, id: InstanceId) -> Result<()> {
        let instance_dir = self.host_instance_dir(id);
        let assembly_dir = self.host_assembly_dir(id);

        if let Some(parent) = instance_dir.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("creating instances root {}", parent.display()))?;
        }

        if let Some(parent) = assembly_dir.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("creating assembly root {}", parent.display()))?;
        }

        if fs::symlink_metadata(&instance_dir).is_ok() {
            debug!(
                target: "cfctl",
                "prepare_host_directories: trashing existing instance dir {}",
                instance_dir.display()
            );
            self.trash_then_purge_async(&instance_dir)?;
        }
        if fs::symlink_metadata(&assembly_dir).is_ok() {
            debug!(
                target: "cfctl",
                "prepare_host_directories: trashing existing assembly dir {}",
                assembly_dir.display()
            );
            self.trash_then_purge_async(&assembly_dir)?;
        }

        debug!(
            target: "cfctl",
            "prepare_host_directories: creating instance dir {}",
            instance_dir.display()
        );
        fs::create_dir_all(&instance_dir)
            .with_context(|| format!("creating instance dir {}", instance_dir.display()))?;

        debug!(
            target: "cfctl",
            "prepare_host_directories: creating assembly dir {}",
            assembly_dir.display()
        );
        fs::create_dir_all(&assembly_dir)
            .with_context(|| format!("creating assembly dir {}", assembly_dir.display()))?;

        Ok(())
    }

    fn prepare_run_log(&self, paths: &InstancePaths) -> Result<File> {
        if let Some(parent) = paths.run_log_path().parent() {
            fs::create_dir_all(parent)?;
        }
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(paths.run_log_path())
            .with_context(|| format!("opening run log {}", paths.run_log_path().display()))?;
        Ok(file)
    }

    fn spawn_guest_process(
        &self,
        id: InstanceId,
        metadata: &InstanceMetadata,
        log_file: File,
        webrtc_enabled: bool,
        track: Option<&str>,
    ) -> Result<Child> {
        let log_clone = log_file
            .try_clone()
            .context("cloning run log file for stderr")?;

        let inst_name = id.to_string();
        let instance_dir = self.host_instance_dir(id);
        let assembly_dir = self.host_assembly_dir(id);
        
        // Use cfenv if track specified, otherwise direct FHS wrapper
        let mut cmd = if let Some(t) = track {
            info!(target: "cfctl", "spawn_guest_process: using track '{}'", t);
            let mut c = Command::new("cfenv");
            c.arg("-t").arg(t).arg("--");
            c
        } else {
            info!(target: "cfctl", "spawn_guest_process: using default FHS wrapper");
            let mut c = Command::new(&self.config.cuttlefish_fhs);
            c.arg("--");
            c
        };
        cmd
            .arg("launch_cvd")
            .arg(format!(
                "--system_image_dir={}",
                self.config.cuttlefish_system_image_dir.display()
            ))
            .arg(format!("--instance_dir={}", instance_dir.display()))
            .arg(format!("--assembly_dir={}", assembly_dir.display()))
            .arg("--vm_manager=qemu_cli")
            .arg("--enable_wifi=false")
            .arg("--enable_host_bluetooth=false")
            .arg("--enable_modem_simulator=false")
            .arg(format!(
                "--start_webrtc={}",
                if webrtc_enabled { "true" } else { "false" }
            ))
            .arg(format!(
                "--start_webrtc_sig_server={}",
                if webrtc_enabled { "true" } else { "false" }
            ))
            .arg("--report_anonymous_usage_stats=n")
            .arg("--daemon=false")
            .arg("--console=true")
            .arg("--verbosity=DEBUG")
            .arg("--resume=false");

        if metadata.boot_image.exists() {
            cmd.arg(format!("--boot_image={}", metadata.boot_image.display()));
        } else {
            debug!(
                target: "cfctl",
                "spawn_guest_process: boot image {} not found; skipping flag",
                metadata.boot_image.display()
            );
        }
        if metadata.init_boot_image.exists() {
            cmd.arg(format!(
                "--init_boot_image={}",
                metadata.init_boot_image.display()
            ));
        } else {
            debug!(
                target: "cfctl",
                "spawn_guest_process: init boot image {} not found; skipping flag",
                metadata.init_boot_image.display()
            );
        }

        if self.config.disable_host_gpu {
            cmd.env("CUTTLEFISH_DISABLE_HOST_GPU", "1");
        }

        cmd.env("GFXSTREAM_DISABLE_GRAPHICS_DETECTOR", "1");
        cmd.env("GFXSTREAM_HEADLESS", "1");

        cmd.env("CUTTLEFISH_INSTANCE", &inst_name);
        cmd.env("CUTTLEFISH_INSTANCE_NUM", inst_name.clone());
        cmd.env("CUTTLEFISH_ADB_TCP_PORT", metadata.adb_port.to_string());
        cmd.stdin(Stdio::null())
            .stdout(Stdio::from(log_file))
            .stderr(Stdio::from(log_clone));

        if let Some(parent) = instance_dir.parent() {
            cmd.current_dir(parent);
        }

        info!(
            target: "cfctl",
            "spawn_guest_process: launching instance {} with command {:?}",
            id,
            cmd
        );

        let child = cmd.spawn().with_context(|| {
            format!(
                "spawning cuttlefish guest {} via {}",
                id,
                self.config.cuttlefish_fhs.display()
            )
        })?;

        Ok(child)
    }

    fn spawn_exit_watcher(&self, id: InstanceId, handle: Arc<GuestHandle>) {
        let config = self.config.clone();
        let registry = self.guest_registry.clone();
        thread::spawn(move || match handle.wait() {
            Ok(exit) => {
                registry.remove_if_handle(id, &handle);
                let mut manager = InstanceManager::new(config.clone(), registry.clone());
                if let Err(err) = manager.handle_guest_exit(id, exit) {
                    warn!(
                        target: "cfctl",
                        "spawn_exit_watcher: error handling guest exit {}: {:#}",
                        id,
                        err
                    );
                }
            }
            Err(err) => {
                warn!(
                    target: "cfctl",
                    "spawn_exit_watcher: failed waiting for guest {} exit: {:#}",
                    id,
                    err
                );
                registry.remove_if_handle(id, &handle);
            }
        });
    }

    fn handle_guest_exit(&mut self, id: InstanceId, exit: ExitStatusInfo) -> Result<()> {
        let mut metadata = match self.metadata(id) {
            Ok(metadata) => metadata,
            Err(err) => {
                debug!(
                    target: "cfctl",
                    "handle_guest_exit: metadata missing for {}: {}",
                    id,
                    err
                );
                return Ok(());
            }
        };

        let new_state = if exit.success() {
            InstanceState::Stopped
        } else {
            InstanceState::Failed
        };

        debug!(
            target: "cfctl",
            "handle_guest_exit: instance {} exited with {}; updating state to {:?}",
            id,
            exit.describe(),
            new_state
        );

        metadata.state = new_state;
        metadata.updated_at = epoch_secs()?;
        let paths = self.paths(id);
        self.write_metadata(&paths, &metadata)?;
        self.metadata_cache.insert(id, metadata.clone());
        self.cleanup_host_state(id);
        Ok(())
    }

    fn ensure_qemu_datadir(&self) -> Result<()> {
        let datadir = Path::new("/var/lib/cuttlefish/usr/share/qemu/x86_64-linux-gnu");
        fs::create_dir_all(datadir)
            .with_context(|| format!("creating qemu datadir {}", datadir.display()))?;
        let target = datadir.join("kvmvapic.bin");
        if target.exists() {
            return Ok(());
        }

        debug!(
            target: "cfctl",
            "ensure_qemu_datadir: populating {} from cuttlefish-fhs",
            target.display()
        );
        let output = Command::new(&self.config.cuttlefish_fhs)
            .args(["--", "cat", "/usr/share/qemu/kvmvapic.bin"])
            .output()
            .with_context(|| {
                format!(
                    "ensure_qemu_datadir: invoking {} to read kvmvapic.bin",
                    self.config.cuttlefish_fhs.display()
                )
            })?;
        if !output.status.success() {
            warn!(
                target: "cfctl",
                "ensure_qemu_datadir: failed to read kvmvapic.bin via cuttlefish-fhs (status: {})",
                output.status
            );
            return Ok(());
        }

        fs::write(&target, &output.stdout)
            .with_context(|| format!("ensure_qemu_datadir: writing {}", target.display()))?;
        fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).with_context(|| {
            format!(
                "ensure_qemu_datadir: setting permissions on {}",
                target.display()
            )
        })?;
        Ok(())
    }

    fn terminate_guest(&self, id: InstanceId, grace: Duration) -> Result<Option<ExitStatusInfo>> {
        if let Some(handle) = self.guest_registry.get(id) {
            info!(
                target: "cfctl",
                "terminate_guest: sending SIGTERM to instance {} (pid {})",
                id,
                handle.pid()
            );
            handle.signal(libc::SIGTERM)?;
            if let Some(exit) = handle.wait_timeout(grace)? {
                info!(
                    target: "cfctl",
                    "terminate_guest: instance {} exited cleanly with {}",
                    id,
                    exit.describe()
                );
                self.guest_registry.remove_if_handle(id, &handle);
                return Ok(Some(exit));
            }
            warn!(
                target: "cfctl",
                "terminate_guest: instance {} did not exit within {:?}, sending SIGKILL",
                id,
                grace
            );
            handle.signal(libc::SIGKILL)?;
            if let Some(exit) = handle.wait_timeout(Duration::from_secs(5))? {
                info!(
                    target: "cfctl",
                    "terminate_guest: instance {} exited after SIGKILL with {}",
                    id,
                    exit.describe()
                );
                self.guest_registry.remove_if_handle(id, &handle);
                Ok(Some(exit))
            } else {
                warn!(
                    target: "cfctl",
                    "terminate_guest: instance {} still running after SIGKILL",
                    id
                );
                self.guest_registry.remove_if_handle(id, &handle);
                Ok(None)
            }
        } else {
            debug!(
                target: "cfctl",
                "terminate_guest: no active handle for instance {}",
                id
            );
            Ok(None)
        }
    }

    fn host_instance_dir(&self, id: InstanceId) -> PathBuf {
        self.config.cuttlefish_instances_dir.join(id.to_string())
    }

    fn host_assembly_dir(&self, id: InstanceId) -> PathBuf {
        self.config.cuttlefish_assembly_dir.join(id.to_string())
    }

    fn preflight_cleanup(&self, id: InstanceId) -> Result<()> {
        info!(
            target: "cfctl",
            "preflight_cleanup: starting pre-launch cleanup for instance {}",
            id
        );
        let guests_gone = self.kill_guest_processes(id);
        if !guests_gone {
            warn!(
                target: "cfctl",
                "preflight_cleanup: instance {} still has running processes after kill attempts",
                id
            );
        }
        self.remove_network_devices(id);
        self.remove_ephemeral_dirs(id);
        self.remove_cuttlefish_config_symlink();
        info!(
            target: "cfctl",
            "preflight_cleanup: completed pre-launch cleanup for instance {}",
            id
        );
        Ok(())
    }

    fn cleanup_host_state(&self, id: InstanceId) -> CleanupOutcome {
        info!(
            target: "cfctl",
            "cleanup_host_state: starting full cleanup for instance {}",
            id
        );
        let mut steps: Vec<String> = Vec::new();

        let _ = self.kill_guest_processes(id);
        steps.push("kill_guest_processes".to_string());

        self.remove_network_devices(id);
        steps.push("remove_network_devices".to_string());

        self.remove_ephemeral_dirs(id);
        steps.push("remove_ephemeral_dirs".to_string());

        self.remove_cuttlefish_config_symlink();
        steps.push("remove_cuttlefish_config_symlink".to_string());

        self.kill_open_file_holders(&[
            format!("/var/lib/cuttlefish/instances/{}", id),
            format!("/var/lib/cuttlefish/assembly/{}", id),
        ]);
        steps.push("kill_open_file_holders".to_string());
        let remaining = self.collect_guest_pids(id);
        steps.push("collect_guest_pids".to_string());
        if remaining.is_empty() {
            if let Err(err) = self.trash_then_purge_async(&self.host_instance_dir(id)) {
                debug!(
                    target: "cfctl",
                    "cleanup_host_state: failed to trash instance dir for {}: {}",
                    id,
                    err
                );
            }
            steps.push("trash_instance_dir".to_string());
            if let Err(err) = self.trash_then_purge_async(&self.host_assembly_dir(id)) {
                debug!(
                    target: "cfctl",
                    "cleanup_host_state: failed to trash assembly dir for {}: {}",
                    id,
                    err
                );
            }
            steps.push("trash_assembly_dir".to_string());
        } else {
            warn!(
                target: "cfctl",
                "cleanup_host_state: instance {} still has running processes: {:?}",
                id,
                remaining
            );
        }
        Self::reset_cuttlefish_permissions_async();
        steps.push("reset_permissions".to_string());
        info!(
            target: "cfctl",
            "cleanup_host_state: cleanup completed for instance {}",
            id
        );
        CleanupOutcome::from_parts(remaining, steps)
    }

    fn kill_guest_processes(&self, id: InstanceId) -> bool {
        let patterns = Self::guest_process_patterns(id);
        for pattern in &patterns {
            debug!(
                target: "cfctl",
                "kill_guest_processes: pkill -9 -f {}",
                pattern
            );
            if let Err(err) = Self::pkill_pattern(pattern, Some("-9")) {
                debug!(
                    target: "cfctl",
                    "kill_guest_processes: ignoring pkill -9 {}: {}",
                    pattern,
                    err
                );
            }
        }
        thread::sleep(Duration::from_millis(200));

        let mut remaining = self.collect_guest_pids(id);
        if remaining.is_empty() {
            return true;
        }

        for pid in &remaining {
            let pid_str = pid.to_string();
            debug!(
                target: "cfctl",
                "kill_guest_processes: kill -9 {}",
                pid
            );
            if let Err(err) = run_command_allow_failure("kill", &["-9", &pid_str]) {
                debug!(
                    target: "cfctl",
                    "kill_guest_processes: ignoring kill -9 {}: {}",
                    pid,
                    err
                );
            }
        }
        thread::sleep(Duration::from_millis(200));

        remaining = self.collect_guest_pids(id);
        if !remaining.is_empty() {
            debug!(
                target: "cfctl",
                "kill_guest_processes: remaining processes for {}: {:?}",
                id,
                remaining
            );
        }
        remaining.is_empty()
    }

    fn guest_process_patterns(id: InstanceId) -> Vec<String> {
        let inst_str = id.to_string();
        vec![
            format!("--instance_dir=/var/lib/cuttlefish/instances/{}", inst_str),
            format!("--assembly_dir=/var/lib/cuttlefish/assembly/{}", inst_str),
            format!("/var/lib/cuttlefish/instances/{}/", inst_str),
            format!("/var/lib/cuttlefish/assembly/{}/", inst_str),
            format!("cvd-{}", inst_str),
        ]
    }

    fn collect_guest_pids(&self, id: InstanceId) -> Vec<i32> {
        let patterns = Self::guest_process_patterns(id);
        let mut seen: HashSet<i32> = HashSet::new();
        for pattern in &patterns {
            match Command::new("pgrep").args(["-f", pattern]).output() {
                Ok(output) => {
                    if output.status.success() {
                        for line in String::from_utf8_lossy(&output.stdout).lines() {
                            if let Ok(pid) = line.trim().parse::<i32>() {
                                seen.insert(pid);
                            }
                        }
                    } else if output.status.code() == Some(1) {
                        // no matches; ignore
                    } else {
                        debug!(
                            target: "cfctl",
                            "collect_guest_pids: pgrep -f {} exited with {}",
                            pattern,
                            output.status
                        );
                    }
                }
                Err(err) => {
                    debug!(
                        target: "cfctl",
                        "collect_guest_pids: failed to invoke pgrep -f {}: {}",
                        pattern,
                        err
                    );
                }
            }
        }
        let mut result: Vec<i32> = seen.into_iter().collect();
        result.sort_unstable();
        result
    }

    fn pkill_pattern(pattern: &str, signal: Option<&str>) -> Result<bool> {
        let mut cmd = Command::new("pkill");
        if let Some(sig) = signal {
            cmd.arg(sig);
        }
        cmd.args(["-f", pattern]);
        let status = cmd.status().with_context(|| {
            format!(
                "invoking pkill {}{}",
                signal.unwrap_or(""),
                if signal.is_some() { " " } else { "" }
            )
        })?;
        match status.code() {
            Some(0) => Ok(true),
            Some(1) => Ok(false),
            Some(code) => Err(anyhow!("pkill -f {} exited with {}", pattern, code)),
            None => Err(anyhow!("pkill -f {} terminated by signal", pattern)),
        }
    }

    fn remove_ephemeral_dirs(&self, id: InstanceId) {
        let inst_str = id.to_string();
        let tmp_dirs = [
            format!("/tmp/cf_avd_0/cvd-{}", inst_str),
            format!("/tmp/cf_env_0/env-{}", inst_str),
            format!("/tmp/cf_img_0/cvd-{}", inst_str),
        ];
        for dir in tmp_dirs {
            debug!(target: "cfctl", "cleanup_host_state: removing directory {}", dir);
            if let Err(err) = fs::remove_dir_all(&dir) {
                debug!(target: "cfctl", "cleanup_host_state: ignoring remove_dir_all({}): {}", dir, err);
            } else {
                debug!(target: "cfctl", "cleanup_host_state: successfully removed directory {}", dir);
            }
        }
    }

    fn remove_network_devices(&self, id: InstanceId) {
        let inst_padded = format!("{:02}", id);
        for tap in [
            format!("cvd-mtap-{}", inst_padded),
            format!("cvd-tap-{}", inst_padded),
        ] {
            debug!(target: "cfctl", "cleanup_host_state: removing tap device {}", tap);
            if let Err(err) = run_command_allow_failure("ip", &["tuntap", "del", "dev", &tap]) {
                debug!(
                    target: "cfctl",
                    "cleanup_host_state: ignoring ip tuntap del {}: {}",
                    tap,
                    err
                );
            } else {
                debug!(
                    target: "cfctl",
                    "cleanup_host_state: successfully removed tap device {}",
                    tap
                );
            }
        }

        let eth_device = format!("cvd-eth-{}", inst_padded);
        debug!(target: "cfctl", "cleanup_host_state: removing ethernet device {}", eth_device);
        if let Err(err) = run_command_allow_failure("ip", &["link", "del", &eth_device]) {
            debug!(
                target: "cfctl",
                "cleanup_host_state: ignoring ip link del {}: {}",
                eth_device, err
            );
        } else {
            debug!(target: "cfctl", "cleanup_host_state: successfully removed ethernet device {}", eth_device);
        }
    }

    fn remove_cuttlefish_config_symlink(&self) {
        debug!(target: "cfctl", "cleanup_host_state: removing cuttlefish config symlink");
        if let Err(err) = fs::remove_file("/var/lib/cuttlefish/.cuttlefish_config.json") {
            if err.kind() != std::io::ErrorKind::NotFound {
                debug!(
                    target: "cfctl",
                    "cleanup_host_state: ignoring remove_file(.cuttlefish_config.json): {}",
                    err
                );
            }
        } else {
            debug!(target: "cfctl", "cleanup_host_state: successfully removed cuttlefish config symlink");
        }
    }

    fn kill_open_file_holders(&self, paths: &[String]) {
        debug!(target: "cfctl", "kill_open_file_holders: checking paths: {:?}", paths);
        for path in paths {
            debug!(target: "cfctl", "kill_open_file_holders: checking file holders for {}", path);
            if let Ok(output) = run_command_capture("lsof", &["-t", path]) {
                let pids: Vec<&str> = output.lines().filter(|s| !s.trim().is_empty()).collect();
                debug!(target: "cfctl", "kill_open_file_holders: found {} PIDs holding {}: {:?}", pids.len(), path, pids);
                for pid in pids {
                    debug!(target: "cfctl", "kill_open_file_holders: killing PID {} holding {}", pid, path);
                    if let Err(err) = run_command_allow_failure("kill", &["-9", pid]) {
                        debug!(target: "cfctl", "kill_open_file_holders: ignoring kill -9 {}: {}", pid, err);
                    } else {
                        debug!(target: "cfctl", "kill_open_file_holders: successfully killed PID {}", pid);
                    }
                }
            } else {
                debug!(target: "cfctl", "kill_open_file_holders: no file holders found for {}", path);
            }
        }
    }

    fn trash_then_purge_async(&self, path: &Path) -> Result<()> {
        if fs::symlink_metadata(path).is_err() {
            return Ok(());
        }
        let trash = Self::make_trash_path(path);
        debug!(
            target: "cfctl",
            "trash_then_purge_async: renaming {} -> {}",
            path.display(),
            trash.display()
        );
        fs::rename(path, &trash).with_context(|| {
            format!(
                "renaming {} -> {} before async purge",
                path.display(),
                trash.display()
            )
        })?;
        thread::spawn(move || {
            debug!(
                target: "cfctl",
                "background purge: removing {}",
                trash.display()
            );
            if let Err(err) = fs::remove_dir_all(&trash) {
                warn!(
                    target: "cfctl",
                    "background purge: failed removing {}: {}",
                    trash.display(),
                    err
                );
            } else {
                debug!(
                    target: "cfctl",
                    "background purge: removed {}",
                    trash.display()
                );
            }
        });
        Ok(())
    }

    fn make_trash_path(path: &Path) -> PathBuf {
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("trash");
        let epoch = epoch_secs().unwrap_or(0);
        let pid = process::id();
        let trash_name = format!("{}.__trash__.{}.{}", name, epoch, pid);
        match path.parent() {
            Some(dir) => dir.join(&trash_name),
            None => PathBuf::from(trash_name),
        }
    }

    fn reset_cuttlefish_permissions_async() {
        thread::spawn(|| {
            debug!(
                target: "cfctl",
                "background: resetting ownership/permissions on /var/lib/cuttlefish"
            );
            Self::reset_cuttlefish_permissions();
        });
    }

    fn reset_cuttlefish_permissions() {
        if let Err(err) =
            run_command_allow_failure("chown", &["-R", "justin:cvdnetwork", "/var/lib/cuttlefish"])
        {
            debug!(
                target: "cfctl",
                "reset_cuttlefish_permissions: ignoring chown: {}",
                err
            );
        }

        if let Err(err) =
            run_command_allow_failure("chmod", &["-R", "g+rwX", "/var/lib/cuttlefish"])
        {
            debug!(
                target: "cfctl",
                "reset_cuttlefish_permissions: ignoring chmod: {}",
                err
            );
        }
    }

    fn guest_log_tail(&self, id: InstanceId, lines: usize) -> Result<Option<String>> {
        let paths = self.paths(id);
        if !paths.run_log_path().exists() {
            return Ok(None);
        }
        let content = tail_file(paths.run_log_path(), lines)?;
        Ok(Some(content))
    }
}
