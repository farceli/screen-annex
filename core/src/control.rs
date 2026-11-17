//! uitest control channel: one JSON-RPC request per call.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::time::Duration;

pub struct Control {
    stream: BufReader<TcpStream>,
    keyboard_driver: Option<String>,
    keyboard_probed: bool,
}

impl Control {
    pub fn connect(port: u16) -> Result<Self, String> {
        let stream = TcpStream::connect(("127.0.0.1", port)).map_err(|e| e.to_string())?;
        stream.set_nodelay(true).ok();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .map_err(|e| e.to_string())?;
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .map_err(|e| e.to_string())?;
        Ok(Self {
            stream: BufReader::new(stream),
            keyboard_driver: None,
            keyboard_probed: false,
        })
    }

    fn exchange(&mut self, method: &str, params: &Value) -> Result<Value, String> {
        let mut message = serde_json::to_vec(&json!({
            "module": "com.ohos.devicetest.hypiumApiHelper", "method": method, "params": params,
        }))
        .map_err(|error| error.to_string())?;
        message.push(b'\n');
        self.stream
            .get_mut()
            .write_all(&message)
            .map_err(|e| e.to_string())?;
        let mut buffer = Vec::new();
        (&mut self.stream)
            .take(256 * 1024)
            .read_until(b'\n', &mut buffer)
            .map_err(|e| e.to_string())?;
        if buffer.last() != Some(&b'\n') {
            return Err("手机控制响应不完整".into());
        }
        serde_json::from_slice(&buffer).map_err(|e| e.to_string())
    }

    fn request(&mut self, api: &str, args: Value) -> Result<Value, String> {
        self.exchange("Gestures", &json!({ "api": api, "args": args }))
    }

    fn keyboard(&mut self) -> Option<String> {
        if !self.keyboard_probed {
            self.keyboard_probed = true;
            let response = self.exchange(
                "callHypiumApi",
                &json!({ "api": "Driver.create", "this": "", "args": [] }),
            );
            self.keyboard_driver = response
                .ok()
                .and_then(|value| value["result"].as_str().map(str::to_owned));
        }
        self.keyboard_driver.clone()
    }

    // 返回 false 仅表示旧设备明确缺少该能力，可以安全回退。
    pub fn stroke(&mut self, code: u32, shift: bool) -> Result<bool, String> {
        let Some(driver) = self.keyboard() else {
            return Ok(false);
        };
        let api = if shift {
            "Driver.triggerCombineKeys"
        } else {
            "Driver.triggerKey"
        };
        let args = if shift {
            json!([2047, code])
        } else {
            json!([code])
        };
        self.driver_action(&driver, api, args)
    }

    pub fn back(&mut self) -> Result<bool, String> {
        let Some(driver) = self.keyboard() else {
            return Ok(false);
        };
        self.driver_action(&driver, "Driver.pressBack", json!([]))
    }

    fn driver_action(&mut self, driver: &str, api: &str, args: Value) -> Result<bool, String> {
        let response = self.exchange(
            "callHypiumApi",
            &json!({ "api": api, "this": driver, "args": args }),
        );
        if let Ok(value) = &response {
            if value["exception"].is_null() && value.get("result").is_some() {
                return Ok(true);
            }
            if value["exception"]["message"]
                .as_str()
                .is_some_and(|message| message.starts_with("No handler found for api"))
            {
                return Ok(false);
            }
        }
        // 超时可能已执行按键。丢弃当前驱动，避免重发同一次输入。
        self.keyboard_driver = None;
        Err("设备未确认按键操作".into())
    }

    pub fn touch(&mut self, phase: i32, x: i32, y: i32) -> Result<Value, String> {
        let api = match phase {
            0 => "touchDown",
            1 => "touchMove",
            _ => "touchUp",
        };
        self.request(api, json!({ "x": x, "y": y }))
    }

    /// 滚动只使用鼠标轴事件；不允许退回可能产生点击的触摸序列。
    pub fn scroll(&mut self, x: i32, y: i32, steps: i32) -> Result<(), String> {
        let args = json!({ "x": x, "y": y }); // 与设备端轴事件使用相同位置参数。
        let requests = scroll_requests(steps); // 生成有界、以 AxisStop 结束的事件序列。
        if requests.is_empty() {
            return Ok(());
        } // 零增量不访问设备。
        let result = (|| {
            for api in &requests[..requests.len() - 1] {
                self.request(api, args.clone())?;
            } // 轴请求失败后停止步进。
            Ok(())
        })();
        let stopped = self.request("AxisStop", args).map(|_| ()); // 无论前面是否失败都尝试结束滚轮序列。
        result.and(stopped) // 返回失败，不合成触摸点击作为后备。
    }

    pub fn rotate(&mut self, horizontal: bool) -> Result<Value, String> {
        let value = if horizontal { 1 } else { 0 };
        self.request("Driver.setDisplayRotation", json!([value]))
    }
}

/// 同一协议计划供发送和测试共用，所有分支都不得包含按钮或触摸事件。
fn scroll_requests(steps: i32) -> Vec<&'static str> {
    let steps = steps.clamp(-3, 3); // 限制一次批次，避免阻塞其他输入。
    if steps == 0 {
        return Vec::new();
    } // 零滚动不能变成点按或鼠标动作。
    let api = if steps > 0 { "AxisDown" } else { "AxisUp" }; // 与 Swift 端保持方向一致。
    let mut requests = vec![api; steps.unsigned_abs() as usize];
    requests.push("AxisStop"); // 独立结束滚轮轴，不使用鼠标按钮抬起。
    requests
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scroll_never_generates_touch_or_mouse_button_events() {
        for steps in [-100, -1, 0, 1, 100] {
            // 覆盖正反方向、空操作和异常大增量。
            let requests = scroll_requests(steps);
            assert!(requests
                .iter()
                .all(|api| matches!(*api, "AxisUp" | "AxisDown" | "AxisStop"))); // 任何点击原语都不允许出现。
            assert!(requests.len() <= 4); // 至多三步加一个停止事件。
            if steps == 0 {
                assert!(requests.is_empty());
            }
            // 零移动不产生任何交互。
            else {
                assert_eq!(requests.last(), Some(&"AxisStop"));
            } // 正反方向都必须结束轴序列。
        }
        assert_eq!(scroll_requests(1), ["AxisDown", "AxisStop"]); // 固定现有正向约定。
        assert_eq!(scroll_requests(-1), ["AxisUp", "AxisStop"]); // 负向独立验证。
    }
}
