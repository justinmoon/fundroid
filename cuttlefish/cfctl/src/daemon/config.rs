use std::path::PathBuf;
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct CfctlDaemonConfig {
    pub socket_path: PathBuf,
    pub state_dir: PathBuf,
    pub etc_instances_dir: PathBuf,
    pub default_boot_image: PathBuf,
    pub default_init_boot_image: PathBuf,
    pub start_timeout: Duration,
    pub adb_wait_timeout: Duration,
    pub journal_lines: usize,
    pub adb_host: String,
    pub base_adb_port: u16,
    pub cuttlefish_fhs: PathBuf,
    pub cuttlefish_instances_dir: PathBuf,
    pub cuttlefish_assembly_dir: PathBuf,
    pub cuttlefish_system_image_dir: PathBuf,
    pub disable_host_gpu: bool,
}

impl Default for CfctlDaemonConfig {
    fn default() -> Self {
        Self {
            socket_path: PathBuf::from("/run/cfctl.sock"),
            state_dir: PathBuf::from("/var/lib/cfctl"),
            etc_instances_dir: PathBuf::from("/etc/cuttlefish/instances"),
            default_boot_image: PathBuf::from("/var/lib/cuttlefish/images/boot.img"),
            default_init_boot_image: PathBuf::from("/var/lib/cuttlefish/images/init_boot.img"),
            start_timeout: Duration::from_secs(120),
            adb_wait_timeout: Duration::from_secs(90),
            journal_lines: 200,
            adb_host: "127.0.0.1".to_string(),
            base_adb_port: 6520,
            cuttlefish_fhs: PathBuf::from("/run/current-system/sw/bin/cuttlefish-fhs"),
            cuttlefish_instances_dir: PathBuf::from("/var/lib/cuttlefish/instances"),
            cuttlefish_assembly_dir: PathBuf::from("/var/lib/cuttlefish/assembly"),
            cuttlefish_system_image_dir: PathBuf::from("/var/lib/cuttlefish/images"),
            disable_host_gpu: true,
        }
    }
}
