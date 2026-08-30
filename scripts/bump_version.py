#!/usr/bin/env python3
"""EverLink 发版脚本（本地辅助，标准 tag 触发 CI 流程）。

标准发版方式（Flutter 社区通用）：
  1. 唯一版本源 = pubspec.yaml 的 `version: x.y.z+build`；
  2. 推送 `vX.Y.Z` 标签即触发 GitHub Actions（build-release.yml）自动构建并发布 Release；
  3. CI 从 pubspec 读取版本，并断言其与 tag 一致（不一致直接失败）。

因此本脚本只做三件事：改 pubspec 版本 → 提交 → 打 annotated tag。
构建 / 打包 / 发布全部交给 CI。推送需在本机配好凭据后执行
（此机无 GitHub 凭据，故默认只打印推送命令，可用 --push 尝试）。

用法：
  python scripts/bump_version.py patch            # 1.2.0+15 -> 1.2.1+16
  python scripts/bump_version.py minor            # 1.2.0+15 -> 1.3.0+16
  python scripts/bump_version.py major            # 1.2.0+15 -> 2.0.0+16
  python scripts/bump_version.py 1.3.0            # 指定完整版本，build 自动 +1
  python scripts/bump_version.py 1.3.0+20         # 指定版本 + build

选项：
  --push       尝试自动推送（默认不推送，仅打印命令）
  --dry-run    只预览，不写文件、不提交、不打 tag
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "pubspec.yaml"

# pubspec.yaml 中 version: major.minor.patch+build
VER_RE = re.compile(r"^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$", re.M)


def read_version() -> tuple[str, int]:
    """读取 pubspec.yaml 的 (version, build)。pubspec 是版本唯一源。"""
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
    """按 major/minor/patch 进位，低位归零。"""
    major, minor, patch = (int(x) for x in cur.split("."))
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    if part == "patch":
        return f"{major}.{minor}.{patch + 1}"
    sys.exit(f"错误：未知升级类型 {part!r}（可选 patch/minor/major 或直接给版本号）")


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        capture_output=True, text=True, encoding="utf-8",
    )


def main() -> None:
    ap = argparse.ArgumentParser(description="EverLink 发版辅助（改 pubspec + 打 tag）")
    ap.add_argument("target", help="patch / minor / major / X.Y.Z / X.Y.Z+N")
    ap.add_argument("--push", action="store_true", help="尝试自动推送（默认不推送）")
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

    if tuple(int(x) for x in new_ver.split(".")) < tuple(int(x) for x in cur_ver.split(".")):
        sys.exit(f"错误：新版本 {new_ver} 低于当前 {cur_ver}（发版不允许回退）")

    print(f"版本：{cur_ver}+{cur_build}  ->  {new_ver}+{new_build}")
    if args.dry_run:
        print("（dry-run，未做任何修改）")
        return

    # 1) 写入 pubspec.yaml（版本唯一源）
    write_version(new_ver, new_build)
    print(f"✓ pubspec.yaml -> version: {new_ver}+{new_build}")

    # 2) 仅提交 pubspec.yaml（限定文件，避免夹带无关改动）
    tag = f"v{new_ver}"
    git("commit", "-m", f"chore(release): v{new_ver}", "--", "pubspec.yaml")
    git("tag", "-a", tag, "-m", f"EverLink v{new_ver}")
    print(f"✓ 已提交并打 tag {tag}")

    # 3) 推送（触发 build-release.yml 自动构建发版）
    if not args.push:
        print("\n本机无 GitHub 凭据，请手动推送（二选一）：")
        print("  标准（tag 为新建）： git push --follow-tags")
        print("  若曾强推过该 tag：   git push origin master && git push -f origin " + tag)
        return
    r = git("push", "--follow-tags")
    if r.returncode != 0:
        print(f"推送失败：{r.stderr.strip()}")
        print(f"tag {tag} 已在本地，请手动执行：git push --follow-tags")
        sys.exit(1)
    print(f"✓ 已推送 {tag}，CI 将自动构建并发布 Release")


if __name__ == "__main__":
    main()
