use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;
use cfctl::{CfctlDaemon, CfctlDaemonConfig};
use clap::Parser;
use tracing_subscriber::{fmt, EnvFilter};

#[derive(Debug, Parser)]
#[command(name = "cfctl-daemon", about = "Cuttlefish control daemon", version)]
struct Args {
    #[arg(long, env = "CFCTL_SOCKET", default_value = "/run/cfctl.sock")]
    socket: PathBuf,
    #[arg(long, env = "CFCTL_STATE_DIR", default_value = "/var/lib/cfctl")]
    state_dir: PathBuf,
    #[arg(
        long,
        env = "CFCTL_ETC_DIR",
        default_value = "/etc/cuttlefish/instances"
    )]
    etc_instances_dir: PathBuf,
    #[arg(
        long,
        env = "CFCTL_DEFAULT_BOOT",
        default_value = "/var/lib/cuttlefish/images/boot.img"
    )]
    default_boot_image: PathBuf,
    #[arg(
        long,
        env = "CFCTL_DEFAULT_INIT_BOOT",
        default_value = "/var/lib/cuttlefish/images/init_boot.img"
    )]
    default_init_boot_image: PathBuf,
    #[arg(long, env = "CFCTL_START_TIMEOUT_SECS", default_value_t = 120)]
    start_timeout_secs: u64,
    #[arg(long, env = "CFCTL_ADB_TIMEOUT_SECS", default_value_t = 90)]
    adb_timeout_secs: u64,
    #[arg(long, env = "CFCTL_JOURNAL_LINES", default_value_t = 200)]
    journal_lines: usize,
    #[arg(long, env = "CFCTL_ADB_HOST", default_value = "127.0.0.1")]
    adb_host: String,
    #[arg(long, env = "CFCTL_BASE_ADB_PORT", default_value_t = 6520)]
    base_adb_port: u16,
    #[arg(
        long,
        env = "CFCTL_CUTTLEFISH_FHS",
        default_value = "/run/current-system/sw/bin/cuttlefish-fhs"
    )]
    cuttlefish_fhs: PathBuf,
    #[arg(
        long,
        env = "CFCTL_CUTTLEFISH_INSTANCES_DIR",
        default_value = "/var/lib/cuttlefish/instances"
    )]
    cuttlefish_instances_dir: PathBuf,
    #[arg(
        long,
        env = "CFCTL_CUTTLEFISH_ASSEMBLY_DIR",
        default_value = "/var/lib/cuttlefish/assembly"
    )]
    cuttlefish_assembly_dir: PathBuf,
    #[arg(
        long,
        env = "CFCTL_CUTTLEFISH_SYSTEM_IMAGE_DIR",
        default_value = "/var/lib/cuttlefish/images"
    )]
    cuttlefish_system_image_dir: PathBuf,
    #[arg(long, env = "CFCTL_DISABLE_HOST_GPU", default_value_t = true)]
    disable_host_gpu: bool,
    #[arg(long, env = "CFCTL_GUEST_USER", default_value = "justin")]
    guest_user: String,
    #[arg(long, env = "CFCTL_GUEST_PRIMARY_GROUP", default_value = "cvdnetwork")]
    guest_primary_group: String,
    #[arg(
        long,
        env = "CFCTL_GUEST_SUPPLEMENTARY_GROUPS",
        default_value = "cvdnetwork,kvm",
        value_delimiter = ','
    )]
    guest_supplementary_groups: Vec<String>,
    #[arg(
        long,
        env = "CFCTL_GUEST_CAPABILITIES",
        default_value = "net_admin",
        value_delimiter = ','
    )]
    guest_capabilities: Vec<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info,cfctl=info"));
    fmt().with_env_filter(filter).init();

    let config = CfctlDaemonConfig {
        socket_path: args.socket,
        state_dir: args.state_dir,
        etc_instances_dir: args.etc_instances_dir,
        default_boot_image: args.default_boot_image,
        default_init_boot_image: args.default_init_boot_image,
        start_timeout: Duration::from_secs(args.start_timeout_secs),
        adb_wait_timeout: Duration::from_secs(args.adb_timeout_secs),
        journal_lines: args.journal_lines,
        adb_host: args.adb_host,
        base_adb_port: args.base_adb_port,
        cuttlefish_fhs: args.cuttlefish_fhs,
        cuttlefish_instances_dir: args.cuttlefish_instances_dir,
        cuttlefish_assembly_dir: args.cuttlefish_assembly_dir,
        cuttlefish_system_image_dir: args.cuttlefish_system_image_dir,
        disable_host_gpu: args.disable_host_gpu,
        guest_user: args.guest_user,
        guest_primary_group: args.guest_primary_group,
        guest_supplementary_groups: args.guest_supplementary_groups,
        guest_capabilities: args.guest_capabilities,
    };

    let daemon = CfctlDaemon::new(config);
    daemon.run().await
}
