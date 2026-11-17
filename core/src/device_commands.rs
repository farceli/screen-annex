//! 与 Swift 端一致的鸿蒙系统输入命令。控件坐标与投屏尺寸仍由宿主计算。

use crate::hdc::Hdc;
use std::time::Duration;

fn parse_power(output: &str) -> Option<bool> {
    for line in output.lines() {
        let line = line.trim().to_ascii_uppercase();
        // 主物理屏与投屏虚拟屏的电源状态独立。
        if line.starts_with("SCREEN[")
            && line.contains(": ID=0,")
            && line.contains("ISVIRTUAL=FALSE")
        {
            for field in line.split(',').map(str::trim) {
                match field {
                    "POWERSTATUS=POWER_STATUS_ON" => return Some(true),
                    "POWERSTATUS=POWER_STATUS_OFF" | "POWERSTATUS=POWER_STATUS_SUSPEND" => {
                        return Some(false)
                    }
                    _ => {}
                }
            }
        }
        let current = line
            .strip_prefix("CURRENT STATE:")
            .or_else(|| line.strip_prefix("CURRENTSTATE:"));
        match current.and_then(|value| value.split_whitespace().next()) {
            Some("AWAKE" | "ON" | "DIM") => return Some(true),
            Some("INACTIVE" | "SLEEP" | "OFF" | "DOZE") => return Some(false),
            _ => {}
        }
    }
    None // 不根据历史记录或读不到状态推断为亮屏。
}

pub fn back_or_wake(
    hdc: &Hdc<'_>,
    serial: &str,
    back: impl FnOnce() -> Result<bool, String>,
) -> Result<(), String> {
    let probe = |command| {
        hdc.run(&["-t", serial, "shell", command], Duration::from_secs(2))
            .ok()
            .and_then(|output| parse_power(&output))
    };
    let state = probe("hidumper -s RenderService -a screen")
        .or_else(|| probe("hidumper -s PowerManagerService -a '-s'"));
    if state == Some(true) {
        if back()? {
            return Ok(());
        }
        return checked_input(hdc, serial, "uinput -K -d 2 -u 2");
    }
    checked_input(hdc, serial, "power-shell wakeup")
}

pub fn ascii_strokes(text: &str) -> Option<Vec<(u32, bool)>> {
    if text.len() > 3 {
        return None;
    }
    text.bytes()
        .map(|byte| match byte {
            b'a'..=b'z' => Some((2017 + u32::from(byte - b'a'), false)),
            b'A'..=b'Z' => Some((2017 + u32::from(byte - b'A'), true)),
            b'0'..=b'9' => Some((2000 + u32::from(byte - b'0'), false)),
            b' ' => Some((2050, false)),
            _ => None, // Unicode 和长文本使用系统的焦点文字接口。
        })
        .collect()
}

pub fn focused_text(hdc: &Hdc<'_>, serial: &str, text: &str) -> Result<(), String> {
    if text.is_empty() {
        return Ok(());
    }
    let literal = text.replace('\'', "'\\''"); // 始终将输入作为当前焦点的文字。
    checked_input(hdc, serial, &format!("uitest uiInput text '{literal}'"))
}

fn checked_input(hdc: &Hdc<'_>, serial: &str, command: &str) -> Result<(), String> {
    let command = format!("{command}; printf '\\n__HOSMIRROR_INPUT_STATUS__%d\\n' \"$?\"");
    let error = || "鸿蒙设备未能执行输入命令".to_string();
    let output = hdc
        .run(&["-t", serial, "shell", &command], Duration::from_secs(5))
        .map_err(|_| error())?; // 不向 UI 或日志回显输入内容。
    if output.trim_end().ends_with("__HOSMIRROR_INPUT_STATUS__0")
        && !output.contains("Missing parameter")
        && !output.contains("invalid command")
        && !output.contains("[Fail]")
    {
        Ok(())
    } else {
        Err(error())
    }
}

#[cfg(test)]
mod tests {
    use super::parse_power;

    #[test]
    fn uses_current_physical_display_state() {
        let output = "screen[0]: id=1, isVirtual=true, powerStatus=POWER_STATUS_ON\nscreen[1]: id=0, isVirtual=false, powerStatus=POWER_STATUS_SUSPEND";
        assert_eq!(parse_power(output), Some(false));
        assert_eq!(
            parse_power("CURRENT STATE: AWAKE\nHistory: SLEEP"),
            Some(true)
        );
        assert_eq!(parse_power("History: CURRENT STATE: AWAKE"), None);
    }
}
