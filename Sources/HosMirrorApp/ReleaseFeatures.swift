enum ReleaseFeatures {
    // 公开 Android 版隐藏鸿蒙入口，开发构建保留两平台的调试能力。
    #if ANDROID_RELEASE
    static let harmonyEnabled = false
    #else
    static let harmonyEnabled = true
    #endif
}
