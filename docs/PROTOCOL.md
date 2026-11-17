# HarmonyOS 协议参考

该参考基于 hosScrcpy 1.0.17.12 的协议描述、设备通信观察和 [hnscrcpy 协议文档](https://github.com/taxiao213/hnscrcpy/blob/main/docs/HOS_SCRCPY_PROTOCOL.md)。

## protobuf（从 jar 内 descriptor 提取）

```proto
syntax = "proto3";

service ScrcpyService {
  rpc onStart (Empty) returns (stream ReplyMessage);
  rpc onEnd (Empty) returns (ReplyEndMessage);
  rpc onRequestIDRFrame (Empty) returns (ReplyEndMessage);
}

message Empty {}

message ReplyMessage {
  string data = 1;
  int32 reply_type = 2;
  map<string, ParamValue> payload = 3;
}

message ParamValue {
  oneof values {
    int64  val_int = 1;
    double val_double = 2;
    string val_string = 3;
    bool   val_bool = 4;
    bytes  val_bytes = 5;
    float  val_float = 6;
  }
}

message ReplyEndMessage { int32 result = 1; }
```

视频帧取 `payload["data"].val_bytes`。

## 设备端守护进程

```bash
# 采集端（扩展）
/system/bin/uitest start-daemon singleness \
  --extension-name libscreen_casting.z.so \
  -scale 1 -frameRate 30 -bitRate 8388608 -p 5000 -iFrameInterval 2000 &

# 注入端
/system/bin/uitest start-daemon singleness &
```

> 两个守护进程都叫 `singleness`，但参数不同，可以共存。

## 端口转发

```bash
# uitest >= 6.0.2.1
hdc fport tcp:<D> localabstract:scrcpy_grpc_socket
hdc fport tcp:<C> localabstract:uitest_socket
# 老版本
hdc fport tcp:<D> tcp:5000
hdc fport tcp:<C> tcp:8012
```

## gRPC 调用

- 目标：`127.0.0.1:<D>`，明文 h2c，无 TLS
- 路径：`/ScrcpyService/onStart`
- macOS 解码器需要恢复时，或视频在连续增量帧后停稳时，在同一 HTTP/2 连接上另开流调用 `/ScrcpyService/onRequestIDRFrame`。该流的响应不进入视频解包，设备静止时可能等到下一张采集帧才输出关键帧。
- 消息大小上限：100 MB
- 请求体：`Empty`（5 字节 `00 00 00 00 00`）
- 响应：server-streaming，每个 gRPC 消息 = 一帧

## H.264 约定

- 4 字节起始码 `00 00 00 01`
- 首条消息通常是 SPS+PPS（约 31–33 字节）
- 之后每条消息 = 一个访问单元
- 静止画面不推帧；交互时最高 30 fps

## 控制 JSON

```json
{"module":"com.ohos.devicetest.hypiumApiHelper","method":"Gestures",
 "params":{"api":"touchDown","args":{"x":600,"y":1200}}}
```

- `api`：`touchDown` / `touchMove` / `touchUp`、`ButtonLeftDown` 等、`AxisUp/AxisDown`
- 旋转：`api = "Driver.setDisplayRotation"`，`args = [1|0]`
- 响应：`{"result":null,"pts":1000}`
- 同步 RPC：发一条等一条，高频移动需客户端节流

## 按键（uinput）

| 功能 | 命令 |
|---|---|
| 返回 | `uinput -K -d 2 -u 2` |
| 主页 | `uinput -K -d 1 -u 1` |
| 电源 | `uinput -K -d 18 -u 18` |
| 最近任务 | `uinput -K -d 2720 -u 2720` |
| 回车 | `uinput -K -d 2054 -u 2054` |
| 退格 | `uinput -K -d 2055 -u 2055` |

## 组件版本选择

| uitest 版本 | 采集端 | 注入端 |
|---|---|---|
| ≥ 6.0.2.1 | `libscrcpy_server_unix_6.5-device.z.so` | `uitest_agent_1.2.2.so` |
| ≥ 6.0.2.1（无 6.5） | `libscrcpy_server_unix_6.4-20260113.z.so` | `uitest_agent_1.2.2.so` |
| ≥ 5.1.1.2 | `libscrcpy_server_5.10-20260114.z.so` | `uitest_agent_1.1.10.so` |
| 更低 | `libscrcpy_server3.z.so` | `uitest_agent_1.1.10.so` |
| 模拟器 | `libscrcpy_server_emulator.z.so` | 同上 |

判定模拟器：`ls /system/lib64/libCPHMediaEngine.z.so` 存在。

## 滚轮与键盘（macOS）

鸿蒙触屏列表可能不处理鼠标滚轮轴。macOS 通过现有控制连接把连续滚动转换为一组 `touchDown`、`touchMove` 和 `touchUp`，按触控板的实际位移或鼠标格数移动。起点避开系统手势区，微小位移不会触发点按。

短英文、数字和空格通过同一控制连接上的 `callHypiumApi` 调用 `Driver.triggerKey` 或 `Driver.triggerCombineKeys`。中文、长文本和其他字符仍使用 `uitest uiInput text` 送到当前焦点。首批立即发送，发送期间收到的新字符才合并。Mac 输入法只转发已确认内容。

实机采集组件的 `-scale` 接受整数除数：`1` 是原始分辨率，`2` 是宽和高各减半。旧版传入的 `0.75` 实际回到原始尺寸。

## 独立滚轮轴（Windows）

滚动调用 Gestures 的 AxisUp、AxisDown，位置参数与触控一样使用物理像素 x/y，每个批次最后发送 AxisStop。正向步进使用 AxisDown，反向使用 AxisUp；客户端保留原有方向约定。

该路径不能发送 touchDown、touchUp、ButtonLeftDown 等点击原语；设备返回错误时也禁止回退到短距离触摸滑动。这样即使在屏幕边缘或惯性末尾，也不会因为零长度触摸而产生一次点按。
