#!/usr/bin/env python3
"""EverLink 版本号自动管理脚本。

一条命令完成：改 pubspec.yaml 版本 → 同步 update.json → 提交 → 打 tag → 推送（触发 CI 发版）。

用法：
  python scripts/bump_version.py patch          # 1.0.0+1  -> 1.0.1+2
  python scripts/bump_version.py minor          # 1.0.0+1  -> 1.1.0+2
  python scripts/bump_version.py major          # 1.0.0+1  -> 2.0.0+2
  python scripts/bump_version.py 1.2.3          # 指定完整版本号，build 自动 +1
  python scripts/bump_version.py 1.2.3+10       # 指定版本号 + build 号

选项：
  --notes "更新说明"   写入 update.json 的 notes 字段（留档用）
  --no-push            只改文件 + 提交 + 打 tag，不推送
  --dry-run            只打印将要发生的改动，不写任何文件

说明：
  - CI（build-release.yml）由 tag 推送触发，tag 名必须与 pubspec.yaml 的
    version 字段一致（v 前缀可选）；本脚本自动保证三者一致。
  - App 内更新检查走 GitHub Releases API（tag 即版本号），因此 tag 正确
    = App 内“检查更新”正确。
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "pubspec.yaml"
UPDATE_JSON = ROOT / "update.json"

# pubspec.yaml 中 version: major.minor.patch+build
VER_RE = re.compile(r"^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$", re.M)


def read_version() -> tuple[str, int]:
    text = PUBSPEC.read_text(encoding="utf-8")
    m = VER_RE.search(text)
    if not m:
        sys.exit(f"错误：{PUBSPEC} 中找不到 version: X.Y.Z+N 行")
    return ".".join(m.groups()[:3]), int(m.group(4))


def write_version(version: str, build: int) -> None:
    text = PUBSPEC.read_text(encoding="utf-8")
    text, n = VER_RE.subn(f"version: {version}+{build}", text, count=1)
    if n != 1:
        sys.exit("错误：替换 version 行失败")
    PUBSPEC.write_text(text, encoding="utf-8")


def bump(cur: str, part: str) -> str:
    major, minor, patch = (int(x) for x in cur.split("."))
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    if part == "patch":
        return f"{major}.{minor}.{patch + 1}"
    sys.exit(f"错误：未知升级类型 {part!r}（可选 patch/minor/major 或直接给版本号）")


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        capture_output=True, text=True, encoding="utf-8", check=check,
    )


def sync_update_json(version: str, build: int, notes: str | None) -> None:
    """update.json 与新版本保持同步（App 端已不依赖它，仅作发版留档）。"""
    if not UPDATE_JSON.exists():
        print("（update.json 不存在，跳过同步）")
        return
    data = json.loads(UPDATE_JSON.read_text(encoding="utf-8"))
    data["version"] = version
    data["build"] = build
    data.setdefault("downloadUrls", {})
    data["downloadUrls"]["github"] = (
        f"https://github.com/bobocha214/everlink/releases/download/"
        f"v{version}/EverLink-{version}-android.apk"
    )
    data["downloadUrls"]["gitee"] = (
        f"https://gitee.com/zhiyu_214/ever-link/releases/download/"
        f"v{version}/EverLink-{version}-android.apk"
    )
    if notes:
        data["notes"] = notes
    UPDATE_JSON.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def main() -> None:
    ap = argparse.ArgumentParser(description="EverLink 版本号自动管理")
    ap.add_argument("target", help="patch / minor / major / X.Y.Z / X.Y.Z+N")
    ap.add_argument("--notes", help="更新说明（写入 update.json）")
    ap.add_argument("--no-push", action="store_true", help="不推送到远端")
    ap.add_argument("--dry-run", action="store_true", help="只预览，不实际修改")
    args = ap.parse_args()

    cur_ver, cur_build = read_version()

    # 解析目标版本
    if re.fullmatch(r"\d+\.\d+\.\d+(\+\d+)?", args.target):
        if "+" in args.target:
            new_ver, new_build = args.target.split("+")
            new_build = int(new_build)
        else:
            new_ver, new_build = args.target, cur_build + 1
    else:
        new_ver = bump(cur_ver, args.target)
        new_build = cur_build + 1

    print(f"版本：{cur_ver}+{cur_build}  ->  {new_ver}+{new_build}")
    if args.dry_run:
        print("（dry-run，未做任何修改）")
        return

    # 1) pubspec.yaml
    write_version(new_ver, new_build)
    print(f"✓ pubspec.yaml -> version: {new_ver}+{new_build}")

    # 2) update.json
    sync_update_json(new_ver, new_build, args.notes)
    print(f"✓ update.json -> {new_ver} / build {new_build}")

    # 3) 提交 + 打 tag（路径限定提交，避免把暂存区里无关改动带进去）
    tag = f"v{new_ver}"
    files = ["pubspec.yaml"] + (["update.json"] if UPDATE_JSON.exists() else [])
    git("commit", "-m", f"chore: bump version to {new_ver}+{new_build}", "--", *files)
    git("tag", "-a", tag, "-m", f"EverLink v{new_ver}")
    print(f"✓ 已提交并打 tag {tag}")

    # 4) 推送（触发 build-release.yml 自动构建发版）
    if args.no_push:
        print("（--no-push：未推送。手动推送请执行：git push --follow-tags）")
        return
    r = git("push", "--follow-tags")
    if r.returncode != 0:
        print(f"推送失败：{r.stderr.strip()}")
        print(f"tag {tag} 已在本地，稍后手动执行：git push --follow-tags")
        sys.exit(1)
    print(f"✓ 已推送 {tag}，CI 将自动构建并发布 Release（APK: EverLink-{new_ver}-android.apk）")


if __name__ == "__main__":
    main()
