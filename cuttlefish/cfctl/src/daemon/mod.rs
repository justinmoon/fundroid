mod config;
mod guest;
mod manager;
mod util;

pub use config::CfctlDaemonConfig;

use std::{fs, os::unix::fs::PermissionsExt, sync::Arc, thread};

use anyhow::{Context, Result};
use dashmap::DashMap;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixListener,
    sync::{Mutex as AsyncMutex, OwnedMutexGuard},
    task,
};
use tracing::{debug, error, info, warn};

use crate::protocol::{InstanceId, Request, Response};

use guest::GuestRegistry;
use manager::InstanceManager;

#[derive(Clone)]
pub struct CfctlDaemon {
    config: Arc<CfctlDaemonConfig>,
    instance_locks: Arc<DashMap<InstanceId, Arc<AsyncMutex<()>>>>,
    id_lock: Arc<AsyncMutex<()>>,
    guest_registry: Arc<GuestRegistry>,
}

impl CfctlDaemon {
    pub fn new(config: CfctlDaemonConfig) -> Self {
        Self {
            config: Arc::new(config),
            instance_locks: Arc::new(DashMap::new()),
            id_lock: Arc::new(AsyncMutex::new(())),
            guest_registry: Arc::new(GuestRegistry::new()),
        }
    }

    pub async fn run(&self) -> Result<()> {
        let config = (*self.config).clone();
        Self::ensure_dirs(&config)?;
        Self::sweep_trash(&config);

        if config.socket_path.exists() {
            fs::remove_file(&config.socket_path).with_context(|| {
                format!(
                    "removing pre-existing socket {}",
                    config.socket_path.display()
                )
            })?;
        }

        let listener = UnixListener::bind(&config.socket_path)
            .with_context(|| format!("binding socket {}", config.socket_path.display()))?;
        fs::set_permissions(&config.socket_path, fs::Permissions::from_mode(0o660))?;

        info!("cfctl daemon listening on {}", config.socket_path.display());

        loop {
            let (stream, _) = listener.accept().await?;
            let daemon = self.clone();
            task::spawn(async move {
                if let Err(err) = daemon.handle_stream(stream).await {
                    error!("connection handler error: {:#}", err);
                }
            });
        }
    }

