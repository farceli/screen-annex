//! Portable HarmonyOS mirror/control kernel.
//!
//! Transport only: hdc + gRPC-over-h2c + protobuf + uitest JSON. Video decoding
//! stays platform-specific (VideoToolbox on macOS, Media Foundation on Windows).

mod control;
mod device_commands;
mod h2;
mod hdc;
mod proto;

use control::Control;
use hdc::Hdc;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream}; // 保存读 socket 的副本，停止时主动唤醒读取线程。
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

pub use hdc::StartedSession;

pub struct Session {
    pub serial: String,
    resources: PathBuf,
    hdc_binary: PathBuf,
    started: Option<StartedSession>,
    control: Arc<Mutex<Option<Control>>>,
    stop: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>, // 独立于 stop，允许启动期间发出取消请求。
    video_ended: Arc<AtomicBool>,
    reader: Option<JoinHandle<()>>,
    writer: Option<Arc<Mutex<TcpStream>>>, // 所有 HTTP/2 写入必须保持完整帧边界。
    next_stream: AtomicU32,
    video: Option<TcpStream>, // 仅用于 shutdown，不在这个副本上读取视频。
}

impl Session {
    pub fn new(
        serial: impl Into<String>,
        resources: impl Into<PathBuf>,
        hdc_binary: impl Into<PathBuf>,
    ) -> Self {
        Self {
            serial: serial.into(),
            resources: resources.into(),
            hdc_binary: hdc_binary.into(),
            started: None,
            control: Arc::new(Mutex::new(None)),
            stop: Arc::new(AtomicBool::new(false)),
            cancelled: Arc::new(AtomicBool::new(false)),
            video_ended: Arc::new(AtomicBool::new(false)),
            reader: None,
            writer: None,
            next_stream: AtomicU32::new(3),
            video: None,
        }
    }

    pub fn start<L, F>(
        &mut self,
        fps: u32,
        bitrate_mbps: u32,
        scale: f64,
        mut log: L,
        on_frame: F,
    ) -> Result<(u32, u32), String>
    where
        L: FnMut(&str),
        F: FnMut(&[u8]) + Send + 'static,
    {
        self.stop(); // 重复 start 必须先完整释放上次会话。
        self.stop.store(false, Ordering::Relaxed);
        self.video_ended.store(false, Ordering::Relaxed);
        let cancelled = self.cancelled.clone(); // 独立克隆后可在失败路径可变借用会话。
        let hdc = Hdc::new(self.hdc_binary.clone()).with_cancellation(&cancelled);
        let started = hdc::bootstrap(
            &hdc,
            &self.resources,
            &self.serial,
            fps,
            bitrate_mbps,
            scale,
            &mut log,
        )?;

        let size = (started.width, started.height); // 提前保存返回值，避免移交所有权后借用。
        let video_port = started.video_port;
        let control_port = started.control_port;
        self.started = Some(started); // 后续连接失败时 stop() 也拥有完整清理信息。
        let channels = (|| {
            // 集中处理两条通道的部分初始化失败。
            let control = Control::connect(control_port)?;
            let stream = h2::open(video_port, "/ScrcpyService/onStart")
                .map_err(|error| format!("gRPC 连接失败: {error}"))?;
            let shutdown = stream.try_clone().map_err(|error| error.to_string())?; // 允许 stop 唤醒 recv。
            let writer = stream.try_clone().map_err(|error| error.to_string())?;
            Ok::<_, String>((control, stream, shutdown, writer))
        })();
        let (control, stream, shutdown, writer) = match channels {
            Ok(channels) => channels,
            Err(error) => {
                self.stop();
                return Err(error);
            } // 释放转发和已启动的设备进程。
        };
        *self.control.lock().unwrap() = Some(control);
        self.video = Some(shutdown); // 读取线程启动前接管主动关闭句柄。
        let writer = Arc::new(Mutex::new(writer));
        self.writer = Some(writer.clone());
        self.next_stream.store(3, Ordering::Relaxed);
        let mut stream = VideoChannel {
            reader: stream,
            writer,
        };
        let stop = self.stop.clone();
        let video_ended = self.video_ended.clone();
        let reader = thread::spawn(move || {
            let mut grpc: Vec<u8> = Vec::new();
            let mut on_frame = on_frame;
            let _ = h2::read_loop(&mut stream, &stop, |payload| {
                grpc.extend_from_slice(payload);
                loop {
                    if grpc.len() < 5 {
                        break;
                    }
                    let length = u32::from_be_bytes([grpc[1], grpc[2], grpc[3], grpc[4]]) as usize;
                    if grpc.len() < 5 + length {
                        break;
                    }
                    let message: Vec<u8> = grpc[5..5 + length].to_vec();
                    grpc.drain(..5 + length);
                    if let Some(data) = proto::reply_data(&message) {
                        on_frame(&data);
                    }
                }
            });
            video_ended.store(true, Ordering::Release); // 空闲超时仍在读取，只有视频通道实际退出才标记断线。
        });

        self.reader = Some(reader);
        Ok(size)
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(video) = self.video.take() {
            let _ = video.shutdown(Shutdown::Both);
        } // 先解除阻塞再 join。
        self.writer = None;
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
        if let Some(started) = self.started.take() {
            let hdc = Hdc::new(self.hdc_binary.clone());
            hdc.remove_forward(&started.serial, started.video_port);
            hdc.remove_forward(&started.serial, started.control_port);
            let _ = hdc.shell(&started.serial, "pkill -9 -f singleness");
        }
        *self.control.lock().unwrap() = None;
    }

