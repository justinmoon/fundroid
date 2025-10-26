use serde::{Deserialize, Serialize};

pub type InstanceId = u64;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstanceSummary {
    pub id: InstanceId,
    pub adb: Option<AdbInfo>,
    pub state: InstanceState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdbInfo {
    pub host: String,
    pub port: u16,
    pub serial: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum InstanceState {
    #[default]
    Unknown,
    Created,
    Starting,
    Running,
    Stopped,
    Failed,
    Destroyed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateInstanceResponse {
    pub summary: InstanceSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstanceActionResponse {
    pub summary: InstanceSummary,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub journal_tail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verification: Option<BootVerificationResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cleanup: Option<CleanupSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogsResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub journal: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub console_log_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeployRequest {
    pub id: InstanceId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub boot_image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub init_boot_image: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StartOptions {
    #[serde(default)]
    pub disable_webrtc: bool,
    #[serde(default)]
    pub timeout_secs: Option<u64>,
    #[serde(default)]
    pub verify_boot: bool,
    #[serde(default)]
    pub skip_adb_wait: bool,
    #[serde(default)]
    pub track: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DestroyOptions {
    #[serde(default)]
    pub timeout_secs: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LogsOptions {
    #[serde(default)]
    pub timeout_secs: Option<u64>,
    #[serde(default)]
    pub stream_stdout: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BootVerificationResult {
    pub adb_ready: bool,
    pub boot_marker_observed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorDetail {
    pub code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CleanupSummary {
    pub guest_processes_killed: bool,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub remaining_pids: Vec<i32>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub steps: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Request {
    CreateInstance {
        #[serde(skip_serializing_if = "Option::is_none")]
        purpose: Option<String>,
    },
    StartInstance {
        id: InstanceId,
        #[serde(default)]
        options: StartOptions,
    },
    CreateStartInstance {
        #[serde(skip_serializing_if = "Option::is_none")]
        purpose: Option<String>,
        #[serde(default)]
        options: StartOptions,
    },
    StopInstance {
        id: InstanceId,
    },
    HoldInstance {
        id: InstanceId,
    },
    DestroyInstance {
        id: InstanceId,
        #[serde(default)]
        options: DestroyOptions,
    },
    Deploy(DeployRequest),
    WaitForAdb {
        id: InstanceId,
        #[serde(default)]
        timeout_secs: Option<u64>,
    },
    Logs {
        id: InstanceId,
        #[serde(default)]
        lines: Option<usize>,
        #[serde(default)]
        options: LogsOptions,
    },
    Status {
        id: InstanceId,
    },
    ListInstances,
    PruneExpired {
        max_age_secs: u64,
    },
    PruneAll,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub create: Option<CreateInstanceResponse>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<InstanceActionResponse>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logs: Option<LogsResponse>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instances: Option<Vec<InstanceSummary>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorDetail>,
}

impl Response {
    pub fn ok() -> Self {
        Self {
            ok: true,
            message: None,
            create: None,
            action: None,
            logs: None,
            instances: None,
            error: None,
        }
    }

    pub fn with_message(mut self, msg: impl Into<String>) -> Self {
        self.message = Some(msg.into());
        self
    }

    pub fn error(msg: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: Some(msg.into()),
            create: None,
            action: None,
            logs: None,
            instances: None,
            error: None,
        }
    }

    pub fn error_with_detail(detail: ErrorDetail) -> Self {
        Self {
            ok: false,
            message: None,
            create: None,
            action: None,
            logs: None,
            instances: None,
            error: Some(detail),
        }
    }
}