    fn ensure_dirs(config: &CfctlDaemonConfig) -> Result<()> {
        fs::create_dir_all(&config.state_dir)
            .with_context(|| format!("creating state dir {}", config.state_dir.display()))?;
        fs::create_dir_all(&config.etc_instances_dir)
            .with_context(|| format!("creating etc dir {}", config.etc_instances_dir.display()))?;

        if let Some(parent) = config.socket_path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("creating socket dir {}", parent.display()))?;
        }

        Ok(())
    }

    fn sweep_trash(config: &CfctlDaemonConfig) {
        let bases = [
            &config.cuttlefish_instances_dir,
            &config.cuttlefish_assembly_dir,
        ];
        for base in bases {
            let Ok(entries) = fs::read_dir(base) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                    continue;
                };
                if !name.contains(".__trash__.") {
                    continue;
                }
                debug!(
                    target: "cfctl",
                    "sweep_trash: scheduling removal of {}",
                    path.display()
                );
                thread::spawn(move || {
                    if let Err(err) = fs::remove_dir_all(&path) {
                        warn!(
                            target: "cfctl",
                            "sweep_trash: failed removing {}: {}",
                            path.display(),
                            err
                        );
                    } else {
                        debug!(
                            target: "cfctl",
                            "sweep_trash: removed {}",
                            path.display()
                        );
                    }
                });
            }
        }
    }

    async fn handle_stream(&self, stream: tokio::net::UnixStream) -> Result<()> {
        info!(target: "cfctl", "handle_stream: new connection received");
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        let bytes = reader.read_line(&mut line).await?;
        if bytes == 0 {
            info!(target: "cfctl", "handle_stream: empty request, closing connection");
            return Ok(());
        }

        debug!(target: "cfctl", "handle_stream: received request: {}", line.trim());
        let request: Request = serde_json::from_str(&line)
            .with_context(|| format!("decoding request JSON: {}", line.trim()))?;

        info!(target: "cfctl", "handle_stream: parsed request: {:?}", request);

        let response = self.dispatch(request).await.unwrap_or_else(|err| {
            error!(target: "cfctl", "handle_stream: request error: {:#}", err);
            Response::error(err.to_string())
        });

        info!(target: "cfctl", "handle_stream: dispatch completed, preparing response");
        debug!(target: "cfctl", "handle_stream: sending response: {:?}", response);
        let mut stream = reader.into_inner();
        let json = serde_json::to_vec(&response)?;
        debug!(
            target: "cfctl",
            "handle_stream: serialized response ({} bytes)", json.len()
        );
        stream.write_all(&json).await?;
        debug!(target: "cfctl", "handle_stream: wrote response body");
        stream.write_all(b"\n").await?;
        debug!(target: "cfctl", "handle_stream: wrote newline terminator");
        stream.shutdown().await?;
        info!(target: "cfctl", "handle_stream: response sent, connection closed");
        Ok(())
    }

    async fn dispatch(&self, request: Request) -> Result<Response> {
        let request_label = describe_request(&request);
        info!(target: "cfctl", "dispatch: processing request: {}", request_label);
        use Request::*;

        let maybe_instance_id = match &request {
            StartInstance { id, .. }
            | StopInstance { id }
            | HoldInstance { id }
            | DestroyInstance { id, .. }
            | WaitForAdb { id, .. }
            | Logs { id, .. }
            | Status { id }
            | Describe { id, .. } => Some(*id),
            Deploy(req) => Some(req.id),
            _ => None,
        };

        let mut instance_guard: Option<(InstanceId, OwnedMutexGuard<()>)> = None;
        if let Some(id) = maybe_instance_id {
            let guard = self.lock_instance(id).await;
            instance_guard = Some((id, guard));
        }

        let mut id_guard: Option<OwnedMutexGuard<()>> = None;
        if matches!(request, CreateInstance { .. } | CreateStartInstance { .. }) {
            id_guard = Some(self.id_lock.clone().lock_owned().await);
        }

        let instance_id_for_cleanup = instance_guard.as_ref().map(|(id, _)| *id);
        let instance_guard_owned = instance_guard.map(|(_, guard)| guard);
        let id_guard_owned = id_guard;
        let config = self.config.clone();
        let guest_registry = self.guest_registry.clone();
        debug!(
            target: "cfctl",
            "dispatch: acquired locks for {}",
            request_label
        );

        let response = match request {
            other => {
                let result = task::spawn_blocking(move || {
                    let _id_guard = id_guard_owned;
                    let _instance_guard = instance_guard_owned;
                    let mut manager = InstanceManager::new((*config).clone(), guest_registry);
                    manager.handle(other)
                })
                .await;

                let result = match result {
                    Ok(inner) => {
                        debug!(
                            target: "cfctl",
                            "dispatch: completed blocking handler for {}",
                            request_label
                        );
                        inner
                    }
                    Err(err) => {
                        error!(
                            target: "cfctl",
                            "dispatch: join error for {}: {}",
                            request_label,
                            err
                        );
                        return Err(err.into());
                    }
                }?;

                result
            }
        };

        if let Some(id) = instance_id_for_cleanup {
            self.cleanup_instance_lock(id);
        }

        info!(
            target: "cfctl",
            "dispatch: returning response for {}",
            request_label
        );
        Ok(response)
    }

    async fn lock_instance(&self, id: InstanceId) -> OwnedMutexGuard<()> {
        use dashmap::mapref::entry::Entry;
        let lock_arc = match self.instance_locks.entry(id) {
            Entry::Occupied(entry) => entry.get().clone(),
            Entry::Vacant(entry) => entry.insert(Arc::new(AsyncMutex::new(()))).clone(),
        };
        lock_arc.lock_owned().await
    }

    fn cleanup_instance_lock(&self, id: InstanceId) {
        if let Some(entry) = self.instance_locks.get(&id) {
            let should_remove = Arc::strong_count(entry.value()) == 1;
            if should_remove {
                drop(entry);
                self.instance_locks.remove(&id);
            }
        }
    }
}

fn describe_request(request: &Request) -> String {
    match request {
        Request::CreateInstance { .. } => "CreateInstance".to_string(),
        Request::CreateStartInstance { .. } => "CreateStartInstance".to_string(),
        Request::StartInstance { id, .. } => format!("StartInstance({})", id),
        Request::StopInstance { id } => format!("StopInstance({})", id),
        Request::HoldInstance { id } => format!("HoldInstance({})", id),
        Request::DestroyInstance { id, .. } => format!("DestroyInstance({})", id),
        Request::Deploy(req) => format!("Deploy({})", req.id),
        Request::WaitForAdb { id, .. } => format!("WaitForAdb({})", id),
        Request::Logs { id, .. } => format!("Logs({})", id),
        Request::Status { id } => format!("Status({})", id),
        Request::Describe { id, .. } => format!("Describe({})", id),
        Request::ListInstances => "ListInstances".to_string(),
        Request::PruneExpired { max_age_secs } => {
            format!("PruneExpired(max_age_secs={})", max_age_secs)
        }
        Request::PruneAll => "PruneAll".to_string(),
    }
}