    fn request_key_frame(&self) {
        if let (Some(writer), Some(started)) = (&self.writer, &self.started) {
            if let Ok(mut writer) = writer.lock() {
                let id = self.next_stream.fetch_add(2, Ordering::Relaxed);
                let _ = h2::send_request(
                    &mut *writer,
                    started.video_port,
                    "/ScrcpyService/onRequestIDRFrame",
                    id,
                );
            }
        }
    }

    pub fn size(&self) -> (u32, u32) {
        self.started
            .as_ref()
            .map(|s| (s.width, s.height))
            .unwrap_or((0, 0))
    }

    pub fn touch(&self, phase: i32, x: i32, y: i32) {
        if let Ok(mut guard) = self.control.lock() {
            if let Some(control) = guard.as_mut() {
                let _ = control.touch(phase, x, y);
            }
        }
    }

    pub fn scroll(&self, x: i32, y: i32, steps: i32) {
        if let Ok(mut guard) = self.control.lock() {
            // 与点击、旋转共用控制通道串行锁。
            if let Some(control) = guard.as_mut() {
                let _ = control.scroll(x, y, steps);
            } // 不合成触摸按下和抬起。
        }
    }

    pub fn rotate(&self, horizontal: bool) {
        if let Ok(mut guard) = self.control.lock() {
            if let Some(control) = guard.as_mut() {
                let _ = control.rotate(horizontal);
            }
        }
    }

    pub fn key(&self, code: u32) {
        if (2000..=2071).contains(&code) {
            if let Some(control) = self.control.lock().unwrap().as_mut() {
                if control.stroke(code, false) != Ok(false) {
                    return;
                }
            }
        }
        let hdc = Hdc::new(self.hdc_binary.clone());
        let _ = hdc.shell(&self.serial, &format!("uinput -K -d {code} -u {code}"));
    }

    fn focused_text(&self, text: &str) -> Result<(), String> {
        if let Some(strokes) = device_commands::ascii_strokes(text) {
            if let Some(control) = self.control.lock().unwrap().as_mut() {
                for (index, (key, shift)) in strokes.into_iter().enumerate() {
                    if control.stroke(key, shift)? {
                        continue;
                    }
                    if index > 0 {
                        return Err("部分文字已发送，无法继续按键输入".into());
                    }
                    return device_commands::focused_text(
                        &Hdc::new(&self.hdc_binary),
                        &self.serial,
                        text,
                    );
                }
                return Ok(());
            }
        }
        device_commands::focused_text(&Hdc::new(&self.hdc_binary), &self.serial, text)
    }

