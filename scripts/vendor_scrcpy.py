#!/usr/bin/env python3
"""安装和校验固定版本的 scrcpy、ADB 和对应发行材料；默认不联网。"""
import argparse  # 明确区分首次准备资源、日常离线校验和发行目录组装。
import hashlib  # 所有归档和运行文件使用 SHA-256 校验。
import json  # 读取可审查的版本锁与逐文件清单。
import shutil  # 仅复制经过校验的文件，不执行下载包中的脚本。
import subprocess  # 下载使用系统 curl，签名校验使用系统 codesign。
import struct  # 解析 Mach-O 头部，只忽略签名后留下的未使用头部填充。
import sys  # Windows 控制台和重定向日志统一使用 UTF-8。
import tarfile  # 手工提取普通文件，拒绝路径穿越和链接成员。
import tempfile  # 签名归一化只修改独占临时副本。
import zipfile  # Windows 发行包及 SDK 声明使用 ZIP。
from pathlib import Path  # 所有路径均相对于明确的项目根目录。

ROOT = Path(__file__).resolve().parents[1]  # 不依赖调用者当前目录。
LOCK = ROOT / "third_party/scrcpy.lock.json"  # 升级必须显式修改锁文件并重新核查许可。
REQUIRED_DOCS = ("THIRD_PARTY_NOTICES.txt", "THIRD_PARTY_TERMS.md", "SCRCPY_CHANGES.md", "REBUILDING.md", "rebuild_scrcpy.sh")  # 任何关键声明缺失都禁止打包。


def digest(path):
    with path.open("rb") as stream:  # 流式计算，避免把大源码包一次载入内存。
        return hashlib.file_digest(stream, "sha256").hexdigest()  # 返回标准小写摘要。


