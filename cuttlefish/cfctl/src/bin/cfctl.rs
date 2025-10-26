use std::sync::atomic::{AtomicBool, Ordering};
use std::{
    io::{BufRead, BufReader, Write},
    net::Shutdown,
    os::unix::net::UnixStream,
    path::PathBuf,
    process,
    sync::Arc,
    thread,
    time::Duration,
};

use anyhow::{anyhow, Result};
use cfctl::{
    DeployRequest, DestroyOptions, InstanceId, LogsOptions, Request, Response, StartOptions,
};
use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(name = "cfctl", about = "CLI for the cfctl daemon", version)]
struct Cli {
    #[arg(long, env = "CFCTL_SOCKET", default_value = "/run/cfctl.sock")]
    socket: PathBuf,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    #[command(subcommand)]
    Instance(InstanceCommands),
    /// Copy boot/init images into the instance workspace and update env.
    Deploy {
        id: InstanceId,
        #[arg(long)]
        boot: Option<PathBuf>,
        #[arg(long)]
        init: Option<PathBuf>,
    },
    /// Wait for the instance adb socket to accept TCP connections.
    WaitAdb {
        id: InstanceId,
        #[arg(long)]
        timeout_secs: Option<u64>,
    },
    /// Fetch recent journal entries for the instance.
    Logs {
        id: InstanceId,
        #[arg(long)]
        lines: Option<usize>,
        #[arg(long)]
        timeout_secs: Option<u64>,
        #[arg(long)]
        stdout: bool,
    },
}

