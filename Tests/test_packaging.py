"""以本地替身验证真实打包脚本的签名顺序，不签名、不提交 Apple 服务。"""
import os  # 为子进程提供隔离的 PATH 和测试身份。
import plistlib  # 生成 PlistBuddy 能读取的最小 App 元数据。
import shutil  # 把待测脚本复制到隔离目录。
import subprocess  # 执行真实的 shell 编排逻辑。
import sys  # 判断当前系统是否具备 Apple plist 工具。
import tempfile  # 每个测试独享临时目录。
import unittest  # 使用 Python 标准测试库，无需额外依赖。
from pathlib import Path  # 安全拼接临时路径。

ROOT = Path(__file__).resolve().parents[1]  # 确定项目根目录。


@unittest.skipUnless(sys.platform == "darwin", "requires macOS PlistBuddy/plutil")
class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="hosmirror-packaging-")  # 禁止触碰现有 dist 产物。
        self.addCleanup(self.directory.cleanup)  # 失败时同样删除隔离夹具。
        self.root = Path(self.directory.name)  # 本次测试的假项目。
        (self.root / "scripts").mkdir()  # 与真实项目保持相同脚本相对路径。
        (self.root / "bin").mkdir()  # 测试命令只存在于隔离 PATH。
        self.trace = self.root / "trace"  # 记录真实脚本调用的先后顺序。
        for name in ("notarize.sh", "package-dmg.sh", "dmg-layout.py"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)  # 使用未改写的生产编排脚本。
        self.write_executable("scripts/vendor_scrcpy.py", "import os, sys\nsys.exit(int(os.environ.get('COMPLIANCE_RESULT', '0')))\n")  # 材料校验器独立测试，此处只控制实际打包脚本的通过/失败分支。
        (self.root / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1"}))  # 为 build 替身提供版本。
        self.write_executable("scripts/build-app.sh", '''#!/bin/sh
# 模拟重建 App 时覆盖签名，这正是原问题的触发条件。
echo build >> "$TRACE"
rm -rf 'dist/Screen Annex.app'
mkdir -p 'dist/Screen Annex.app/Contents'
mkdir -p 'dist/Screen Annex.app/Contents/Helpers/Screen Annex Settings.app' # 模拟随包内置的独立设置应用。
cp Info.plist 'dist/Screen Annex.app/Contents/Info.plist'
echo adhoc > 'dist/Screen Annex.app/signature'
''')
        self.write_executable("bin/codesign", '''#!/bin/sh
# 只记录调用；不使用真实证书或钥匙串。
printf 'codesign %s\\n' "$*" >> "$TRACE"
for target do :; done
# 用文本标记模拟 Developer ID 签名。
case "$*" in
  *'--sign Test Developer'*)
    case "$target" in *.app) echo developer > "$target/signature" ;; esac ;;
esac
''')
        self.write_executable("bin/dmgbuild.py", '''
import argparse
import os
import runpy
from pathlib import Path

# 执行真实布局配置，并记录交给打包器时的 App 签名。
if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("-s", required=True)
    parser.add_argument("-D", action="append", required=True)
    parser.add_argument("volume")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    defines = dict(entry.split("=", 1) for entry in args.D)
    settings = runpy.run_path(args.s, init_globals={"defines": defines})
    app = Path(settings["files"][0])
    assert app.name == "Screen Annex.app"
    assert (app / "Contents/Info.plist").is_file()
    assert settings["symlinks"]["Applications"] == "/Applications"
    args.output.write_text((app / "signature").read_text())
    with Path(os.environ["TRACE"]).open("a") as trace:
        trace.write("package\\n")
''')
        self.write_executable("bin/xcrun", '''#!/bin/sh
# 返回结构化审核结果，禁止调用真实 notarytool。
printf 'xcrun %s\\n' "$*" >> "$TRACE"
case "$1" in notarytool) printf '{"status":"%s"}\\n' "${NOTARY_STATUS:-Accepted}" ;; esac
''')
        self.write_executable("bin/spctl", '''#!/bin/sh
# 模拟 Gatekeeper 验证成功或失败。
echo assess >> "$TRACE"
exit "${SPCTL_RESULT:-0}"
''')
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"], PYTHONPATH=str(self.root / "bin"), TRACE=str(self.trace), DEVELOPER_ID="Test Developer", APPLE_ID="test@example.invalid", TEAM_ID="TEST", APP_PASSWORD="test-only")  # 所有身份均为无效测试值。

    def write_executable(self, relative, body):
        path = self.root / relative  # 仅写入本测试的临时目录。
        path.write_text(body)  # 为替身保留可审查的脚本内容。
        path.chmod(0o755)  # 允许真实编排脚本通过 PATH 执行替身。

    def run_script(self, name, *arguments):
        return subprocess.run(["bash", str(self.root / "scripts" / name), *arguments], cwd=self.root, env=self.env, text=True, capture_output=True, timeout=10)  # 所有输出只供断言，不泄露真实环境身份。

    def test_notarization_preserves_developer_signature(self):
        result = self.run_script("notarize.sh")  # 执行完整编排，所有外部副作用均被替换。
        self.assertEqual(result.returncode, 0, result.stderr)  # 正常 Accepted 流程必须成功。
        calls = self.trace.read_text().splitlines()  # 读取执行轨迹。
        self.assertEqual(calls.count("build"), 1)  # 原实现会重建两次。
        self.assertEqual((self.root / "dist/Screen Annex-0.1.dmg").read_text().strip(), "developer")  # 封装时仍是正式签名。
        settings_sign = next(i for i, call in enumerate(calls) if "--sign Test Developer" in call and call.endswith("Screen Annex Settings.app"))
        main_sign = next(i for i, call in enumerate(calls) if "--sign Test Developer" in call and call.endswith("dist/Screen Annex.app"))
        self.assertLess(settings_sign, main_sign)  # 外层应用签名必须封存已经签名的设置 App。
        self.assertTrue(any("stapler staple" in call for call in calls))  # 通过审核后才允许装订票据。

    def test_invalid_notarization_never_staples(self):
        self.env["NOTARY_STATUS"] = "Invalid"  # 即使命令退出为零，审核仍可能未被接受。
        result = self.run_script("notarize.sh")
        self.assertNotEqual(result.returncode, 0)  # 必须检查官方 JSON 状态。
        self.assertNotIn("stapler staple", self.trace.read_text())  # 不装订失败产物。

    def test_gatekeeper_failure_is_not_reported_as_success(self):
        self.env["SPCTL_RESULT"] = "1"  # 模拟最终安全验证失败。
        self.assertNotEqual(self.run_script("notarize.sh").returncode, 0)  # 不能用 || true 隐藏错误。

    def test_no_build_requires_existing_app(self):
        result = self.run_script("package-dmg.sh", "--no-build")  # 缺少 App 时不能偷偷重建。
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.trace.exists())  # 缺少输入即停止，不运行封装或构建命令。

    def test_regular_packaging_still_builds_app(self):
        result = self.run_script("package-dmg.sh")  # 默认开发打包入口仍应正常构建。
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.trace.read_text().splitlines(), ["build", "package"])  # 默认行为保持明确。

    def test_missing_compliance_materials_prevents_packaging(self):
        self.env["COMPLIANCE_RESULT"] = "1"  # 模拟真实校验器发现缺失许可证或源码。
        result = self.run_script("package-dmg.sh")  # 生产脚本必须检查而不是忽略校验结果。
        self.assertNotEqual(result.returncode, 0)  # 不能对不完整的发行包报告成功。
        self.assertNotIn("package", self.trace.read_text().splitlines())  # 校验失败前不能创建 DMG。


if __name__ == "__main__":
    unittest.main()  # 支持直接执行或 unittest discover。
