#!/usr/bin/env python3
"""Build the stable public catalog for the Windows and Codex Skill collection."""

from __future__ import annotations

import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SKILLS = ROOT / "skills"
NAMES = [
    "diannao-kongzhi",
    "windows-storage-cleanup",
    "zhuomian-zhengli",
    "ai-output-renamer",
    "video-project-library-maintainer",
    "codex-task-renamer",
]
PURPOSE = {
    "diannao-kongzhi": "通过受限Windows UI Automation包装器操作桌面应用",
    "windows-storage-cleanup": "审计磁盘占用并按确认清单安全清理",
    "zhuomian-zhengli": "盘点并安全调整Windows桌面图标布局",
    "ai-output-renamer": "安全整理AI输出副本并生成中文语义名称",
    "video-project-library-maintainer": "登记、索引和维护本地视频工程资料库",
    "codex-task-renamer": "预览并在确认后批量重命名Codex任务",
}
NETWORK = {"windows-storage-cleanup"}
WRITES = {
    "diannao-kongzhi",
    "windows-storage-cleanup",
    "zhuomian-zhengli",
    "ai-output-renamer",
    "video-project-library-maintainer",
}
NO_FILESYSTEM_READ = {"codex-task-renamer"}
EXTERNAL = set(NAMES)
DEPENDENCIES = {
    "diannao-kongzhi": [
        "Windows 10/11",
        "Windows PowerShell 5.1+",
        "用户另行安装、审查并锁定SHA-256的Safe-WinApp.ps1受限包装器",
        "与包装器兼容的Windows UI Automation后端",
    ],
    "windows-storage-cleanup": [
        "Windows 10/11",
        "Windows PowerShell 5.1+或PowerShell 7+",
        "可选：用户自行安装并获许可使用的WizTree",
    ],
    "zhuomian-zhengli": [
        "Windows 10/11",
        "PowerShell 7+",
        "Windows Explorer Shell/COM（系统内置）",
    ],
    "ai-output-renamer": [
        "Windows 10/11",
        "PowerShell 7+",
        "已有的AI输出副本库及其索引",
    ],
    "video-project-library-maintainer": [
        "Python 3.10+",
        "可选：Windows PowerShell 5.1+或PowerShell 7+（仅创建Windows桌面快捷方式时需要）",
    ],
    "codex-task-renamer": [
        "提供任务列表、任务读取和标题修改原生工具的Codex环境",
    ],
}


def display_name(name: str) -> str:
    text = (SKILLS / name / "agents" / "openai.yaml").read_text(encoding="utf-8")
    match = re.search(r'^\s*display_name:\s*["\']?(.+?)["\']?\s*$', text, re.M)
    return match.group(1) if match else name


def main() -> int:
    provenance = json.loads((ROOT / "provenance.json").read_text(encoding="utf-8"))
    approved = {row["name"] for row in provenance.get("skills", [])}
    planned = set(NAMES)
    directories = {path.name for path in SKILLS.iterdir() if path.is_dir()}
    if approved != planned or directories != approved:
        raise ValueError(
            "publication set differs from provenance approval: "
            f"unplanned={sorted(directories - approved)}, "
            f"missing={sorted(approved - directories)}, "
            f"metadata_gap={sorted(approved ^ planned)}"
        )
    rows = []
    for name in NAMES:
        platforms = (["cross-platform", "windows"] if name == "video-project-library-maintainer"
                     else ["cross-platform"] if name == "codex-task-renamer"
                     else ["windows"])
        rows.append({
            "name": name,
            "display_name_zh": display_name(name),
            "purpose_zh": PURPOSE[name],
            "release": "v0.1.1",
            "platforms": platforms,
            "risk_level": "high",
            "permissions": {
                "network": name in NETWORK,
                "filesystem_read": name not in NO_FILESYSTEM_READ,
                "filesystem_write": name in WRITES,
                "credentials": False,
                "external_state": name in EXTERNAL,
                "cost_or_quota": False,
            },
            "dependencies": DEPENDENCIES[name],
            "invocation_policy": "explicit-only",
            "license": "MIT",
            "version": "0.1.1",
            "archive_sha256": None,
        })
    payload = {
        "schema_version": 1,
        "repository": "ranveerankhira-gif/windows-codex-agent-skills",
        "skills": rows,
    }
    target = ROOT / "catalog.json"
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {target} with {len(rows)} skills")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

