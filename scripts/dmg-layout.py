"""Finder settings evaluated by dmgbuild when packaging Screen Annex."""

format = "UDZO"
files = [defines["app"]]
# 拖入快捷方式即复制到本机的「应用程序」。
symlinks = {"Applications": "/Applications"}
# 保留 App 的 Finder 元数据，避免打包工具写入签名校验会拒绝的扩展属性。
background = "builtin-arrow"
window_rect = ((200, 150), (640, 240))
icon_size = 96
icon_locations = {"Screen Annex.app": (160, 120), "Applications": (480, 120)}

if "source" in defines:
    # 离线发行的源码文件夹放在底部，给安装路径留出空间。
    files.append(defines["source"])
    window_rect = ((200, 150), (640, 340))
    icon_locations["Source Code"] = (160, 260)
