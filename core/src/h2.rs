//! Minimal HTTP/2 (h2c) client for the video stream and independent IDR requests.

use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

fn frame(ftype: u8, flags: u8, stream: u32, payload: &[u8]) -> Vec<u8> {
    let len = payload.len();
    let mut out = Vec::with_capacity(9 + len);
    out.push((len >> 16) as u8);
    out.push((len >> 8) as u8);
    out.push(len as u8);
    out.push(ftype);
    out.push(flags);
    out.extend_from_slice(&(stream & 0x7fff_ffff).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn push_header(out: &mut Vec<u8>, name: &str, value: &str) {
    out.push(0x00); // literal without indexing, new name
    out.push(name.len() as u8);
    out.extend_from_slice(name.as_bytes());
    out.push(value.len() as u8);
    out.extend_from_slice(value.as_bytes());
}

pub fn open(port: u16, path: &str) -> io::Result<TcpStream> {
    let mut stream = TcpStream::connect(("127.0.0.1", port))?;
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(Duration::from_millis(1500)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;

    stream.write_all(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")?;

    let mut settings = Vec::new();
    settings.extend_from_slice(&4u16.to_be_bytes()); // INITIAL_WINDOW_SIZE
    settings.extend_from_slice(&(16u32 * 1024 * 1024).to_be_bytes());
    stream.write_all(&frame(0x4, 0, 0, &settings))?;
    stream.write_all(&frame(0x8, 0, 0, &(16u32 * 1024 * 1024).to_be_bytes()))?;

    send_request(&mut stream, port, path, 1)?;
    Ok(stream)
}

pub fn send_request(stream: &mut impl Write, port: u16, path: &str, id: u32) -> io::Result<()> {
    let mut headers = Vec::new();
    push_header(&mut headers, ":method", "POST");
    push_header(&mut headers, ":scheme", "http");
    push_header(&mut headers, ":path", path);
    push_header(&mut headers, ":authority", &format!("127.0.0.1:{port}"));
    push_header(&mut headers, "content-type", "application/grpc");
    push_header(&mut headers, "te", "trailers");
    push_header(&mut headers, "user-agent", "hosmirror-core/0.1");

    let mut request = frame(0x1, 0x4, id, &headers);
    request.extend(frame(0x0, 0x1, id, &[0, 0, 0, 0, 0]));
    stream.write_all(&request)
}

/// Reads DATA payloads until the stream ends or `stop` is set.
pub fn read_loop<S: Read + Write, F>(
    stream: &mut S,
    stop: &AtomicBool,
    mut on_data: F,
) -> io::Result<()>
where
    F: FnMut(&[u8]),
{
    let mut header = [0u8; 9];
    loop {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        if !read_full(stream, &mut header, stop)? {
            return Ok(());
        } // 超时后从已有偏移继续读取同一个帧头。

        let len = ((header[0] as usize) << 16) | ((header[1] as usize) << 8) | header[2] as usize;
        let ftype = header[3];
        let flags = header[4];
        let stream_id = u32::from_be_bytes([header[5] & 0x7f, header[6], header[7], header[8]]);

        let mut payload = vec![0u8; len];
        if len > 0 && !read_full(stream, &mut payload, stop)? {
            return Ok(()); // 帧体同样保留分片读取进度。
        }

        match ftype {
            0x4 if flags & 0x1 == 0 => stream.write_all(&frame(0x4, 0x1, 0, &[]))?,
            0x6 if flags & 0x1 == 0 => stream.write_all(&frame(0x6, 0x1, 0, &payload))?,
            0x0 => {
                if !payload.is_empty() {
                    if stream_id == 1 {
                        on_data(&payload); // IDR 请求的应答不能混入视频 gRPC 缓冲区。
                    }
                    let increment = (payload.len() as u32).to_be_bytes();
                    stream.write_all(&frame(0x8, 0, 0, &increment))?;
                    stream.write_all(&frame(0x8, 0, stream_id, &increment))?;
                }
                if stream_id == 1 && flags & 0x1 != 0 {
                    return Ok(());
                }
            }
            0x1 if stream_id == 1 && flags & 0x1 != 0 => return Ok(()),
            0x7 => return Ok(()),
            0x3 if stream_id == 1 => {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionReset,
                    "video stream reset",
                ))
            } // 不忽略服务端重置。
            _ => {}
        }
    }
}

/// read_exact 超时不会报告已消耗多少字节，因此显式维护偏移直到完整或取消。
fn read_full<R: Read>(reader: &mut R, bytes: &mut [u8], stop: &AtomicBool) -> io::Result<bool> {
    let mut offset = 0; // 每个帧头或帧体独立记录进度。
    while offset < bytes.len() {
        if stop.load(Ordering::Relaxed) {
            return Ok(false);
        } // 断开时不再等待剩余分片。
        match reader.read(&mut bytes[offset..]) {
            // 只读取尚未填充的部分。
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "incomplete HTTP/2 frame",
                ))
            } // 不把截断当成功。
            Ok(count) => offset += count, // 成功收到的字节跨超时保留。
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                continue
            } // 可重试错误不重置偏移。
            Err(error) => return Err(error), // 真实连接错误交由上层处理。
        }
    }
    Ok(true) // 缓冲区完整填满后才能解析长度和类型。
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    struct Fragmented {
        pieces: VecDeque<io::Result<Vec<u8>>>, // 输入可以交替返回短读和超时。
        written: Vec<u8>,                      // 收集解析器的 WINDOW_UPDATE 等响应。
    }

    impl Read for Fragmented {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            match self.pieces.pop_front() {
                // 按顺序重放 TCP 分片。
                Some(Ok(bytes)) => {
                    let count = output.len().min(bytes.len()); // 遵守 Read 的缓冲区长度限制。
                    output[..count].copy_from_slice(&bytes[..count]); // 交付本次能够读取的部分。
                    if count < bytes.len() {
                        self.pieces.push_front(Ok(bytes[count..].to_vec()));
                    } // 剩余字节留给下次读取。
                    Ok(count)
                }
                Some(Err(error)) => Err(error), // 模拟真实 socket 的超时。
                None => Ok(0),                  // 输入结束。
            }
        }
    }

    impl Write for Fragmented {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.written.extend_from_slice(bytes); // 允许测试解析器正常发送确认帧。
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        } // 内存输出无需刷新。
    }

    #[test]
    fn preserves_partial_headers_and_payloads_across_timeouts() {
        let data = frame(0, 1, 1, b"abc"); // 一个同时携带 END_STREAM 的 DATA 帧。
        let mut stream = Fragmented {
            pieces: VecDeque::from([
                Ok(data[..4].to_vec()),                          // 先交付不足九字节的帧头。
                Err(io::Error::from(io::ErrorKind::TimedOut)),   // 触发旧实现的错位路径。
                Ok(data[4..10].to_vec()),                        // 补全帧头并交付部分帧体。
                Err(io::Error::from(io::ErrorKind::WouldBlock)), // 帧体也允许超时重试。
                Ok(data[10..].to_vec()),                         // 交付剩余帧体。
            ]),
            written: Vec::new(),
        };
        let mut received = Vec::new(); // 记录最终交付的原始视频字节。
        read_loop(&mut stream, &AtomicBool::new(false), |data| {
            received.extend_from_slice(data)
        })
        .unwrap();
        assert_eq!(received, b"abc"); // 同一个帧的字节既不能丢失也不能错位。
    }

    #[test]
    fn key_frame_response_does_not_terminate_or_feed_video() {
        let mut stream = Fragmented {
            pieces: VecDeque::from([
                Ok(frame(0, 1, 3, b"non-video")),
                Ok(frame(1, 1, 5, b"trailers")),
                Ok(frame(0, 1, 1, b"picture")),
            ]),
            written: Vec::new(),
        };
        let mut received = Vec::new();
        read_loop(&mut stream, &AtomicBool::new(false), |data| {
            received.extend_from_slice(data)
        })
        .unwrap();
        assert_eq!(received, b"picture"); // 视频仅来自流 1，其他 gRPC 应答不会污染其分包。
    }

    #[test]
    fn rejects_truncated_frames() {
        let mut stream = Fragmented {
            pieces: VecDeque::from([Ok(vec![0, 0, 3])]),
            written: Vec::new(),
        }; // 截断帧头。
        let result = read_loop(&mut stream, &AtomicBool::new(false), |_| {}); // 不能伪装成正常结束。
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn cancellation_does_not_wait_for_another_frame() {
        let mut stream = Fragmented {
            pieces: VecDeque::new(),
            written: Vec::new(),
        }; // 取消后禁止继续读取。
        read_loop(&mut stream, &AtomicBool::new(true), |_| {
            panic!("cancelled frame delivered")
        })
        .unwrap();
    }
}
