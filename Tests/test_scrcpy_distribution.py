"""检查实际发行材料的缺失、污染和重签名；不访问手机、不启动 ADB 服务。"""
import importlib.util  # 导入真实生产校验器，不复制其实现。
import shutil  # 为失败场景复制隔离资源目录。
import subprocess  # 仅调用系统代码签名工具和 scrcpy --version。
import sys  # 非 macOS 主机跳过代码签名测试。
import tempfile  # 每个场景都使用独立可删除副本。
import unittest  # 使用项目现有的标准测试入口。
from pathlib import Path  # 所有路径相对于项目或临时夹具。

ROOT = Path(__file__).resolve().parents[1]  # 不依赖工作目录。
SPEC = importlib.util.spec_from_file_location("vendor_scrcpy", ROOT / "scripts/vendor_scrcpy.py")  # 加载正在打包时使用的生产代码。
VENDOR = importlib.util.module_from_spec(SPEC)  # 创建独立模块对象。
SPEC.loader.exec_module(VENDOR)  # 导入不触发 main 或联网。


class ScrcpyDistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hosmirror-android-package-")  # 不修改真实 Resources 或 dist。
        self.addCleanup(self.temporary.cleanup)  # 任意断言失败也删除夹具。
        self.resources = Path(self.temporary.name)  # 作为假 App 的 Resources。
        self.platform = "windows-x86_64"  # DLL、许可和源码可在任意主机离线检查。
        shutil.copytree(ROOT / "Resources/scrcpy" / self.platform, self.resources / "scrcpy" / self.platform)  # 使用完整真实运行文件。
        shutil.copytree(ROOT / "Resources/compliance", self.resources / "compliance")  # 不能用空文本替代实际许可证。

    def test_complete_windows_distribution_has_matching_sources(self):
        VENDOR.verify(self.resources, self.platform, False)  # 实际运行库和所有声明必须完整。

    def test_missing_adb_usb_library_is_rejected(self):
        (self.resources / "scrcpy" / self.platform / "AdbWinUsbApi.dll").unlink()  # 有 adb.exe 也可能因漏打包 USB DLL 无法连接。
        with self.assertRaisesRegex(ValueError, "AdbWinUsbApi.dll"):
            VENDOR.verify(self.resources, self.platform, False)

    def test_windows_release_uses_the_locked_client_and_keeps_its_patch(self):
        client = self.resources / "scrcpy" / self.platform / "scrcpy.exe"
        with self.assertRaises(ValueError):
            VENDOR.verify(self.resources, self.platform, False, staged=True)
        shutil.copyfile(ROOT / "third_party/scrcpy-windows" / self.platform / client.name, client)
        VENDOR.verify(self.resources, self.platform, False, staged=True)
        (self.resources / "compliance/scrcpy-windows-events.patch").unlink()
        with self.assertRaises(ValueError):
            VENDOR.verify(self.resources, self.platform, False, staged=True)

    def test_missing_license_or_source_is_rejected(self):
        for name in ["licenses/scrcpy-LICENSE.txt", "sources/ffmpeg-9.0.2.tar.xz"]:  # 覆盖署名许可与 LGPL 完整对应源码。
            path = self.resources / "compliance" / name  # 只修改临时安装包。
            original = path.read_bytes()  # 下一场景恢复相同字节。
            path.unlink()  # 模拟打包规则遗漏文件。
            with self.assertRaises(ValueError):
                VENDOR.verify(self.resources, self.platform, False)  # 遗漏必须阻止发行。
            path.write_bytes(original)  # 不让前一场景掩盖后一场景。

    def test_staged_distribution_rejects_locally_installed_sdk(self):
        client = self.resources / "scrcpy" / self.platform / "scrcpy.exe"
        shutil.copyfile(ROOT / "third_party/scrcpy-windows" / self.platform / client.name, client)
        (self.resources / "tools").mkdir()  # 模拟旧产物残留的本机 SDK 目录。
        with self.assertRaisesRegex(ValueError, "本机 SDK"):
            VENDOR.verify(self.resources, self.platform, False, staged=True)

    def test_modified_server_and_undeclared_dll_are_rejected(self):
        server = self.resources / "scrcpy" / self.platform / "scrcpy-server"  # client/server 应来自同一固定版本。
        original = server.read_bytes()  # 保留恢复所需的精确内容。
        server.write_bytes(original + b"unexpected")  # 模拟被混入其他版本或修改后的 server。
        with self.assertRaises(ValueError):
            VENDOR.verify(self.resources, self.platform, False)  # 不能仅凭文件名认为版本正确。
        server.write_bytes(original)  # 恢复原始 server 再测试额外依赖。
        (server.parent / "undeclared.dll").write_bytes(b"not part of the pinned release")  # 模拟未审查的新依赖。
        with self.assertRaises(ValueError):
            VENDOR.verify(self.resources, self.platform, False)  # 未声明运行文件必须使检查失败。

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS codesign")
    def test_resigning_does_not_allow_changed_executable_code(self):
        source = ROOT / "Resources/scrcpy/macos-aarch64/scrcpy"  # 不执行目标二进制，因此 Intel 主机也可检查此文件。
        binary = self.resources / "resigned-scrcpy"  # 只签名临时副本，不操作证书。
        shutil.copy2(source, binary)  # 从已校验官方文件开始。
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True, capture_output=True)  # 模拟 App 组装时的 ad-hoc 重签名。
        self.assertEqual(VENDOR.code_digest(source), VENDOR.code_digest(binary))  # 仅签名元数据改变应被接受。
        data = bytearray(binary.read_bytes())  # 修改副本的实际文件节，不能被归一化忽略。
        data[65536] ^= 1  # 此偏移位于代码/常量载荷，远离签名与加载命令填充。
        binary.write_bytes(data)  # 不执行被修改程序。
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True, capture_output=True)  # 即使攻击文件重新获得有效签名也要拒绝。
        self.assertNotEqual(VENDOR.code_digest(source), VENDOR.code_digest(binary))  # 真实代码变化不能借重签名规则绕过检查。


if __name__ == "__main__":
    unittest.main()  # 可直接运行或由 unittest discover 执行。