def code_digest(path):
    with tempfile.TemporaryDirectory(prefix="hosmirror-signature-") as directory:  # 不修改原始上游文件或用户安装包。
        copy = Path(directory) / "binary"  # codesign 只操作此临时文件。
        shutil.copy2(path, copy)  # 保留完整的每架构 Mach-O 内容。
        subprocess.run(["codesign", "--remove-signature", str(copy)], check=True, capture_output=True)  # 去掉旧签名或新签名，不忽略代码变化。
        data = copy.read_bytes()  # 签名移除后再归一化未使用的头部填充。
    slices = []  # 通用 ADB 和单架构 scrcpy 使用相同的代码内容比较规则。
    if data[:4] == b"\xca\xfe\xba\xbe":  # macOS Platform Tools 的 ADB 为 FAT32 通用容器。
        count = struct.unpack_from(">I", data, 4)[0]  # 容器记录每个架构的偏移与大小。
        for index in range(count):
            cpu, subtype, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + index * 20)  # 忽略容器层的对齐填充，不忽略任何架构。
            slices.append((cpu, subtype, data[offset:offset + size]))  # 每个架构分别计算规范化字节。
    else:
        slices.append((0, 0, data))  # 非通用 scrcpy 只有一个 Mach-O 切片。
    result = hashlib.sha256()  # 多架构结果按明确的 CPU 类型合并。
    for cpu, subtype, raw in sorted(slices):
        content = bytearray(raw)  # 只有签名移除后的临时数据会被修改。
        if content[:4] != b"\xcf\xfa\xed\xfe":
            raise ValueError("签名检查只接受已支持的 64 位 Mach-O")  # 未知格式不得跳过内容比较。
        commands, size = struct.unpack_from("<II", content, 16)  # 64 位头部中的 ncmds 与 sizeofcmds。
        position = 32  # 64 位 Mach-O 头部固定为 32 字节。
        first_section = len(content)  # 寻找真正被加载的首个文件段，避免覆盖代码。
        for _ in range(commands):
            command, length = struct.unpack_from("<II", content, position)  # 逐条检查活动加载命令。
            if length < 8 or position + length > 32 + size:
                raise ValueError("Mach-O 加载命令损坏")  # 不能通过损坏头部绕过比较。
            if command == 0x19:  # LC_SEGMENT_64 的 section_64 结构提供准确文件偏移。
                if content[position + 8:position + 24].rstrip(b"\0") == b"__LINKEDIT":
                    file_size = struct.unpack_from("<Q", content, position + 48)[0]  # 去签名后的实际文件数据大小。
                    struct.pack_into("<Q", content, position + 32, (file_size + 4095) // 4096 * 4096)  # 签名工具保留的虚拟段预留大小不影响无签名代码内容，按实际数据统一归一化。
                section_count = struct.unpack_from("<I", content, position + 64)[0]  # 段内节数。
                for index in range(section_count):
                    section = position + 72 + index * 80  # 每个 section_64 占 80 字节。
                    offset = struct.unpack_from("<I", content, section + 48)[0]  # 零偏移通常是没有文件内容的 zerofill 节。
                    if offset:
                        first_section = min(first_section, offset)  # 不接触任何实际文件节。
            position += length  # 继续处理下一条加载命令。
        if not 32 + size <= first_section < len(content):
            raise ValueError("Mach-O 节偏移不合法")  # 未知布局保持失败关闭。
        content[32 + size:first_section] = bytes(first_section - 32 - size)  # codesign 移除后残留的旧签名命令位于未使用头部填充中。
        result.update(struct.pack(">II", cpu, subtype))  # 防止不同架构切片混淆。
        result.update(content)  # 加载命令、代码、常量、重定位和其余数据均参与比较。
    return result.hexdigest()  # 除签名和未使用头部填充外必须完全一致。


def archive_files(path, selected=None):
    if path.suffix == ".zip":  # ZIP 中只允许普通文件和目录。
        with zipfile.ZipFile(path) as archive:  # 关闭时释放归档句柄。
            for member in archive.infolist():  # 保留归档中的原始名字以便检查。
                if member.is_dir() or (selected is not None and member.filename not in selected):
                    continue  # 目录会在写入普通文件时按需创建。
                if (member.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError(f"拒绝归档链接：{member.filename}")  # 不允许链接逃逸安装目录。
                yield member.filename, archive.read(member), (member.external_attr >> 16) & 0o777  # 只保留普通权限位。
    else:  # scrcpy 和依赖源码采用 tar.gz 或 tar.xz。
        with tarfile.open(path) as archive:  # tarfile 根据扩展名识别压缩格式。
            for member in archive:  # 只读取计划交付的文件，不解包其他工具。
                if member.isdir() or (selected is not None and member.name not in selected):
                    continue  # 目录本身没有需要交付的内容。
                if not member.isfile():
                    raise ValueError(f"拒绝非普通文件：{member.name}")  # 拒绝符号链接、硬链接和设备文件。
                yield member.name, archive.extractfile(member).read(), member.mode & 0o777  # 内容仅用于写入或许可证提取。


def checked_file(cache, entry, download, *, command="install", timeout=240):
    path = cache / entry["file"]  # 归档名由项目维护的锁文件提供。
    if not path.exists() or digest(path) != entry["sha256"]:  # 已有错误缓存不能被继续使用。
        if not download:
            raise ValueError(f"缺少或校验失败：{path}；先执行 {command} --download")  # 日常构建不偷偷联网。
        temporary = path.with_name(path.name + ".partial")  # 下载中断时不留下看似完整的文件。
        subprocess.run(["curl", "-fL", "--retry", "3", "--retry-all-errors", "--connect-timeout", "15", "--max-time", str(timeout), entry["url"], "-o", str(temporary)], check=True)  # 下载仅使用锁定的 HTTPS 地址。
        if digest(temporary) != entry["sha256"]:
            temporary.unlink(missing_ok=True)  # 不缓存校验失败的下载。
            raise ValueError(f"官方归档校验失败：{entry['file']}")  # 不降低校验要求。
        temporary.replace(path)  # 仅完整且正确的归档进入缓存。
    return path  # 后续提取只使用已验证文件。


def adb_os(platform):
    return platform.split("-", 1)[0]  # macOS 两种架构共用上游 universal2 归档。


def install_adb(cache, entry, download, destination):
    archive = checked_file(cache, entry, download)
    selected = {f"{entry['root']}/{name}": name for name in entry["files"]}
    for member, content, _ in archive_files(archive, selected):
        name = selected.pop(member)  # 固定路径及文件名，不从归档派生目标路径。
        file = destination / name
        file.write_bytes(content)
        file.chmod(0o755 if name in {"adb", "adb.exe"} else 0o644)  # macOS 从 App 资源目录直接执行 ADB。
    if selected:
        raise ValueError(f"ADB 归档缺少：{sorted(selected)}")


def install(cache, download):
    lock = json.loads(LOCK.read_text(encoding="utf-8"))  # 固定版本，下载内容必须匹配仓库锁定的哈希。
    cache.mkdir(parents=True, exist_ok=True)
    resources = ROOT / "Resources"
    work = ROOT / ".build"  # 独占暂存目录与项目位于同一文件系统，便于原子替换。
    work.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="scrcpy-", dir=work) as directory:
        staged = Path(directory)  # 归档完整校验后才替换原有本机运行目录。
        shutil.copytree(resources / "compliance", staged / "compliance", ignore=shutil.ignore_patterns("scrcpy.lock.json"))
        shutil.copy2(LOCK, staged / "compliance/scrcpy.lock.json")  # 最终产物保留可离线核对的版本锁。
        for platform, entry in lock["binaries"].items():
            archive = checked_file(cache, entry, download)
            target = staged / "scrcpy" / platform
            for name, content, mode in archive_files(archive):
                relative = Path(*Path(name).parts[1:])  # 去掉官方归档的顶层目录。
                if not relative.parts or relative.is_absolute() or ".." in relative.parts:
                    raise ValueError(f"拒绝归档路径：{name}")
                if relative.name in {"adb", "adb.exe", "AdbWinApi.dll", "AdbWinUsbApi.dll"}:
                    continue  # 跳过 scrcpy 归档中来自 Google SDK 的 ADB，下面安装有对应源码的构建。
                destination = target / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(content)
                destination.chmod(mode or 0o644)
            install_adb(cache, lock["adb"]["binaries"][adb_os(platform)], download, target)
        verify(staged, "all", False)  # 使用仓库中的独立清单，不信任下载内容自报的哈希。
        current = resources / "scrcpy"
        previous = staged / "previous"
        if current.exists():
            current.replace(previous)  # 保留旧目录到新目录落盘成功。
        try:
            (staged / "scrcpy").replace(current)
        except OSError:
            if previous.exists():
                previous.replace(current)
            raise
        (staged / "compliance/scrcpy.lock.json").replace(resources / "compliance/scrcpy.lock.json")


def verify(resources, platform, signed, *, staged=False):
    if staged or signed:  # 旧输出目录也不得混入本机的 HarmonyOS SDK。
        for name in ("tools", "devices", "agents"):
            if (resources / name).exists():
                raise ValueError(f"构建输出包含本机 SDK 目录：{resources / name}。请使用干净的输出目录。")
    compliance = resources / "compliance"  # 支持源码目录与最终 App 资源目录。
    lock = json.loads((compliance / "scrcpy.lock.json").read_text(encoding="utf-8"))  # 用户收到的版本锁必须完整。
    if lock != json.loads(LOCK.read_text(encoding="utf-8")):
        raise ValueError("发行目录版本锁与项目不一致")  # 不允许旧运行文件配新声明。
    manifest = json.loads((compliance / "manifest.json").read_text(encoding="utf-8"))  # 日常校验不重新生成清单。
    expected = {name: sha for name, sha in manifest["files"].items() if not name.startswith("scrcpy/") or platform == "all" or name.startswith(f"scrcpy/{platform}/")}  # 发行包只需包含目标平台。
    if platform != "all" and platform not in lock["binaries"]:
        raise ValueError(f"不支持的平台：{platform}")  # 不默默选择其他架构。
    for name in REQUIRED_DOCS:
        if f"compliance/{name}" not in expected:
            raise ValueError(f"清单缺少必需材料：{name}")  # 删除清单条目不能绕过关键文档检查。
    for entry in lock["sources"].values():
        name = "compliance/sources/" + entry["file"]  # 源码归档还要与固定锁中的摘要交叉验证。
        if expected.get(name) != entry["sha256"]:
            raise ValueError(f"源码清单与版本锁不一致：{name}")  # 防止源码和二进制版本漂移。
    for name, sha in lock["adb"]["notices"].items():
        if expected.get(f"compliance/{name}") != sha:
            raise ValueError(f"清单缺少锁定的 ADB 声明：{name}")
    for target in lock["binaries"] if platform == "all" else (platform,):
        for filename, sha in lock["adb"]["binaries"][adb_os(target)]["files"].items():
            expected[f"scrcpy/{target}/{filename}"] = sha  # 直接从 ADB 版本锁要求全部运行文件，包括 Windows USB DLL。
    for filename, sha in lock["macos_window_patch"]["materials"].items():
        if expected.get(f"compliance/{filename}") != sha:
            raise ValueError(f"macOS 窗口补丁材料与版本锁不一致：{filename}")
    windows_patch = lock.get("windows_window_patch", {})
    for filename, sha in windows_patch.get("materials", {}).items():
        if expected.get(f"compliance/{filename}") != sha:
            raise ValueError(f"Windows 窗口补丁材料与版本锁不一致：{filename}")
    local_clients = lock["macos_window_patch"]["clients"]
    for name, sha in expected.items():
        path = resources / name  # 每个缺失文件都会使发布停止。
        if not path.is_file():
            raise ValueError(f"发行包缺少：{name}")  # 不能只检查目录是否存在。
        client = local_clients.get(path.parent.name) if name.startswith("scrcpy/macos-") and path.name == "scrcpy" else None
        if client and (staged or signed):
            sha = client["sha256"] # macOS 组装后须使用经过锁定的窗口补丁版本。
        if staged and name == "scrcpy/windows-x86_64/scrcpy.exe":
            sha = windows_patch["client_sha256"]  # Windows 发行包使用有拖放事件桥接的客户端。
        if signed and name.startswith("scrcpy/macos-") and path.name in {"scrcpy", "adb"}:
            subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True, capture_output=True)  # 签名必须有效，并且只允许签名字节发生变化。
            expected_code = client["code_sha256"] if client else lock["adb"]["binaries"]["macos"]["code_sha256"]
            if digest(path) != sha and code_digest(path) != expected_code:
                raise ValueError(f"重签名后代码内容发生改变：{name}")  # 不能用任意有效签名掩盖真正的代码修改。
        elif digest(path) != sha:
            raise ValueError(f"文件校验失败：{name}")  # 源码、许可证、server、DLL 和其余文件必须逐字节一致。
    actual = {path.relative_to(resources).as_posix() for base in [resources / "scrcpy", compliance] for path in base.rglob("*") if path.is_file() and path.name != "manifest.json"}  # 检查偷偷混入的额外依赖。
    if actual != set(expected):
        raise ValueError(f"运行目录文件集合不匹配：{sorted(actual ^ set(expected))}")  # 同时发现缺失与未声明文件。
    print(f"scrcpy {lock['scrcpy_version']} + ADB {lock['adb']['version']} / {platform}：运行文件和随 App 材料校验通过")


