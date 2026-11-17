import Foundation

/// 连接进度来自真实启动步骤，只表达阶段，不伪造百分比或预计剩余时间。
public enum ConnectionStage: Equatable {
    case checkingDevice // 检查设备是否仍然可用。
    case preparingDevice // 准备设备端需要的组件。
    case connectingVideo // 启动屏幕采集并建立视频转发。
    case connectingControl // 建立输入控制通道。
    case waitingForFrame // 通道就绪后等待首个有效画面。
}
