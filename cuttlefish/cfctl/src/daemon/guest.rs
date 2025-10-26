use std::{
    io,
    os::unix::process::ExitStatusExt,
    process::Child,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

use anyhow::{anyhow, Result};
use dashmap::DashMap;
use libc::{c_int, pid_t};

use crate::protocol::InstanceId;

#[derive(Debug, Clone, Copy)]
pub struct ExitStatusInfo {
    pub code: Option<i32>,
    pub signal: Option<i32>,
}

impl ExitStatusInfo {
    pub fn success(&self) -> bool {
        self.code == Some(0) && self.signal.is_none()
    }

    pub fn describe(&self) -> String {
        match (self.code, self.signal) {
            (Some(code), None) => format!("exit code {}", code),
            (None, Some(sig)) => format!("signal {}", sig),
            (Some(code), Some(sig)) => format!("exit code {} (signal {})", code, sig),
            (None, None) => "unknown status".to_string(),
        }
    }
}

#[derive(Debug)]
struct ChildState {
    child: Option<Child>,
    exit: Option<ExitStatusInfo>,
}

impl ChildState {
    fn new(child: Child) -> Self {
        Self {
            child: Some(child),
            exit: None,
        }
    }
}

#[derive(Debug)]
pub struct GuestHandle {
    pid: pid_t,
    state: Mutex<ChildState>,
}

impl GuestHandle {
    pub fn new(child: Child) -> Self {
        let pid = child.id() as pid_t;
        Self {
            pid,
            state: Mutex::new(ChildState::new(child)),
        }
    }

    pub fn pid(&self) -> pid_t {
        self.pid
    }

    pub fn try_wait(&self) -> Result<Option<ExitStatusInfo>> {
        let mut state = self.state.lock().expect("poisoned guest handle mutex");
        if let Some(exit) = state.exit {
            return Ok(Some(exit));
        }
        if let Some(child) = state.child.as_mut() {
            match child.try_wait()? {
                Some(status) => {
                    let exit = ExitStatusInfo {
                        code: status.code(),
                        signal: status.signal(),
                    };
                    state.child = None;
                    state.exit = Some(exit);
                    Ok(Some(exit))
                }
                None => Ok(None),
            }
        } else {
            Ok(state.exit)
        }
    }

    pub fn wait(&self) -> Result<ExitStatusInfo> {
        let mut state = self.state.lock().expect("poisoned guest handle mutex");
        if let Some(exit) = state.exit {
            return Ok(exit);
        }

        if let Some(mut child) = state.child.take() {
            let status = child.wait()?;
            let exit = ExitStatusInfo {
                code: status.code(),
                signal: status.signal(),
            };
            state.exit = Some(exit);
            Ok(exit)
        } else {
            Err(anyhow!("guest process already awaited"))
        }
    }

    pub fn wait_timeout(&self, timeout: Duration) -> Result<Option<ExitStatusInfo>> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(exit) = self.try_wait()? {
                return Ok(Some(exit));
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            thread::sleep(Duration::from_millis(200));
        }
    }

    pub fn signal(&self, signal: c_int) -> Result<()> {
        let result = unsafe { libc::kill(self.pid, signal) };
        if result == 0 {
            Ok(())
        } else {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::ESRCH) {
                Ok(())
            } else {
                Err(err.into())
            }
        }
    }
}

#[derive(Debug)]
pub struct GuestRegistry {
    handles: DashMap<InstanceId, Arc<GuestHandle>>,
}

impl GuestRegistry {
    pub fn new() -> Self {
        Self {
            handles: DashMap::new(),
        }
    }

    pub fn insert(&self, id: InstanceId, handle: Arc<GuestHandle>) -> Option<Arc<GuestHandle>> {
        self.handles.insert(id, handle)
    }

    pub fn get(&self, id: InstanceId) -> Option<Arc<GuestHandle>> {
        self.handles.get(&id).map(|entry| Arc::clone(entry.value()))
    }

    pub fn contains(&self, id: InstanceId) -> bool {
        self.handles.contains_key(&id)
    }

    pub fn remove_if_handle(
        &self,
        id: InstanceId,
        handle: &Arc<GuestHandle>,
    ) -> Option<Arc<GuestHandle>> {
        if let Some(existing) = self.handles.get(&id) {
            if Arc::ptr_eq(existing.value(), handle) {
                drop(existing);
                return self.handles.remove(&id).map(|(_, handle)| handle);
            }
        }
        None
    }
}
