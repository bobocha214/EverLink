#!/usr/bin/env python3
"""从 CHANGELOG.md 抽取指定版本的段落，作为 GitHub Release 的说明正文。

配合 build-release.yml 使用（Level 1 发版流程）：
  1. 变更写在 CHANGELOG.md 的 `## [x.y.z] - 日期` 段落里（Keep a Changelog 格式）；
  2. CI 用本脚本抽出当前版本段落写入 RELEASE_NOTES.md；
  3. action-gh-release 以 body_path 引用该文件，GitHub 自动生成的提交列表追加其后。

抽出的文本会展示在应用内的更新弹窗（UpdateService.notes），所以写给用户看。

用法：
  python scripts/extract_changelog.py                      # 版本取自 pubspec.yaml，打印到 stdout
  python scripts/extract_changelog.py 1.2.4                # 指定版本
  python scripts/extract_changelog.py -o RELEASE_NOTES.md  # 写入文件（CI 用法）
  python scripts/extract_changelog.py --strict             # 找不到段落即失败（发版前自检）

退出码：
  0  找到段落，或未找到但已输出兜底文案（非 --strict）
  2  --strict 下未找到对应版本段落
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
PUBSPEC = ROOT / "pubspec.yaml"

# `## [1.2.4] - 2026-08-30` / `## [v1.2.4]` / `## 1.2.4` 均可识别。
HEADING_RE = re.compile(r"^##\s+\[?v?(\d+\.\d+\.\d+)\]?")
# Keep a Changelog 惯例的底部链接定义（`[1.2.4]: https://...`），不应出现在 Release 正文里。
LINK_DEF_RE = re.compile(r"^\[[^\]]+\]:\s*https?://")

FALLBACK = "本次发布未提供人工撰写的更新说明，请参考下方自动生成的变更列表。"


def pubspec_version() -> str:
    """从 pubspec.yaml 读版本号（版本唯一源，与 bump_version.py / CI 保持一致）。"""
    m = re.search(r"^version:\s*(\d+)\.(\d+)\.(\d+)", PUBSPEC.read_text(encoding="utf-8"), re.M)
    if not m:
        sys.exit(f"错误：{PUBSPEC} 中找不到 version: X.Y.Z 行")
    return ".".join(m.groups()[:3])


def extract(text: str, version: str) -> str | None:
    """取出 version 段落正文。未找到返回 None；找到但内容为空返回空串。"""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        m = HEADING_RE.match(line)
        if m and m.group(1) == version:
            start = i + 1
            break
    if start is None:
        return None

    body: list[str] = []
    for line in lines[start:]:
        if line.startswith("## "):  # 下一个版本段落（含 `## [未发布]`）即终止
            break
        if LINK_DEF_RE.match(line):
            continue
        body.append(line)
    return "\n".join(body).strip("\n")


def main() -> None:
    ap = argparse.ArgumentParser(description="抽取 CHANGELOG.md 中指定版本的段落")
    ap.add_argument("version", nargs="?", help="版本号（默认取 pubspec.yaml）")
    ap.add_argument("-o", "--output", help="输出文件（默认写到 stdout）")
    ap.add_argument("--strict", action="store_true", help="未找到段落时以退出码 2 失败")
    args = ap.parse_args()

    version = args.version or pubspec_version()
    if not CHANGELOG.exists():
        sys.exit(f"错误：找不到 {CHANGELOG}")

    section = extract(CHANGELOG.read_text(encoding="utf-8"), version)
    if not section:
        reason = "未找到" if section is None else "内容为空"
        if args.strict:
            print(f"错误：CHANGELOG.md 中 {version} 段落{reason}", file=sys.stderr)
            sys.exit(2)
        print(f"警告：CHANGELOG.md 中 {version} 段落{reason}，使用兜底文案", file=sys.stderr)
        section = FALLBACK

    if args.output:
        Path(args.output).write_text(section + "\n", encoding="utf-8", newline="\n")
        print(f"已写入 {args.output}（{version}，{len(section)} 字符）", file=sys.stderr)
    else:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        print(section)


if __name__ == "__main__":
    main()
