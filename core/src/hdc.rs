//! `hdc` process wrapper and session bootstrap.

use std::io::Read; // 两条管道必须与子进程执行并行读取。
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::sleep;
use std::time::{Duration, Instant};

pub struct Hdc<'a> {
    pub binary: PathBuf,
    cancelled: Option<&'a AtomicBool>, // 启动阶段共享取消标记，清理阶段使用独立 Hdc。
}

impl<'a> Hdc<'a> {
    pub fn new(binary: impl Into<PathBuf>) -> Self {
        Self {
            binary: binary.into(),
            cancelled: None,
        }
    }

    pub fn with_cancellation(mut self, cancelled: &'a AtomicBool) -> Self {
        self.cancelled = Some(cancelled);
        self
    }

    fn check_cancelled(&self) -> Result<(), String> {
        if self
            .cancelled
            .is_some_and(|flag| flag.load(Ordering::Relaxed))
        {
            return Err("连接已取消".into());
        }
        Ok(())
    }

    fn wait(&self, duration: Duration) -> Result<(), String> {
        let deadline = Instant::now() + duration;
        while Instant::now() < deadline {
            self.check_cancelled()?;
            sleep(
                deadline
                    .saturating_duration_since(Instant::now())
                    .min(Duration::from_millis(40)),
            );
        }
        self.check_cancelled()
    }

    pub fn run(&self, args: &[&str], timeout: Duration) -> Result<String, String> {
        self.check_cancelled()?;
        let mut command = Command::new(&self.binary);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW：投屏和键盘输入不弹出控制台。
        }
        let mut child = command
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("无法执行 hdc: {error}"))?;

        let stdout = child.stdout.take().ok_or("无法捕获 hdc stdout")?; // 把管道所有权移交读线程。
        let stderr = child.stderr.take().ok_or("无法捕获 hdc stderr")?; // stderr 也必须独立排空。
        let collect = |mut pipe: Box<dyn Read + Send>| {
            // 两个线程使用相同的收集逻辑。
            let mut bytes = Vec::new(); // 保存完整命令输出。
            pipe.read_to_end(&mut bytes).map(|_| bytes) // 读取直到子进程关闭写端。
        };
        let out = std::thread::spawn(move || collect(Box::new(stdout))); // 防止 stdout 写满。
        let err = std::thread::spawn(move || collect(Box::new(stderr))); // 防止 stderr 写满。
        let deadline = Instant::now() + timeout;
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Ok(None) if Instant::now() < deadline && self.check_cancelled().is_ok() => {
                    sleep(Duration::from_millis(20))
                }
                Ok(None) => {
                    let _ = child.kill(); // 结束超过期限的进程。
                    let _ = child.wait(); // 必须回收子进程，避免遗留僵尸。
                    break Err(self
                        .check_cancelled()
                        .err()
                        .unwrap_or_else(|| "hdc 命令超时".into()));
                }
                Err(error) => {
                    let _ = child.kill(); // 查询失败也不能丢弃仍在运行的子进程。
                    let _ = child.wait();
                    break Err(error.to_string());
                }
            }
        };
        let stdout = out.join().map_err(|_| "stdout 读取线程异常")?; // 等待已排空的输出。
        let stderr = err.join().map_err(|_| "stderr 读取线程异常")?; // 任何退出路径都回收读线程。
        let status = status?; // 优先报告超时或进程状态错误。
        let stdout = stdout.map_err(|error| error.to_string())?;
        let stderr = stderr.map_err(|error| error.to_string())?;
        let text = String::from_utf8_lossy(&stdout).to_string() + &String::from_utf8_lossy(&stderr);
        if !status.success()
            || text.contains("Connect server failed")
            || text
                .lines()
                .any(|line| line.trim_start().starts_with("[Fail]"))
        {
            return Err(if text.trim().is_empty() {
                format!("hdc 失败: {}", args.join(" "))
            } else {
                text
            });
        }
        Ok(text)
    }

    pub fn shell(&self, serial: &str, command: &str) -> Result<String, String> {
        self.run(&["-t", serial, "shell", command], Duration::from_secs(25))
    }

    pub fn targets(&self) -> Result<Vec<String>, String> {
        let output = self.run(&["list", "targets"], Duration::from_secs(10))?;
        Ok(output
            .lines()
            .map(|line| line.trim().to_string())
            .filter(|line| {
                !line.is_empty() && !line.contains("[Empty]") && line.to_lowercase() != "empty"
            })
            .collect())
    }

    fn push_capture_asset(&self, serial: &str, local: &Path, remote: &str) -> Result<(), String> {
        let output = self.run(
            &[
                "-t",
                serial,
                "file",
                "send",
                &local.to_string_lossy(),
                remote,
            ],
            Duration::from_secs(120),
        )?;
        if !output.contains("FileTransfer finish") {
            return Err(format!("未收到采集组件写入确认：{output}"));
        }
        Ok(())
    }

    pub fn forward(&self, serial: &str, port: u16, remote: &str) -> Result<(), String> {
        self.run(
            &["-t", serial, "fport", &format!("tcp:{port}"), remote],
            Duration::from_secs(15),
        )
        .and_then(|output| {
            if output.contains("Forward parament failed") {
                Err(output)
            } else {
                Ok(())
            }
        })
    }

    pub fn remove_forward(&self, serial: &str, port: u16) {
        let _ = self.run(
            &["-t", serial, "fport", "rm", &format!("tcp:{port}")],
            Duration::from_secs(10),
        );
    }
}