    pub fn text(&self, x: i32, y: i32, text: &str) {
        let escaped = text.replace('\'', "'\\''");
        let hdc = Hdc::new(self.hdc_binary.clone());
        let _ = hdc.shell(
            &self.serial,
            &format!("uitest uiInput inputText {x} {y} '{escaped}'"),
        );
    }

    pub fn screenshot(&self, destination: &Path) -> Result<(), String> {
        let hdc = Hdc::new(self.hdc_binary.clone());
        let remote = "/data/local/tmp/hosmirror_shot.jpeg";
        hdc.shell(&self.serial, &format!("snapshot_display -f {remote}"))?;
        hdc.run(
            &[
                "-t",
                &self.serial,
                "file",
                "recv",
                remote,
                &destination.to_string_lossy(),
            ],
            std::time::Duration::from_secs(30),
        )
        .map(|_| ())
    }
}

struct VideoChannel {
    reader: TcpStream,
    writer: Arc<Mutex<TcpStream>>,
}

impl Read for VideoChannel {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.reader.read(bytes)
    }
}

impl Write for VideoChannel {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.writer.lock().unwrap().write_all(bytes)?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stop();
    }
}

// MARK: - C ABI

pub type FrameCallback = extern "C" fn(user: *mut c_void, data: *const u8, len: usize);
pub type LogCallback = extern "C" fn(user: *mut c_void, message: *const c_char);

struct Sink {
    frame: Option<FrameCallback>,
    log: Option<LogCallback>,
    user: usize,
}

unsafe impl Send for Sink {}