#[derive(Debug, Subcommand)]
enum InstanceCommands {
    /// Create a new instance.
    Create {
        #[arg(long)]
        purpose: Option<String>,
    },
    /// Start the systemd unit for the instance.
    Start {
        id: InstanceId,
        #[arg(long)]
        disable_webrtc: bool,
        #[arg(long)]
        timeout_secs: Option<u64>,
        #[arg(long)]
        verify_boot: bool,
        #[arg(long)]
        skip_adb_wait: bool,
    },
    /// Create and immediately start a new instance.
    CreateStart {
        #[arg(long)]
        purpose: Option<String>,
        #[arg(long)]
        disable_webrtc: bool,
        #[arg(long)]
        timeout_secs: Option<u64>,
        #[arg(long)]
        verify_boot: bool,
        #[arg(long)]
        skip_adb_wait: bool,
        #[arg(long)]
        track: Option<String>,
    },
    /// Stop the systemd unit for the instance.
    Stop { id: InstanceId },
    /// Hold the instance to prevent pruning.
    Hold { id: InstanceId },
    /// Destroy the instance and cleanup files.
    Destroy {
        id: InstanceId,
        #[arg(long)]
        timeout_secs: Option<u64>,
    },
    /// Show the instance status.
    Status { id: InstanceId },
    /// Describe the instance with detailed diagnostics.
    Describe {
        id: InstanceId,
        #[arg(long, default_value_t = 50)]
        run_log_lines: usize,
    },
    /// List all known instances.
    List,
    /// Trigger expired instance pruning.
    Prune {
        #[arg(long, default_value_t = 24 * 60 * 60, help = "Maximum instance age before pruning in seconds")]
        max_age_secs: u64,
        #[arg(long)]
        all: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let response = match cli.command {
        Commands::Instance(cmd) => match cmd {
            InstanceCommands::Create { purpose } => {
                send_request(&cli.socket, Request::CreateInstance { purpose })?
            }
            InstanceCommands::Start {
                id,
                disable_webrtc,
                timeout_secs,
                verify_boot,
                skip_adb_wait,
            } => {
                let options = StartOptions {
                    disable_webrtc,
                    timeout_secs,
                    verify_boot,
                    skip_adb_wait,
                    track: None,  // Start command doesn't support track yet
                };
                send_request(&cli.socket, Request::StartInstance { id, options })?
            }
            InstanceCommands::CreateStart {
                purpose,
                disable_webrtc,
                timeout_secs,
                verify_boot,
                skip_adb_wait,
                track,
            } => {
                let options = StartOptions {
                    disable_webrtc,
                    timeout_secs,
                    verify_boot,
                    skip_adb_wait,
                    track,
                };
                send_request(
                    &cli.socket,
                    Request::CreateStartInstance { purpose, options },
                )?
            }
            InstanceCommands::Stop { id } => {
                send_request(&cli.socket, Request::StopInstance { id })?
            }
            InstanceCommands::Hold { id } => {
                send_request(&cli.socket, Request::HoldInstance { id })?
            }
            InstanceCommands::Destroy { id, timeout_secs } => {
                let options = DestroyOptions { timeout_secs };
                let progress = ProgressPrinter::spawn(
                    format!("Destroying instance {}", id),
                    Duration::from_secs(2),
                );
                let response = send_request(&cli.socket, Request::DestroyInstance { id, options })?;
                drop(progress);
                emit_cleanup_feedback(&response);
                response
            }
            InstanceCommands::Status { id } => send_request(&cli.socket, Request::Status { id })?,
            InstanceCommands::Describe { id, run_log_lines } => send_request(
                &cli.socket,
                Request::Describe {
                    id,
                    run_log_lines: Some(run_log_lines),
                },
            )?,
            InstanceCommands::List => send_request(&cli.socket, Request::ListInstances)?,
            InstanceCommands::Prune { max_age_secs, all } => {
                if all {
                    send_request(&cli.socket, Request::PruneAll)?
                } else {
                    send_request(&cli.socket, Request::PruneExpired { max_age_secs })?
                }
            }
        },
        Commands::Deploy { id, boot, init } => {
            if boot.is_none() && init.is_none() {
                return Err(anyhow!("deploy requires --boot and/or --init"));
            }
            let req = DeployRequest {
                id,
                boot_image: boot.map(|p| p.to_string_lossy().to_string()),
                init_boot_image: init.map(|p| p.to_string_lossy().to_string()),
            };
            send_request(&cli.socket, Request::Deploy(req))?
        }
        Commands::WaitAdb { id, timeout_secs } => {
            send_request(&cli.socket, Request::WaitForAdb { id, timeout_secs })?
        }
        Commands::Logs {
            id,
            lines,
            timeout_secs,
            stdout,
        } => {
            let options = LogsOptions {
                timeout_secs,
                stream_stdout: stdout,
            };
            let response = send_request(&cli.socket, Request::Logs { id, lines, options })?;
            match (stdout, response.ok) {
                (true, true) => {
                    if let Some(logs) = &response.logs {
                        if let Some(journal) = &logs.journal {
                            print!("{journal}");
                        }
                    }
                    return Ok(());
                }
                _ => {
                    let output = serde_json::to_string_pretty(&response)?;
                    println!("{}", output);
                    if response.ok {
                        return Ok(());
                    } else {
                        process::exit(1);
                    }
                }
            }
        }
    };

    let output = serde_json::to_string_pretty(&response)?;
    println!("{}", output);

    if response.ok {
        Ok(())
    } else {
        process::exit(1);
    }
}

fn send_request(socket: &PathBuf, request: Request) -> Result<Response> {
    let mut stream =
        UnixStream::connect(socket).map_err(|err| anyhow!("connect to {:?}: {}", socket, err))?;
    let payload = serde_json::to_vec(&request)?;
    stream.write_all(&payload)?;
    stream.write_all(b"\n")?;
    stream.shutdown(Shutdown::Write)?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .map_err(|err| anyhow!("read response: {}", err))?;
    if line.trim().is_empty() {
        return Err(anyhow!("empty response from daemon"));
    }
    let response: Response =
        serde_json::from_str(&line).map_err(|err| anyhow!("decode response JSON: {}", err))?;
    Ok(response)
}

struct ProgressPrinter {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl ProgressPrinter {
    fn spawn(message: String, interval: Duration) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);

        let handle = thread::spawn(move || {
            let mut stderr = std::io::stderr();
            let _ = write!(stderr, "{}", message);
            let _ = stderr.flush();
            while !thread_stop.load(Ordering::SeqCst) {
                thread::sleep(interval);
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                let _ = write!(stderr, ".");
                let _ = stderr.flush();
            }
        });

        Self {
            stop,
            handle: Some(handle),
        }
    }
}

impl Drop for ProgressPrinter {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        let _ = writeln!(std::io::stderr());
    }
}

fn emit_cleanup_feedback(response: &Response) {
    if !response.ok {
        if let Some(error) = &response.error {
            let msg = error
                .message
                .as_deref()
                .unwrap_or("destroy failed without details");
            eprintln!("Destroy failed: {} ({})", msg, error.code);
        }
        return;
    }

    if let Some(action) = response.action.as_ref() {
        if let Some(cleanup) = action.cleanup.as_ref() {
            if cleanup.guest_processes_killed {
                eprintln!("Destroy finished: no surviving processes.");
            } else if cleanup.remaining_pids.is_empty() {
                eprintln!("Destroy finished: cleanup executed.");
            } else {
                eprintln!(
                    "Destroy finished: remaining processes {:?}",
                    cleanup.remaining_pids
                );
            }
            if !cleanup.steps.is_empty() {
                eprintln!("  Steps: {}", cleanup.steps.join(" -> "));
            }
        }
    }
}