pub struct StartedSession {
    pub serial: String,
    pub video_port: u16,
    pub control_port: u16,
    pub width: u32,
    pub height: u32,
}

pub fn free_port() -> Result<u16, String> {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).map_err(|e| e.to_string())?;
    listener
        .local_addr()
        .map(|addr| addr.port())
        .map_err(|e| e.to_string())
}

fn version_parts(text: &str) -> Vec<u32> {
    text.trim()
        .split('.')
        .map(|part| {
            part.chars()
                .take_while(|c| c.is_ascii_digit())
                .collect::<String>()
        })
        .map(|part| part.parse().unwrap_or(0))
        .collect()
}

fn at_least(version: &[u32], target: &[u32]) -> bool {
    for index in 0..target.len().max(version.len()) {
        let left = version.get(index).copied().unwrap_or(0);
        let right = target.get(index).copied().unwrap_or(0);
        if left != right {
            return left > right;
        }
    }
    true
}

pub fn bootstrap(
    hdc: &Hdc,
    resources: &Path,
    serial: &str,
    frame_rate: u32,
    bitrate_mbps: u32,
    scale: f64,
    log: &mut dyn FnMut(&str),
) -> Result<StartedSession, String> {
    log(&format!("检查设备 {serial}…"));
    if !hdc.targets()?.iter().any(|target| target == serial) {
        return Err(format!("设备未连接：{serial}"));
    }

    let script = "\
        echo __V__; /system/bin/uitest --version; \
        echo __E__; ls /system/lib64/libCPHMediaEngine.z.so 2>&1; \
        echo __S__; SP_daemon -screen 2>&1";
    let output = hdc.shell(serial, script)?;

    let section = |name: &str| -> String {
        let marker = format!("__{name}__");
        if let Some(start) = output.find(&marker) {
            let rest = &output[start + marker.len()..];
            if let Some(end) = rest.find("__") {
                return rest[..end].trim().to_string();
            }
            return rest.trim().to_string();
        }
        String::new()
    };

    let version_text = section("V");
    let version = version_parts(
        version_text
            .lines()
            .map(|line| line.trim())
            .find(|line| {
                line.chars()
                    .next()
                    .map(|c| c.is_ascii_digit())
                    .unwrap_or(false)
            })
            .unwrap_or("0.0.0"),
    );
    log(&format!(
        "uitest 版本 {}",
        version_text.lines().next().unwrap_or("?")
    ));

    let emulator_text = section("E");
    let is_emulator = emulator_text.contains("libCPHMediaEngine")
        && !emulator_text.to_lowercase().contains("no such file");

    let server_name = if is_emulator {
        "libscrcpy_server_emulator.z.so"
    } else if at_least(&version, &[6, 0, 2, 1]) {
        let preferred = "libscrcpy_server_unix_6.5-device.z.so";
        if resources.join("devices").join(preferred).exists() {
            preferred
        } else {
            "libscrcpy_server_unix_6.4-20260113.z.so"
        }
    } else if at_least(&version, &[5, 1, 1, 2]) {
        "libscrcpy_server_5.10-20260114.z.so"
    } else {
        "libscrcpy_server3.z.so"
    };
    let agent_name = if at_least(&version, &[6, 0, 2, 1]) {
        "uitest_agent_1.2.2.so"
    } else {
        "uitest_agent_1.1.10.so"
    };

    let server = resources.join("devices").join(server_name);
    let agent = resources.join("agents").join(agent_name);
    if !server.exists() {
        return Err(format!("缺少设备端组件：{server_name}"));
    }
    if !agent.exists() {
        return Err(format!("缺少注入端组件：{agent_name}"));
    }

    let mut rollback = BootstrapRollback {
        hdc,
        serial,
        ports: Vec::new(),
        armed: true,
    }; // 从首次设备修改开始拥有回滚责任。
    let _ = hdc.shell(serial, "pkill -9 -f singleness");
    hdc.wait(Duration::from_millis(500))?;

    let remote_server = "/data/local/tmp/libscreen_casting.z.so";
    log(&format!("推送 {server_name} → {remote_server}"));
    hdc.push_capture_asset(serial, &server, remote_server)?;
    log(&format!("推送 {agent_name} → /data/local/tmp/agent.so"));
    hdc.push_capture_asset(serial, &agent, "/data/local/tmp/agent.so")?;

    log("启动采集守护进程…");
    let scale_divisor = if scale == 0.5 { 2 } else { 1 }; // 与采集组件接受的整数缩放除数对应。
    let params = format!(
        "-scale {scale_divisor} -frameRate {frame_rate} -bitRate {} -p 5000 -iFrameInterval 2000",
        bitrate_mbps << 20
    );
    let start = format!(
        "/system/bin/uitest start-daemon singleness --extension-name libscreen_casting.z.so {params} &"
    );
    hdc.shell(serial, &start)?;
    let mut video = wait_for_endpoint(
        hdc,
        serial,
        "scrcpy_grpc_socket",
        5000,
        Duration::from_millis(1500),
    )?;
    if video.is_none() {
        let daemons = hdc.run(
            &[
                "-t",
                serial,
                "shell",
                "ps -ef | grep singleness | grep -v grep",
            ],
            Duration::from_secs(2),
        );
        if daemons.is_ok_and(|output| !output.lines().any(|line| line.contains("uitest"))) {
            log("采集守护进程未就绪，重试一次");
            hdc.shell(serial, &start)?;
            video = wait_for_endpoint(
                hdc,
                serial,
                "scrcpy_grpc_socket",
                5000,
                Duration::from_millis(1500),
            )?;
        }
    }
    let video_port = forward_available(hdc, serial, "scrcpy_grpc_socket", 5000, video)?;
    rollback.ports.push(video_port); // 第二条通道失败时也清理已建立的转发。
    log("启动注入守护进程…");
    hdc.shell(serial, "/system/bin/uitest start-daemon singleness &")?;
    let control = wait_for_endpoint(
        hdc,
        serial,
        "uitest_socket",
        8012,
        Duration::from_millis(800),
    )?;
    let control_port = forward_available(hdc, serial, "uitest_socket", 8012, control)?;

    rollback.ports.push(control_port); // 控制转发成功后也纳入回滚。
    let size_text = section("S");
    let (width, height) = parse_size(&size_text).unwrap_or((1080, 2340));
    log(&format!("设备分辨率 {width}×{height}"));

    rollback.armed = false; // 成功返回后，清理责任移交给 Session。
    Ok(StartedSession {
        serial: serial.to_string(),
        video_port,
        control_port,
        width,
        height,
    })
}

