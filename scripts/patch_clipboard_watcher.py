#!/usr/bin/env python3
"""CI/本地补丁：把 clipboard_watcher 插件的 compileSdk 从 33 提升到 36。

背景：clipboard_watcher 0.3.0 在 android/build.gradle 写死 compileSdk 33，
但其 AndroidX 依赖要求 compileSdk >= 34，会导致 :clipboard_watcher:check*AarMetadata
失败。Flutter 不会用 App 的 compileSdk 覆盖插件写死的值，只能改插件文件本身。

本地把 pub 缓存里的该文件改成 36 即可；CI 是全新 pub 缓存，须在 flutter pub get
之后、构建之前自动改。本脚本解析 Flutter 生成的 .flutter-plugins-dependencies
（权威路径）并兜底搜索 $PUB_CACHE，定位并 patch 插件 android 工程，幂等。
"""
import os
import re
import sys
import json
import glob

RE_CS_VERSION = re.compile(r"compileSdkVersion\s+\d+")
RE_CS_EQ = re.compile(r"compileSdk\s*=\s*\d+")

TARGET = 36


def pub_cache_bases():
    """收集所有可能的 pub 缓存根目录（跨平台 + 显式 PUB_CACHE）。"""
    bases = []
    if os.environ.get("PUB_CACHE"):
        bases.append(os.environ["PUB_CACHE"])
    bases.append(os.path.join(os.path.expanduser("~"), ".pub-cache"))  # Linux/macOS 默认
    local = os.environ.get("LOCALAPPDATA")  # Windows 默认: %LOCALAPPDATA%\Pub\Cache
    if local:
        bases.append(os.path.join(local, "Pub", "Cache"))
    seen, out = set(), []
    for b in bases:
        if b and os.path.isdir(b) and b not in seen:
            seen.add(b)
            out.append(b)
    return out


def resolve_candidates(repo_root: str):
    cands = set()

    # 1) 权威路径：Flutter 生成的依赖清单里直接给出插件绝对路径（CI 上最可靠）
    dep = os.path.join(repo_root, "android", ".flutter-plugins-dependencies")
    if os.path.exists(dep):
        try:
            with open(dep, "r", encoding="utf-8") as f:
                data = json.load(f)
            for plug in data.get("plugins", {}).get("android", []):
                if plug.get("name") == "clipboard_watcher":
                    p = plug.get("path")
                    if p:
                        cands.add(os.path.join(p, "android", "build.gradle"))
        except Exception as e:  # noqa: BLE001
            print(f"[warn] 解析 .flutter-plugins-dependencies 失败: {e}")

    # 2) 兜底：在各 pub 缓存根目录里按文件名搜
    for base in pub_cache_bases():
        for pat in glob.glob(
            os.path.join(base, "**", "clipboard_watcher*", "android", "build.gradle"),
            recursive=True,
        ):
            cands.add(pat)

    # 过滤掉 example 工程（不会被主构建引用，改了也无意义）
    cands = {c for c in cands if "/example/" not in c.replace("\\", "/")}
    return sorted(c for c in cands if os.path.isfile(c))


def patch_file(path: str) -> bool:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    new = RE_CS_VERSION.sub(f"compileSdkVersion {TARGET}", content)
    new = RE_CS_EQ.sub(f"compileSdk = {TARGET}", new)
    if new != content:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        print(f"[patched] {path}")
        return True
    print(f"[ok]      {path}")
    return False


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cands = resolve_candidates(repo_root)
    if not cands:
        print(
            "[warn] 未找到 clipboard_watcher 的 android/build.gradle，"
            "跳过 patch（构建可能仍因 compileSdk 33 失败）。"
        )
        return 0
    patched = 0
    for c in cands:
        if patch_file(c):
            patched += 1
    print(f"[done] 共处理 {len(cands)} 个文件，其中 patch {patched} 个。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