#[repr(C)]
pub struct HmSession {
    cancellation: Arc<AtomicBool>, // 原生句柄启动期间仅访问这个独立字段。
    inner: Session,
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_session_new(
    serial: *const c_char,
    resources: *const c_char,
    hdc: *const c_char,
) -> *mut HmSession {
    if serial.is_null() || resources.is_null() || hdc.is_null() {
        return std::ptr::null_mut();
    }
    let serial = unsafe { CStr::from_ptr(serial) }
        .to_string_lossy()
        .to_string();
    let resources = unsafe { CStr::from_ptr(resources) }
        .to_string_lossy()
        .to_string();
    let hdc = unsafe { CStr::from_ptr(hdc) }.to_string_lossy().to_string();
    let inner = Session::new(serial, resources, hdc);
    Box::into_raw(Box::new(HmSession {
        cancellation: inner.cancelled.clone(),
        inner,
    }))
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_session_start(
    session: *mut HmSession,
    fps: u32,
    bitrate_mbps: u32,
    scale: f64,
    frame: Option<FrameCallback>,
    log: Option<LogCallback>,
    user: *mut c_void,
) -> c_int {
    if session.is_null() {
        return -1;
    }
    let session = &mut (*session).inner; // 取消入口只读取独立的 cancellation 字段。
    let sink = Sink {
        frame,
        log,
        user: user as usize,
    };

    let log_sink = Sink {
        frame: None,
        log,
        user: user as usize,
    };
    let mut logger = move |message: &str| {
        if let (Some(callback), user) = (log_sink.log, log_sink.user) {
            if let Ok(text) = CString::new(message) {
                callback(user as *mut c_void, text.as_ptr());
            }
        }
    };

    match session.start(fps, bitrate_mbps, scale, &mut logger, move |data| {
        if let Some(callback) = sink.frame {
            callback(sink.user as *mut c_void, data.as_ptr(), data.len());
        }
    }) {
        Ok(_) => 0,
        Err(error) => {
            logger(&error);
            -1
        }
    }
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_session_stop(session: *mut HmSession) {
    if !session.is_null() {
        (*session).inner.stop();
    }
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_session_free(session: *mut HmSession) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_touch(session: *mut HmSession, phase: c_int, x: c_int, y: c_int) {
    if !session.is_null() {
        (*session).inner.touch(phase, x, y);
    }
}

/// # Safety
/// session 必须是有效且尚未释放的句柄；调用期间不得并发修改或释放该会话。
#[no_mangle]
pub unsafe extern "C" fn hm_scroll(session: *mut HmSession, x: c_int, y: c_int, steps: c_int) {
    if !session.is_null() {
        (*session).inner.scroll(x, y, steps);
    } // 独立导出原生滚轮入口，不能复用 hm_touch。
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_key(session: *mut HmSession, code: u32) {
    if !session.is_null() {
        (*session).inner.key(code);
    }
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_rotate(session: *mut HmSession, horizontal: c_int) {
    if !session.is_null() {
        (*session).inner.rotate(horizontal != 0);
    }
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_text(session: *mut HmSession, x: c_int, y: c_int, text: *const c_char) {
    if session.is_null() || text.is_null() {
        return;
    }
    let value = CStr::from_ptr(text).to_string_lossy().to_string();
    (*session).inner.text(x, y, &value);
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_screenshot(
    session: *mut HmSession,
    destination: *const c_char,
) -> c_int {
    if session.is_null() || destination.is_null() {
        return -1;
    }
    let path = PathBuf::from(CStr::from_ptr(destination).to_string_lossy().to_string());
    match (*session).inner.screenshot(&path) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// # Safety
/// 非空字符串指针必须指向有效的、以 NUL 结尾的 UTF-8 缓冲区；其他非空指针必须有效且对齐。
/// 会话句柄由 hm_session_new 创建；调用期间不得被并发修改或释放，free 只能调用一次。
/// 帧与日志回调及 user 必须保持有效直到 stop/free 返回；回调不得重入修改同一会话。
#[no_mangle]
pub unsafe extern "C" fn hm_size(session: *mut HmSession, width: *mut c_int, height: *mut c_int) {
    if session.is_null() || width.is_null() || height.is_null() {
        return;
    }
    let size = (*session).inner.size();
    *width = size.0 as c_int;
    *height = size.1 as c_int;
}

/// # Safety
/// 句柄必须仍由调用者持有；允许与 hm_session_start 并发，调用结束前不得释放。
#[no_mangle]
pub unsafe extern "C" fn hm_session_cancel_start(session: *mut HmSession) {
    if !session.is_null() {
        (*session).cancellation.store(true, Ordering::Relaxed);
    }
}

/// # Safety
/// 句柄必须有效，调用期间不得释放或修改会话。
#[no_mangle]
pub unsafe extern "C" fn hm_video_ended(session: *const HmSession) -> c_int {
    if session.is_null() {
        return 1;
    }
    (*session).inner.video_ended.load(Ordering::Acquire) as c_int
}

/// # Safety
/// 句柄必须有效，调用期间不得释放或修改会话。
#[no_mangle]
pub unsafe extern "C" fn hm_back_or_wake(session: *mut HmSession) -> c_int {
    if session.is_null() {
        return -1;
    }
    let inner = &(*session).inner;
    device_commands::back_or_wake(&Hdc::new(&inner.hdc_binary), &inner.serial, || {
        if let Some(control) = inner.control.lock().unwrap().as_mut() {
            return control.back();
        }
        Ok(false)
    })
    .map_or(-1, |_| 0)
}

/// # Safety
/// 句柄和以 NUL 结尾的 UTF-8 字符串必须有效，调用期间不得释放或修改。
#[no_mangle]
pub unsafe extern "C" fn hm_focused_text(session: *mut HmSession, text: *const c_char) -> c_int {
    if session.is_null() || text.is_null() {
        return -1;
    }
    let Ok(text) = CStr::from_ptr(text).to_str() else {
        return -1;
    };
    let inner = &(*session).inner;
    inner.focused_text(text).map_or(-1, |_| 0)
}

/// # Safety
/// 句柄必须有效，调用期间不得释放或修改会话。
#[no_mangle]
pub unsafe extern "C" fn hm_request_key_frame(session: *mut HmSession) {
    if !session.is_null() {
        (*session).inner.request_key_frame();
    }
}