fn wait_for_endpoint(
    hdc: &Hdc<'_>,
    serial: &str,
    name: &str,
    port: u16,
    timeout: Duration,
) -> Result<Option<String>, String> {
    let deadline = Instant::now() + timeout;
    let hex = format!(":{port:04X}");
    let script = format!("if [ -r /proc/net/unix ]; then echo __UNIX__; grep -F ' @{name}' /proc/net/unix; fi; if [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then echo __TCP__; grep -ih '{hex} ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; fi; :");
    while Instant::now() < deadline {
        let output = hdc.run(
            &["-t", serial, "shell", &script],
            deadline.saturating_duration_since(Instant::now()),
        );
        hdc.check_cancelled()?;
        let Ok(output) = output else { break };
        if !output.contains("__UNIX__") && !output.contains("__TCP__") {
            break; // 旧设备不开放监听表，继续使用兼容等待。
        }
        for line in output.lines() {
            let fields: Vec<_> = line.split_whitespace().collect();
            if fields.len() == 8
                && fields[7].strip_prefix('@') == Some(name)
                && fields[4] == "0001"
                && u32::from_str_radix(fields[3], 16).is_ok_and(|flags| flags & 0x10000 != 0)
            {
                return Ok(Some(format!("localabstract:{name}")));
            }
            if fields.len() >= 10
                && fields[1].to_ascii_uppercase().ends_with(&hex)
                && fields[3] == "0A"
            {
                return Ok(Some(format!("tcp:{port}")));
            }
        }
        hdc.wait(
            deadline
                .saturating_duration_since(Instant::now())
                .min(Duration::from_millis(75)),
        )?;
    }
    hdc.wait(deadline.saturating_duration_since(Instant::now()))?;
    Ok(None)
}