def stage_adb_source(cache, destination, download):
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    adb = lock["adb"]
    cache.mkdir(parents=True, exist_ok=True)  # 独立源码任务从干净检出运行，未安装二进制时也能下载。
    source = checked_file(cache, adb["source"], download, command="adb-source", timeout=1800)
    dependencies = [checked_file(cache, entry, download, command="adb-source") for entry in adb["source_dependencies"]]
    destination.mkdir(parents=True, exist_ok=True)
    package_cache = destination / "packagecache"
    package_cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="adb-source-", dir=destination) as directory:
        entries = [(source, destination), *((path, package_cache) for path in dependencies)]
        for path, parent in entries:
            target = parent / path.name
            if path.resolve() == target.resolve():
                continue  # 允许复用已就位且经过校验的文件。
            staged = Path(directory) / path.name
            shutil.copyfile(path, staged)
            staged.replace(target)  # 提交完整文件，发布目录不会留下只复制一部分的归档。
    shutil.copy2(ROOT / "Resources/compliance/ADB-SOURCES.md", destination / "README.md")


def main():
    if sys.platform == "win32":
        for stream in (sys.stdout, sys.stderr):
            if hasattr(stream, "reconfigure"):
                stream.reconfigure(encoding="utf-8")  # 默认 cp1252 的重定向日志也必须能输出中文诊断。
    parser = argparse.ArgumentParser(description=__doc__)  # 命令帮助说明用途与联网边界。
    parser.add_argument("action", choices=["install", "verify", "stage", "adb-source"])  # 不提供自动升级行为。
    parser.add_argument("--cache", type=Path, default=ROOT / ".build/android-downloads")  # 初次下载目录不进入发行包。
    parser.add_argument("--download", action="store_true")  # 联网必须显式指定。
    parser.add_argument("--platform", default="all")  # 源资源默认检查全部已支持架构。
    parser.add_argument("--resources", type=Path, default=ROOT / "Resources")  # 允许对最终产物执行相同检查。
    parser.add_argument("--signed", action="store_true")  # 仅用于已经重签名的 macOS 产物。
    parser.add_argument("--staged", action="store_true")  # 校验已组装、未重新签名的发行目录。
    parser.add_argument("--destination", type=Path)  # stage 目标必须由打包脚本明确传入。
    args = parser.parse_args()  # 解析后再进行任何文件操作。
    if args.action == "install":
        install(args.cache, args.download)  # 仅安装生成的第三方资源。
    elif args.action == "verify":
        verify(args.resources, args.platform, args.signed, staged=args.staged)  # 默认全离线，失败立即退出。
    elif args.action == "adb-source":
        if args.destination is None:
            parser.error("adb-source 必须指定 --destination")
        stage_adb_source(args.cache, args.destination, args.download)
    else:
        if args.platform == "all" or args.destination is None:
            parser.error("stage 必须指定 --platform 和 --destination")  # 避免把所有平台运行文件都放入一个安装包。
        verify(ROOT / "Resources", "all", False)  # 原始资源校验通过后才允许复制。
        target = args.destination / "scrcpy"  # 目标只是调用者指定的 App 资源目录。
        if target.exists():
            shutil.rmtree(target)  # 删除此阶段管理的旧平台资源，防止跨架构混用。
        shutil.copytree(ROOT / "Resources/scrcpy" / args.platform, target / args.platform)  # 仅复制目标运行平台。
        shutil.copytree(ROOT / "Resources/compliance", args.destination / "compliance", dirs_exist_ok=True)  # 许可证与完整源码一起复制。
        if args.platform.startswith("macos-"):
            client = ROOT / "third_party/scrcpy-macos" / args.platform / "scrcpy"
            shutil.copy2(client, target / args.platform / "scrcpy") # 替换桌面客户端，沿用原包的 server 与资源。
        if args.platform == "windows-x86_64":
            client = ROOT / "third_party/scrcpy-windows" / args.platform / "scrcpy.exe"
            shutil.copy2(client, target / args.platform / "scrcpy.exe")  # server 与运行库仍来自官方归档。
        verify(args.destination, args.platform, False, staged=True)  # 在签名前对组装结果再次校验。


if __name__ == "__main__":
    main()  # 支持直接执行，也允许测试导入纯校验函数。
