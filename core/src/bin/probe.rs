use hosmirror_core::Session;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(serial) = args.get(1).filter(|serial| !serial.is_empty()) else {
        // 探针会发送测试滑动，设备必须由调用者明确指定。
        eprintln!("Usage: hm-probe <device-serial> [seconds] [output-directory]");
        std::process::exit(2);
    };
    let seconds: u64 = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(8);
    let output = PathBuf::from(
        args.get(3)
            .cloned()
            .unwrap_or_else(|| "/tmp/hosmirror-rs".into()),
    );

    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    // 可使用独立的本机 SDK 资源目录，也兼容开发环境原有的 Resources 布局。
    let resources = std::env::var_os("HOSMIRROR_HARMONY_RESOURCES")
        .or_else(|| std::env::var_os("HOSMIRROR_RESOURCES"))
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("Resources"));
    let hdc = resources.join(if cfg!(windows) {
        "tools/hdc.exe"
    } else {
        "tools/hdc"
    });

    let mut session = Session::new(serial.clone(), resources, hdc.clone());
    let frames: Arc<Mutex<Vec<Vec<u8>>>> = Arc::new(Mutex::new(Vec::new()));
    let sink = frames.clone();

    let size = session
        .start(
            30,
            8,
            1.0,
            |message| println!("· {message}"),
            move |data| {
                sink.lock().unwrap().push(data.to_vec());
            },
        )
        .expect("start failed");
    println!("· 分辨率 {}×{}", size.0, size.1);

    let deadline = std::time::Instant::now() + Duration::from_secs(seconds);
    while std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_secs(1));
        let _ = Command::new(&hdc)
            .args(["-t", serial, "shell", "uinput -T -m 600 1800 600 1100 120"])
            .output();
    }
    session.stop();

    let captured = frames.lock().unwrap();
    let count = captured.len();
    let total: usize = captured.iter().map(|f| f.len()).sum();
    println!("· 收到 {count} 帧 / {total} 字节");
    if count == 0 {
        std::process::exit(1);
    }

    std::fs::create_dir_all(&output).unwrap();
    let file = output.join("probe-rs.h264");
    let mut merged = Vec::with_capacity(total);
    for frame in captured.iter() {
        merged.extend_from_slice(frame);
    }
    std::fs::write(&file, &merged).unwrap();
    println!("· 已写入 {}", file.display());
}