fn forward_available(
    hdc: &Hdc<'_>,
    serial: &str,
    name: &str,
    port: u16,
    detected: Option<String>,
) -> Result<u16, String> {
    // free_port 与 hdc 绑定之间存在时间窗。不同设备使用同一把锁，避免两个启动同时选择同一个端口。
    static FORWARD_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = FORWARD_LOCK.lock().map_err(|e| e.to_string())?;
    let local = free_port()?;
    let abstract_socket = format!("localabstract:{name}");
    let tcp = format!("tcp:{port}");
    let preferred = detected.as_deref().unwrap_or(&abstract_socket);
    let fallback = if preferred == abstract_socket {
        &tcp
    } else {
        &abstract_socket
    };
    // hdc 可能在已创建转发后才收到取消。让当前命令结束，再由会话回滚已登记的端口。
    hdc.check_cancelled()?;
    let cleanup_hdc = Hdc::new(hdc.binary.clone());
    cleanup_hdc
        .forward(serial, local, preferred)
        .or_else(|_| cleanup_hdc.forward(serial, local, fallback))?;
    Ok(local)
}

fn parse_size(text: &str) -> Option<(u32, u32)> {
    // activeMode: 1216x2688, refreshRate=60
    let bytes = text.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index].is_ascii_digit() {
            let start = index;
            while index < bytes.len() && bytes[index].is_ascii_digit() {
                index += 1;
            }
            if index < bytes.len() && (bytes[index] == b'x' || bytes[index] == b'X') {
                let width: u32 = text[start..index].parse().ok()?;
                let height_start = index + 1;
                let mut height_end = height_start;
                while height_end < bytes.len() && bytes[height_end].is_ascii_digit() {
                    height_end += 1;
                }
                let height: u32 = text[height_start..height_end].parse().ok()?;
                if width >= 100 && height >= 100 {
                    return Some((width, height));
                }
            }
        } else {
            index += 1;
        }
    }
    None
}

/// 在 bootstrap 任意中间步骤返回错误时自动撤销已建立的设备资源。
struct BootstrapRollback<'a> {
    hdc: &'a Hdc<'a>, // 复用本次启动的命令执行器。
    serial: &'a str,  // 回滚严格限定到当前设备。
    ports: Vec<u16>,  // 只删除本次已成功创建的转发。
    armed: bool,      // 成功移交所有权后禁止再次清理。
}

impl Drop for BootstrapRollback<'_> {
    fn drop(&mut self) {
        if self.armed {
            let cleanup = Hdc::new(self.hdc.binary.clone()); // 回滚必须在取消后也能执行。
                                                             // 仅错误路径执行回滚。
            for port in &self.ports {
                cleanup.remove_forward(self.serial, *port);
            } // 先释放主机转发。
            let _ = cleanup.shell(self.serial, "pkill -9 -f singleness"); // 再停止部分启动的设备进程。
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn drains_both_pipes_before_waiting() {
        let hdc = Hdc::new("/bin/sh"); // 用本地命令模拟有大量输出的 hdc。
        let script = "head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2"; // 两条管道各输出 1 MiB。
        let text = hdc.run(&["-c", script], Duration::from_secs(5)).unwrap(); // 旧实现会卡在进程等待阶段。
        assert_eq!(text.len(), 2 * 1048576); // 验证两条管道均被完整收集。
    }

    #[test]
    fn times_out_and_reaps_child() {
        let hdc = Hdc::new("/bin/sh"); // 不接触真实设备。
        let started = Instant::now(); // 同时验证超时能及时返回。
        let result = hdc.run(&["-c", "exec sleep 5"], Duration::from_millis(100)); // exec 避免留下测试子孙进程。
        assert!(result.unwrap_err().contains("超时")); // 返回明确的超时错误。
        assert!(started.elapsed() < Duration::from_secs(2)); // 不等待原始五秒命令结束。
    }
}
