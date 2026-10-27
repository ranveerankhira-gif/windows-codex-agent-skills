#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

DEFAULT_LIBRARY = os.environ.get("VIDEO_PROJECT_LIBRARY_ROOT")
COPY_LIMIT = 50 * 1024 * 1024
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_JSON_DEPTH = 64
MAX_DEPENDENCIES = 4096
REPARSE = 0x400
STAGE_MARKER = ".video-project-library-owned-staging"
PROJECT_MARKER = ".video-project-library-managed-project.json"
LOCK_SUFFIX = ".video-project-library.lock"
WINDOWS_RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL", "CLOCK$",
    *(f"COM{index}" for index in range(1, 10)),
    *(f"LPT{index}" for index in range(1, 10)),
}

REVIEW_DIRS = ["01_项目说明", "02_文案与分镜", "03_图片与封面", "04_配音字幕音乐", "05_预览片", "06_最终成片", "07_问题与修改记录"]
SOURCE_DIRS = ["01_原始视频", "02_原始图片", "03_原始音频", "04_剪辑与时间线工程", "05_字幕与排版", "06_生成过程文件", "07_渲染中间产物", "08_平台发布包", "09_备份与历史版本", "10_项目附属资料"]
MACHINE_DIRS = ["01_项目清单", "02_文件索引", "03_依赖关系", "04_来源与交接", "05_质检报告", "06_日志与维护历史", "历史快照"]

VIDEO = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v", ".mts", ".m2ts"}
IMAGE = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".svg"}
AUDIO = {".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".wma"}
SUBTITLE = {".srt", ".ass", ".ssa", ".vtt", ".lrc"}
EDIT = {".prproj", ".drp", ".fcpxml", ".kdenlive", ".mlt", ".veg", ".capcut", ".aep"}
FONT = {".ttf", ".otf", ".woff", ".woff2"}
DOC = {".txt", ".md", ".docx", ".doc", ".pdf", ".rtf", ".csv", ".xlsx", ".pptx"}
SCRIPT = {".py", ".ps1", ".js", ".mjs", ".cjs", ".bat", ".cmd", ".sh"}
ARCHIVE = {".zip", ".7z", ".rar", ".tar", ".gz", ".bz2", ".xz"}
DATA = {".db", ".sqlite", ".sqlite3", ".bin", ".dat", ".cache", ".npy", ".npz", ".pt", ".pth", ".safetensors"}
CONFIG = {".json", ".jsonl", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".xml"}
BINARY_HELPER = {".dll", ".exe", ".pyd", ".so", ".dylib", ".plugin"}
FORBIDDEN_CLASS_WORDS = ("待分类", "未知", "不明", "其他", "unknown", "unclassified")


class GateError(RuntimeError):
    pass


def dump(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2)


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.{os.urandom(6).hex()}.tmp")
    temp.write_text(dump(data) + "\n", encoding="utf-8")
    try:
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def is_link(path: Path) -> bool:
    try:
        stat = path.lstat()
    except OSError:
        return False
    return path.is_symlink() or bool(getattr(stat, "st_file_attributes", 0) & REPARSE)


def require_absolute(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise GateError(f"{label}必须使用绝对路径: {path}")
    return path


def reject_link_components(path: Path, label: str) -> None:
    absolute = require_absolute(path, label).absolute()
    parts = absolute.parts
    if not parts:
        raise GateError(f"{label}路径为空")
    current = Path(parts[0])
    for part in parts[1:]:
        current = current / part
        if not current.exists():
            continue
        if is_link(current):
            raise GateError(f"{label}路径包含符号链接或重解析点: {current}")


def plain_dir(path: Path, label: str) -> Path:
    require_absolute(path, label)
    reject_link_components(path, label)
    resolved = path.resolve(strict=True)
    if not resolved.is_dir() or is_link(resolved):
        raise GateError(f"{label}不是普通目录: {path}")
    return resolved


def legal_name(value: str) -> str:
    value = value.strip().rstrip(" .")
    if not value or value in {".", ".."} or re.search(r'[<>:"/\\|?*]', value):
        raise GateError("项目名为空或包含 Windows 非法字符")
    if value.split(".", 1)[0].upper() in WINDOWS_RESERVED_NAMES:
        raise GateError(f"项目名是 Windows 保留设备名: {value}")
    return value


def is_within(child: Path, parent: Path) -> bool:
    try:
        child.resolve(strict=False).relative_to(parent.resolve(strict=False))
        return True
    except ValueError:
        return False


def relative_under(child: Path, parent: Path, label: str) -> Path:
    """Return a stable relative path after normalizing Windows long/8.3 aliases."""
    resolved_child = child.resolve(strict=False)
    resolved_parent = parent.resolve(strict=False)
    try:
        return resolved_child.relative_to(resolved_parent)
    except ValueError as exc:
        raise GateError(f"{label}路径不在预期根目录内: {child}") from exc


def safe_child(parent: Path, relative: str | Path, label: str) -> Path:
    value = Path(relative)
    if value.is_absolute() or any(part in {"", ".", ".."} for part in value.parts):
        raise GateError(f"{label}不是安全相对路径: {relative}")
    target = parent / value
    if not is_within(target, parent):
        raise GateError(f"{label}路径越界: {relative}")
    reject_link_components(target, label)
    return target


def ensure_plain_tree(root: Path, label: str) -> None:
    plain_dir(root, label)
    for current, dirs, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in dirs + files:
            candidate = current_path / name
            if is_link(candidate):
                raise GateError(f"{label}包含符号链接或重解析点: {candidate}")


def managed_marker_payload(project: Path) -> dict[str, Any]:
    return {"schema_version": "1.0", "managed_by": "video-project-library-maintainer",
            "project_root": str(project), "project_name": project.name}


def validate_project_marker(project: Path) -> dict[str, Any]:
    marker = project / PROJECT_MARKER
    payload = load_json_object(marker, "受管项目标记")
    expected = managed_marker_payload(project)
    for key, value in expected.items():
        if payload.get(key) != value:
            raise GateError(f"受管项目标记与当前项目不匹配: {key}")
    return payload


@contextlib.contextmanager
def project_lock(project: Path):
    parent = plain_dir(project.parent, "项目父目录")
    lock = parent / f".{project.name}{LOCK_SUFFIX}"
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    try:
        descriptor = os.open(lock, flags, 0o600)
    except FileExistsError as exc:
        raise GateError(f"项目正在被另一个维护进程处理: {lock}") from exc
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(dump({"pid": os.getpid(), "project": str(project)}) + "\n")
        yield
    finally:
        if lock.is_file() and not is_link(lock):
            lock.unlink()


def sniff(path: Path) -> str:
    try:
        with path.open("rb") as handle:
            head = handle.read(64)
    except OSError:
        return "unreadable-file"
    if not head: return "empty-file"
    if head.startswith(b"\x89PNG\r\n\x1a\n"): return "png"
    if head.startswith(b"\xff\xd8\xff"): return "jpeg"
    if head.startswith((b"GIF87a", b"GIF89a")): return "gif"
    if head.startswith(b"RIFF") and head[8:12] == b"WAVE": return "wav"
    if head.startswith(b"RIFF") and head[8:12] == b"WEBP": return "webp"
    if len(head) >= 12 and head[4:8] == b"ftyp": return "iso-media"
    if head.startswith(b"%PDF-"): return "pdf"
    if head.startswith(b"PK\x03\x04"): return "zip-container"
    if head.startswith(b"SQLite format 3\x00"): return "sqlite"
    if head.startswith(b"MZ"): return "windows-binary"
    if b"\x00" not in head: return "text-data"
    return "binary-data"


def has(text: str, *words: str) -> bool:
    return any(word in text for word in words)


def cls(category: str, subcategory: str, basis: list[str], confidence: str = "high", tags: list[str] | None = None, review: str | None = None) -> dict[str, Any]:
    return {"primary_category": category, "subcategory": subcategory, "classification_basis": basis,
            "confidence": confidence, "tags": sorted(set(tags or [])), "review_destination": review}


def classify(relative: Path, signature: str, read_error: str | None) -> dict[str, Any]:
    rel = relative.as_posix().lower()
    name = relative.name.lower()
    ext = relative.suffix.lower()
    basis = [f"extension={ext or '<none>'}", f"signature={signature}"]
    if read_error or signature == "unreadable-file":
        return cls("02_工程源文件/09_备份与历史版本", "损坏或不可读文件", basis + [read_error or "文件不可读"], tags=["read_error"])
    if has(rel, "/_backups/", "/backup/", "/backups/", "/archive/", "/archives/", "备份", "历史版本"):
        return cls("02_工程源文件/09_备份与历史版本", "备份或历史快照", basis + ["路径含备份或历史标记"], tags=["historical"])
    if has(rel, "handoff", "provenance", "来源", "交接"):
        return cls("03_机器清单_勿手改/04_来源与交接", "来源或自动化交接记录", basis + ["路径含来源或交接标记"], tags=["machine_record"])
    media_like = ext in (VIDEO | IMAGE | AUDIO) or signature in {"iso-media", "png", "jpeg", "gif", "webp", "wav"}
    if not media_like and has(rel, "/qa/", "quality", "review", "report", "质检", "审核报告"):
        return cls("03_机器清单_勿手改/05_质检报告", "质检或审核报告", basis + ["路径含质检或报告标记"], tags=["machine_record", "qa"], review="07_问题与修改记录")
    if has(name, "checksum", "sha256", "file-index", "inventory", "文件索引"):
        return cls("03_机器清单_勿手改/02_文件索引", "索引或哈希清单", basis + ["文件名表示索引或哈希"], tags=["machine_record"])
    if has(name, "depend", "binding", "引用", "依赖"):
        return cls("03_机器清单_勿手改/03_依赖关系", "依赖或绑定记录", basis + ["文件名表示依赖或绑定"], tags=["machine_record"])
    if has(name, "manifest", "ledger", "清单", "项目账本"):
        return cls("03_机器清单_勿手改/01_项目清单", "项目或生产清单", basis + ["文件名表示项目清单"], tags=["machine_record"])
    if ext in {".log", ".jsonl"} or has(rel, "/logs/", "/log/", "日志", "history"):
        return cls("03_机器清单_勿手改/06_日志与维护历史", "运行日志或维护历史", basis + ["扩展名或路径表示日志"], tags=["machine_record"])
    if ext in EDIT or has(rel, "timeline", "draft", "project-files", "剪辑工程", "时间线"):
        return cls("02_工程源文件/04_剪辑与时间线工程", "剪辑工程或时间线", basis + ["工程扩展名或路径匹配"], tags=["editable_project"])
    if ext in SUBTITLE | FONT or has(rel, "subtitle", "caption", "typeset", "字幕", "排版", "font"):
        return cls("02_工程源文件/05_字幕与排版", "字幕、字体或排版文件", basis + ["字幕、字体扩展名或路径匹配"], tags=["text_timing"], review="04_配音字幕音乐")
    if ext in VIDEO or signature == "iso-media":
        if has(rel, "proxy", "cache", "intermediate", "render", "stages", "临时", "中间", "预渲染"):
            return cls("02_工程源文件/07_渲染中间产物", "代理、缓存或中间渲染视频", basis + ["视频路径表示中间产物"], tags=["video", "intermediate"])
        if has(rel, "delivery", "platform", "package", "master", "final", "output", "成片", "发布包", "母版"):
            review = "05_预览片" if has(rel, "preview", "预览") else "06_最终成片"
            return cls("02_工程源文件/08_平台发布包", "母版、成片或平台发布视频", basis + ["视频路径表示交付物"], tags=["video", "delivery"], review=review)
        return cls("02_工程源文件/01_原始视频", "原始视频素材", basis + ["视频且无交付或中间产物标记"], "medium", ["video"])
    if ext in IMAGE or signature in {"png", "jpeg", "gif", "webp"}:
        if has(rel, "generation", "generated", "chat-images", "raw-generations", "生图", "生成"):
            return cls("02_工程源文件/06_生成过程文件", "生成式图片或生成过程素材", basis + ["图片路径表示生成过程"], tags=["image", "generated"])
        if has(rel, "render", "reveal", "stage", "frame", "中间", "逐帧"):
            return cls("02_工程源文件/07_渲染中间产物", "渲染帧或阶段图片", basis + ["图片路径表示渲染阶段"], tags=["image", "intermediate"])
        review = "03_图片与封面" if has(rel, "cover", "封面", "poster", "thumbnail") else None
        return cls("02_工程源文件/02_原始图片", "封面或图片素材" if review else "原始图片素材", basis + ["文件头或扩展名表示图片"], tags=["image"], review=review)
    if ext in AUDIO or signature == "wav":
        tags = ["audio"]
        if has(rel, "narration", "voice", "tts", "配音", "旁白"): tags.append("narration")
        if has(rel, "music", "bgm", "音乐"): tags.append("music")
        return cls("02_工程源文件/03_原始音频", "配音、音乐或声音素材", basis + ["文件头或扩展名表示音频"], tags=tags, review="04_配音字幕音乐")
    if has(rel, "script", "storyboard", "shot-plan", "文案", "脚本", "分镜"):
        return cls("02_工程源文件/10_项目附属资料", "文案与分镜资料", basis + ["路径表示文案或分镜"], tags=["document"], review="02_文案与分镜")
    if has(rel, "issue", "feedback", "修改", "问题", "意见"):
        return cls("02_工程源文件/10_项目附属资料", "问题与修改记录", basis + ["路径表示问题或修改记录"], tags=["document"], review="07_问题与修改记录")
    if ext in SCRIPT:
        return cls("02_工程源文件/10_项目附属资料", "自动化工具", basis + ["脚本扩展名匹配"], tags=["automation"])
    if ext in ARCHIVE or signature == "zip-container":
        return cls("02_工程源文件/10_项目附属资料", "压缩归档文件", basis + ["压缩格式或文件头匹配"], tags=["archive"])
    if ext in BINARY_HELPER or signature == "windows-binary":
        return cls("02_工程源文件/10_项目附属资料", "工程辅助二进制文件", basis + ["插件、动态库或可执行文件特征匹配"], tags=["binary_helper"])
    if ext in DATA or signature in {"sqlite", "binary-data", "empty-file"}:
        return cls("02_工程源文件/10_项目附属资料", "工程数据或缓存", basis + ["数据容器、数据库、缓存或二进制内容特征匹配"], "medium", ["project_data"])
    if ext in CONFIG:
        return cls("02_工程源文件/04_剪辑与时间线工程", "工程配置文件", basis + ["配置格式匹配"], "medium", ["configuration"])
    if has(name, "license", "readme", "说明", "许可"):
        return cls("02_工程源文件/10_项目附属资料", "许可证或使用说明", basis + ["文件名表示许可证或说明"], tags=["documentation"], review="01_项目说明")
    if ext in DOC or signature in {"pdf", "text-data"}:
        return cls("02_工程源文件/10_项目附属资料", "项目说明或文本资料", basis + ["文档格式或文本内容特征匹配"], "medium", ["document"], "01_项目说明")
    return cls("02_工程源文件/10_项目附属资料", "工程辅助二进制文件", basis + ["非文本二进制内容；作为工程辅助文件登记并保留原位"], "low", ["binary_helper"])


def scan(source: Path) -> tuple[list[dict[str, Any]], list[str]]:
    ensure_plain_tree(source, "扫描源")
    records, read_errors, seen = [], [], set()
    for root, dirs, files in os.walk(source, followlinks=False):
        root_path = Path(root)
        for dirname in list(dirs):
            if is_link(root_path / dirname):
                raise GateError(f"发现目录链接或重解析点: {root_path / dirname}")
        for filename in files:
            path = root_path / filename
            if is_link(path): raise GateError(f"发现文件链接或重解析点: {path}")
            relative = relative_under(path, source, "扫描文件")
            key = relative.as_posix().casefold()
            if key in seen: raise GateError(f"相对路径重复: {relative}")
            seen.add(key)
            read_error = None
            try:
                before = path.stat(); sha = digest(path); after = path.stat(); size = after.st_size
                if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
                    raise GateError(f"扫描期间文件发生变化: {path}")
                modified = dt.datetime.fromtimestamp(after.st_mtime, dt.timezone.utc).isoformat()
            except OSError as exc:
                read_error = f"{type(exc).__name__}: {exc}"; sha = None; size = None; modified = None
                read_errors.append(f"{relative}: {read_error}")
            signature = sniff(path)
            records.append({"source_path": str(path), "current_path": str(path), "relative_path": relative.as_posix(),
                            "size_bytes": size, "modified_utc": modified, "sha256": sha, "content_signature": signature,
                            "read_error": read_error, **classify(relative, signature, read_error)})
    records.sort(key=lambda item: item["relative_path"].casefold())
    return records, read_errors


def count_files(source: Path) -> int:
    total = 0
    for root, dirs, files in os.walk(source, followlinks=False):
        root_path = Path(root)
        if any(is_link(root_path / name) for name in dirs + files): raise GateError(f"发现链接或重解析点: {root_path}")
        total += len(files)
    return total


def gate(records: list[dict[str, Any]], source_count: int) -> dict[str, Any]:
    errors, paths = [], [item.get("relative_path") for item in records]
    if len(records) != source_count: errors.append(f"源文件数{source_count}与索引数{len(records)}不一致")
    if len(set(paths)) != len(paths): errors.append("索引存在重复相对路径")
    for item in records:
        category = str(item.get("primary_category") or "")
        subcategory = str(item.get("subcategory") or "")
        if not category or not subcategory or any(word in (category + subcategory).lower() for word in FORBIDDEN_CLASS_WORDS):
            errors.append(f"存在非法或空分类: {item.get('relative_path')}")
        if not item.get("classification_basis") or not item.get("confidence"):
            errors.append(f"分类依据或置信度缺失: {item.get('relative_path')}")
    return {"passed": not errors, "errors": errors, "source_file_count": source_count,
            "indexed_file_count": len(records), "category_counts": dict(sorted(Counter(item["primary_category"] for item in records).items())),
            "low_confidence_count": sum(item["confidence"] == "low" for item in records)}


def structure(project: Path) -> list[Path]:
    return ([project / "01_给Codex审核" / "当前正式版" / name for name in REVIEW_DIRS] +
            [project / "01_给Codex审核" / "历史版本"] +
            [project / "02_工程源文件" / name for name in SOURCE_DIRS] +
            [project / "03_机器清单_勿手改" / name for name in MACHINE_DIRS])


def review_target(project: Path, item: dict[str, Any]) -> Path | None:
    folder, size, sha = item.get("review_destination"), item.get("size_bytes"), item.get("sha256")
    if not folder or not isinstance(size, int) or not sha: return None
    if size > COPY_LIMIT and not item.get("required_delivery"): return None
    relative = item.get("review_relative_path")
    if not isinstance(relative, str) or not relative.strip():
        role = str(item.get("source_role") or "engineering")
        source_relative = str(item.get("source_relative_path") or Path(item["source_path"]).name)
        relative = f"当前正式版/{folder}/{role}/{source_relative}"
    target = project / "01_给Codex审核" / Path(relative)
    if not is_within(target, project / "01_给Codex审核"):
        raise GateError(f"审核副本路径越界: {relative}")
    return target


def curated_video_review_destination(item: dict[str, Any]) -> str:
    name = Path(str(item.get("source_path") or "")).stem.casefold()
    relative = str(item.get("source_relative_path") or "").replace("\\", "/").casefold()
    explicit_final = bool(re.search(r"(?:^|[-_. ])final(?:$|[-_. ])", name)) or has(name, "最终", "成片")
    explicit_preview = bool(re.search(r"(?:^|[-_. ])preview(?:$|[-_. ])", name)) or has(name, "预览")
    if explicit_final and not explicit_preview:
        return "06_最终成片"
    if has(relative, "/final/", "/最终成片/", "/成片/") and not explicit_preview:
        return "06_最终成片"
    return "05_预览片"


def assign_curated_destination(item: dict[str, Any], root: Path) -> None:
    category = item["primary_category"]
    source_context = str(root).replace("\\", "/").casefold()
    if "报告" in source_context or "/reports/" in f"/{source_context}/" or "/report/" in f"/{source_context}/":
        item["review_destination"] = "07_问题与修改记录"
    elif "脚本" in source_context or "/scripts/" in f"/{source_context}/" or "/script/" in f"/{source_context}/":
        item["review_destination"] = "02_文案与分镜"
    elif "素材图" in source_context or "/images/" in f"/{source_context}/" or "/visuals/" in f"/{source_context}/":
        item["review_destination"] = "03_图片与封面"
    elif "音频" in source_context or "/audio/" in f"/{source_context}/":
        item["review_destination"] = "04_配音字幕音乐"
    elif category.endswith("/01_原始视频") or category.endswith("/08_平台发布包"):
        item["review_destination"] = curated_video_review_destination(item)
    elif category.endswith("/02_原始图片"):
        item["review_destination"] = "03_图片与封面"
    elif category.endswith("/03_原始音频") or category.endswith("/05_字幕与排版"):
        item["review_destination"] = "04_配音字幕音乐"
    elif category.startswith("03_机器清单_勿手改/05_质检报告"):
        item["review_destination"] = "07_问题与修改记录"
    elif item["subcategory"] == "文案与分镜资料":
        item["review_destination"] = "02_文案与分镜"
    else:
        item["review_destination"] = "01_项目说明"


def scan_source_set(engineering_source: Path, review_sources: list[Path]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[str], int]:
    records, read_errors = scan(engineering_source)
    for item in records:
        original_relative = item["relative_path"]
        item["source_role"] = "engineering"
        item["source_root"] = str(engineering_source)
        item["source_relative_path"] = original_relative
        item["relative_path"] = f"engineering/{original_relative}"
        if review_sources:
            item["review_destination"] = None
    review_records: list[dict[str, Any]] = []
    if review_sources:
        for index, root in enumerate(review_sources, 1):
            role = f"review-{index:02d}"
            batch, errors = scan(root)
            read_errors.extend(f"{role}/{error}" for error in errors)
            for item in batch:
                original_relative = item["relative_path"]
                item["source_role"] = role
                item["source_root"] = str(root)
                item["source_relative_path"] = original_relative
                item["relative_path"] = f"{role}/{original_relative}"
                assign_curated_destination(item, root)
                item["review_relative_path"] = f"当前正式版/{item['review_destination']}/{role}/{original_relative}"
                review_records.append(item)
    else:
        for source_item in records:
            if source_item.get("review_destination"):
                item = dict(source_item)
                item["review_relative_path"] = (
                    f"当前正式版/{item['review_destination']}/{item['source_relative_path']}"
                )
                review_records.append(item)
    records.sort(key=lambda item: item["relative_path"].casefold())
    review_records.sort(key=lambda item: item["relative_path"].casefold())
    return records, review_records, read_errors, count_files(engineering_source)


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file() or is_link(path):
        raise GateError(f"{label}缺失或不是普通文件: {path}")
    reject_link_components(path, label)
    if path.stat().st_size > MAX_JSON_BYTES:
        raise GateError(f"{label}超过 {MAX_JSON_BYTES} 字节上限: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GateError(f"{label}无法读取: {path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise GateError(f"{label}必须是 JSON object: {path}")
    stack: list[tuple[Any, int]] = [(payload, 1)]
    while stack:
        value, depth = stack.pop()
        if depth > MAX_JSON_DEPTH:
            raise GateError(f"{label}嵌套超过 {MAX_JSON_DEPTH} 层: {path}")
        if isinstance(value, dict):
            stack.extend((child, depth + 1) for child in value.values())
        elif isinstance(value, list):
            stack.extend((child, depth + 1) for child in value)
    return payload


def resolve_delivery_file(source: Path, relative: Any, label: str) -> Path:
    if not isinstance(relative, str) or not relative.strip():
        raise GateError(f"{label}路径无效或不是相对路径: {relative!r}")
    path = safe_child(source, relative, label).resolve(strict=False)
    if not path.is_file() or is_link(path):
        raise GateError(f"{label}文件缺失或不是普通文件: {relative}")
    return path


def validate_bound_file(source: Path, label: str, record: Any) -> dict[str, Any]:
    if not isinstance(record, dict):
        raise GateError(f"final-delivery 绑定记录不是 object: {label}")
    path = resolve_delivery_file(source, record.get("path"), label)
    expected = record.get("sha256")
    before = path.stat()
    actual = digest(path)
    after = path.stat()
    if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
        raise GateError(f"final-delivery 绑定在校验期间发生变化: {label}: {record.get('path')}")
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
        raise GateError(f"final-delivery 绑定缺少合法 SHA-256: {label}")
    if actual.casefold() != expected.casefold():
        raise GateError(f"final-delivery 绑定哈希失效: {label}: {record.get('path')}")
    expected_size = record.get("size")
    if not isinstance(expected_size, int) or isinstance(expected_size, bool) or expected_size < 0:
        raise GateError(f"final-delivery 绑定缺少合法非负 size: {label}")
    if expected_size != after.st_size:
        raise GateError(f"final-delivery 绑定大小失效: {label}: {record.get('path')}")
    return {"label": label, "path": path, "relative_path": relative_under(path, source, label).as_posix(),
            "sha256": actual, "size_bytes": after.st_size}


def delivery_sort_key(path: Path, payload: dict[str, Any]) -> tuple[str, str]:
    generated = payload.get("generated_at")
    return (generated if isinstance(generated, str) else "", path.name.casefold())


def select_latest_delivery(source: Path) -> tuple[Path, dict[str, Any]] | None:
    candidates: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted((source / "delivery").glob("final-delivery*.json")) if (source / "delivery").is_dir() else []:
        payload = load_json_object(path, "final-delivery")
        if payload.get("status") == "passed":
            candidates.append((path, payload))
    return max(candidates, key=lambda pair: delivery_sort_key(pair[0], pair[1])) if candidates else None


def validate_latest_delivery(source: Path) -> dict[str, Any]:
    try:
        selected = select_latest_delivery(source)
    except GateError as exc:
        return {"present": True, "passed": False, "errors": [str(exc)], "manifest": None, "entries": []}
    if not selected:
        return {"present": False, "passed": True, "errors": [], "manifest": None, "entries": []}
    path, payload = selected
    errors: list[str] = []
    entries: list[dict[str, Any]] = []
    try:
        entries.append(validate_bound_file(source, "episode_manifest", payload.get("episode_manifest")))
        bindings = payload.get("bindings")
        if not isinstance(bindings, dict) or not bindings:
            raise GateError("final-delivery bindings 为空")
        for label, record in bindings.items():
            entries.append(validate_bound_file(source, str(label), record))
        required_platforms = {"wechat_channels", "douyin", "xiaohongshu", "bilibili"}
        if "platform_package_manifest" in bindings:
            for platform in required_platforms:
                for kind in ("master", "cover"):
                    if f"platform_{platform}_{kind}" not in bindings:
                        errors.append(f"final-delivery 缺少平台绑定: {platform}.{kind}")
    except GateError as exc:
        errors.append(str(exc))
    return {"present": True, "passed": not errors, "errors": errors, "manifest": str(path),
            "manifest_sha256": digest(path), "payload": payload, "entries": entries}


def iter_json_strings(value: Any):
    stack: list[tuple[Any, int]] = [(value, 1)]
    while stack:
        current, depth = stack.pop()
        if depth > MAX_JSON_DEPTH:
            raise GateError(f"依赖 JSON 嵌套超过 {MAX_JSON_DEPTH} 层")
        if isinstance(current, dict):
            stack.extend((child, depth + 1) for child in current.values())
        elif isinstance(current, list):
            stack.extend((child, depth + 1) for child in current)
        elif isinstance(current, str):
            yield current


def discover_delivery_closure(source: Path, seed_entries: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[str]]:
    by_relative = {item["relative_path"].casefold(): dict(item) for item in seed_entries}
    queue = [item for item in by_relative.values() if Path(item["path"]).suffix.casefold() == ".json"]
    errors: list[str] = []
    visited: set[str] = set()
    path_suffixes = VIDEO | IMAGE | AUDIO | SUBTITLE | FONT | DOC | CONFIG | EDIT | ARCHIVE | SCRIPT | DATA | BINARY_HELPER
    while queue:
        if len(by_relative) > MAX_DEPENDENCIES:
            errors.append(f"正式交付依赖超过 {MAX_DEPENDENCIES} 项上限")
            break
        entry = queue.pop(0)
        key = entry["relative_path"].casefold()
        if key in visited:
            continue
        visited.add(key)
        path = Path(entry["path"])
        try:
            payload = load_json_object(path, "当前正式版依赖 JSON")
        except GateError as exc:
            errors.append(str(exc)); continue
        for value in iter_json_strings(payload):
            candidate_value = value.strip()
            if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", candidate_value):
                continue
            candidate_path = Path(candidate_value)
            if not candidate_value or candidate_path.is_absolute():
                continue
            has_separator = "/" in candidate_value or "\\" in candidate_value
            has_file_like_tail = bool(candidate_path.suffix) and has_separator
            explicit_relative = candidate_value.startswith(("./", ".\\", "../", "..\\"))
            if not (candidate_path.suffix.casefold() in path_suffixes or has_file_like_tail or explicit_relative):
                continue
            if any(part == ".." for part in candidate_path.parts):
                errors.append(f"依赖路径越界: {path}: {candidate_value}")
                continue
            options = [(source / candidate_path).resolve(strict=False), (path.parent / candidate_path).resolve(strict=False)]
            resolved = next((item for item in options if is_within(item, source) and item.is_file() and not is_link(item)), None)
            if not resolved:
                errors.append(f"疑似依赖缺失: {path}: {candidate_value}")
                continue
            try:
                reject_link_components(resolved, "正式交付依赖")
            except GateError as exc:
                errors.append(str(exc))
                continue
            relative = relative_under(resolved, source, "正式交付依赖").as_posix()
            relative_key = relative.casefold()
            if relative_key in by_relative:
                continue
            record = {"label": None, "path": resolved, "relative_path": relative,
                      "sha256": digest(resolved), "size_bytes": resolved.stat().st_size}
            by_relative[relative_key] = record
            if len(by_relative) > MAX_DEPENDENCIES:
                errors.append(f"正式交付依赖超过 {MAX_DEPENDENCIES} 项上限")
                break
            if resolved.suffix.casefold() == ".json":
                queue.append(record)
    return sorted(by_relative.values(), key=lambda item: item["relative_path"].casefold()), errors


def official_review_destination(label: str | None, relative: str) -> str:
    rel = relative.casefold()
    label_cf = (label or "").casefold()
    suffix = Path(relative).suffix.casefold()
    if label_cf.startswith("master_") or (label_cf.startswith("platform_") and label_cf.endswith("_master")):
        return "06_最终成片"
    if label_cf.startswith("platform_") and label_cf.endswith("_cover"):
        return "03_图片与封面"
    if label_cf == "platform_package_manifest":
        return "06_最终成片"
    if label_cf.startswith("report_") or "/reports/" in f"/{rel}" or rel.startswith("qa/"):
        return "07_问题与修改记录"
    if suffix in IMAGE or "cover" in rel or "visuals/" in rel or "reveals/" in rel:
        return "03_图片与封面"
    if suffix in AUDIO | SUBTITLE | FONT or rel.startswith("audio/") or rel.startswith("timeline/"):
        return "04_配音字幕音乐"
    if label_cf in {"script", "script_manifest", "plan"} or "script" in rel or "shot-plan" in rel or "storyboard" in rel:
        return "02_文案与分镜"
    if suffix in VIDEO and (rel.startswith("output/") or rel.startswith("platform-packages")):
        return "06_最终成片"
    return "01_项目说明"


def build_review_selection(source: Path, fallback: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    delivery = validate_latest_delivery(source)
    if not delivery["present"]:
        return fallback, delivery
    if not delivery["passed"]:
        return [], delivery
    closure, errors = discover_delivery_closure(source, delivery["entries"])
    if errors:
        delivery["errors"].extend(errors); delivery["passed"] = False
        return [], delivery
    manifest_path = Path(delivery["manifest"])
    closure.append({"label": "final_delivery_manifest", "path": manifest_path,
                    "relative_path": relative_under(manifest_path, source, "final-delivery清单").as_posix(),
                    "sha256": digest(manifest_path), "size_bytes": manifest_path.stat().st_size})
    labels_by_relative = {item["relative_path"].casefold(): item.get("label") for item in delivery["entries"]}
    selected: list[dict[str, Any]] = []
    seen: set[str] = set()
    for entry in closure:
        relative = entry["relative_path"]
        key = relative.casefold()
        if key in seen: continue
        seen.add(key)
        label = entry.get("label") or labels_by_relative.get(key)
        destination = official_review_destination(label, relative)
        selected.append({
            "source_path": str(entry["path"]), "source_root": str(source), "source_role": "current-final-delivery",
            "source_relative_path": relative, "relative_path": f"current-final-delivery/{relative}",
            "size_bytes": entry["size_bytes"], "sha256": entry["sha256"], "review_destination": destination,
            "review_relative_path": f"当前正式版/{destination}/{relative}", "required_delivery": True,
            "delivery_binding_role": label,
        })
    for candidate in sorted((source / "delivery").glob("final-delivery*.json")):
        if candidate.resolve() == manifest_path.resolve():
            continue
        reject_link_components(candidate, "历史交付清单")
        if is_link(candidate):
            raise GateError(f"历史交付清单不能是链接或重解析点: {candidate}")
        selected.append({
            "source_path": str(candidate), "source_root": str(source), "source_role": "historical-delivery",
            "source_relative_path": relative_under(candidate, source, "历史交付清单").as_posix(),
            "relative_path": f"historical-delivery/{candidate.name}", "size_bytes": candidate.stat().st_size,
            "sha256": digest(candidate), "review_destination": "01_项目说明",
            "review_relative_path": f"历史版本/{candidate.stem}/01_项目说明/delivery/{candidate.name}",
            "required_delivery": True, "delivery_binding_role": "historical_final_delivery_manifest",
        })
    return selected, delivery


def public_delivery_gate(delivery: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in delivery.items() if key not in {"payload", "entries"}}


def preview(source: Path, review_sources: list[Path], project: Path, name: str) -> dict[str, Any]:
    records, curated, read_errors, source_count = scan_source_set(source, review_sources)
    check = gate(records, source_count)
    review_files, delivery_gate = build_review_selection(source, curated)
    if not delivery_gate["passed"]:
        check["errors"].extend(delivery_gate["errors"]); check["passed"] = False
    actions = [{"action": "create_directory", "path": str(path)} for path in structure(project)]
    for item in review_files:
        target = review_target(project, item)
        if target: actions.append({"action": "copy_review_file_preserve_hierarchy", "source": item["source_path"], "target": str(target)})
    return {"mode": "preview", "project_name": name, "source_root": str(source),
            "source_roots": [{"role": "engineering", "path": str(source)}] +
                            [{"role": f"review-{index:02d}", "path": str(path)} for index, path in enumerate(review_sources, 1)],
            "project_root": str(project),
            "classification_gate": check, "delivery_gate": public_delivery_gate(delivery_gate),
            "review_mode": "final_delivery" if delivery_gate["present"] else "curated_sources",
            "read_errors": read_errors, "files": records, "review_files": review_files, "planned_actions": actions}


def archive_current(machine: Path, run_id: str) -> Path:
    current = [machine / "01_项目清单/project-manifest.json", machine / "02_文件索引/file-index.json",
               machine / "02_文件索引/checksums.sha256", machine / "03_依赖关系/dependencies.json",
               machine / "04_来源与交接/source-provenance.json",
               machine / "04_来源与交接/automation-handoff.json",
               machine / "05_质检报告/classification-qc.json"]
    existing = [path for path in current if path.exists()]
    snapshot = machine / "历史快照" / run_id; snapshot.mkdir(parents=True, exist_ok=False)
    for path in existing: shutil.copy2(path, snapshot / path.name)
    return snapshot


def tree_hashes(root: Path) -> dict[str, str]:
    if not root.is_dir():
        return {}
    ensure_plain_tree(root, "哈希目录")
    return {
        relative_under(path, root, "哈希文件").as_posix(): digest(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def build_review_tree(stage_project: Path, final_project: Path, items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    for folder in REVIEW_DIRS:
        (stage_project / "01_给Codex审核" / "当前正式版" / folder).mkdir(parents=True, exist_ok=True)
    (stage_project / "01_给Codex审核" / "历史版本").mkdir(parents=True, exist_ok=True)
    copied: list[dict[str, Any]] = []
    for item in items:
        target = review_target(stage_project, item)
        if not target:
            continue
        source = Path(item["source_path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        if digest(target) != item["sha256"]:
            raise GateError(f"审核副本哈希不一致: {target}")
        final_target = final_project / "01_给Codex审核" / Path(item["review_relative_path"])
        copied.append({
            "source": str(source), "source_relative_path": item.get("source_relative_path"),
            "target": str(final_target), "review_relative_path": item["review_relative_path"],
            "sha256": item["sha256"], "size_bytes": item["size_bytes"],
            "delivery_binding_role": item.get("delivery_binding_role"), "status": "copied",
        })
    return copied


def remove_owned_stage(project: Path, stage_project: Path) -> None:
    project = project.resolve(strict=True)
    stage_project = stage_project.absolute()
    marker = stage_project / STAGE_MARKER
    if (
        stage_project.parent.resolve() != project
        or not stage_project.name.startswith((".transaction-staging-", ".transaction-backup-"))
        or is_link(stage_project)
        or not marker.is_file()
        or is_link(marker)
        or marker.read_text(encoding="utf-8") != stage_project.name
    ):
        raise GateError(f"拒绝清理未标记或越界的暂存目录: {stage_project}")
    shutil.rmtree(stage_project)  # noqa: SEC-AUDITOR -- marker-verified staging child of the project root


def remove_owned_sibling_stage(parent: Path, stage: Path, expected_prefix: str) -> None:
    parent = parent.resolve(strict=True)
    stage = stage.absolute()
    marker = stage / STAGE_MARKER
    if (
        stage.parent.resolve() != parent
        or not stage.name.startswith(expected_prefix)
        or is_link(stage)
        or not marker.is_file()
        or is_link(marker)
        or marker.read_text(encoding="utf-8") != stage.name
    ):
        raise GateError(f"拒绝清理未标记或越界的新工程暂存目录: {stage}")
    shutil.rmtree(stage)  # noqa: SEC-AUDITOR -- marker-verified unique staging child of the managed projects directory


def assert_source_snapshot(source: Path, payload: dict[str, Any]) -> None:
    current, _ = scan(source)
    expected = {
        str(item["source_relative_path"]): (item.get("sha256"), item.get("size_bytes"))
        for item in payload["files"] if item.get("source_role") == "engineering"
    }
    actual = {item["relative_path"]: (item.get("sha256"), item.get("size_bytes")) for item in current}
    if expected != actual:
        raise GateError("源工程在预演后、写入前发生变化；请重新预演")


def copy_existing_tree(source: Path, target: Path, label: str) -> None:
    if source.exists():
        ensure_plain_tree(source, label)
        shutil.copytree(source, target)
    else:
        target.mkdir(parents=True)


def write_staged_state(stage: Path, final_project: Path, source: Path, name: str,
                       payload: dict[str, Any], run_id: str) -> tuple[dict[str, Any], str]:
    copied = build_review_tree(stage, final_project, payload["review_files"])
    source_root = stage / "02_工程源文件"
    machine = stage / "03_机器清单_勿手改"
    for folder in SOURCE_DIRS:
        (source_root / folder).mkdir(parents=True, exist_ok=True)
    for folder in MACHINE_DIRS:
        (machine / folder).mkdir(parents=True, exist_ok=True)
    snapshot = archive_current(machine, run_id)
    source_note = source_root / "10_项目附属资料/原工程位置.txt"
    source_note.write_text("\n".join(f"{item['role']}: {item['path']}" for item in payload["source_roots"]) + "\n", encoding="utf-8")
    previous_review = final_project / "01_给Codex审核"
    review_update = "unchanged" if previous_review.is_dir() and tree_hashes(previous_review) == tree_hashes(stage / "01_给Codex审核") else "replaced"
    manifest = {"schema_version": "2.1", "project_name": name, "source_root": str(source), "library_project_root": str(final_project),
                "source_roots": payload["source_roots"], "mode": "registered_without_moving_source", "run_id": run_id,
                "classification_gate": payload["classification_gate"],
                "delivery_gate": payload["delivery_gate"],
                "review_mode": payload["review_mode"], "review_update": review_update,
                "review_copies": copied}
    write_json(machine / "01_项目清单/project-manifest.json", manifest)
    write_json(machine / "02_文件索引/file-index.json", {"schema_version": "2.1", "run_id": run_id,
               "engineering_source_file_count": payload["classification_gate"]["source_file_count"], "files": payload["files"]})
    (machine / "02_文件索引/checksums.sha256").write_text("".join(f"{x['sha256']}  {x['relative_path']}\n" for x in payload["files"] if x.get("sha256")), encoding="utf-8")
    write_json(machine / "03_依赖关系/dependencies.json", {"schema_version": "2.1", "run_id": run_id, "source_root": str(source),
               "source_rewritten": False, "current_final_delivery": payload["delivery_gate"].get("manifest"),
               "current_final_delivery_sha256": payload["delivery_gate"].get("manifest_sha256")})
    write_json(machine / "04_来源与交接/source-provenance.json", {
        "schema_version": "2.1", "run_id": run_id, "source_roots": payload["source_roots"],
        "registration_mode": "index_complete_source_and_copy_curated_review_files", "source_rewritten": False})
    write_json(machine / "04_来源与交接/automation-handoff.json", {
        "schema_version": "2.1", "run_id": run_id, "project_name": name,
        "refresh_command": "maintain_video_library.py refresh --project-root <project-root>",
        "verify_command": "maintain_video_library.py verify --project-root <project-root>",
        "human_review_root": str(final_project / "01_给Codex审核"), "machine_index_root": str(final_project / "03_机器清单_勿手改")})
    write_json(machine / "05_质检报告/classification-qc.json", {
        "schema_version": "2.1", "run_id": run_id, "classification_gate": payload["classification_gate"],
        "delivery_gate": payload["delivery_gate"], "read_errors": payload["read_errors"],
        "review_copy_count": len(copied), "review_update": review_update,
        "automated_qc": "passed", "human_acceptance": "not_recorded_by_library"})
    history = machine / "06_日志与维护历史/maintenance-history.jsonl"
    with history.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"run_id": run_id, "action": "register_or_refresh", "gate": payload["classification_gate"],
                                 "delivery_gate": payload["delivery_gate"].get("passed"),
                                 "review_copy_count": len(copied), "review_update": review_update}, ensure_ascii=False) + "\n")
    return manifest, review_update


def promote_transaction(project: Path, stage: Path, run_id: str) -> None:
    backup = project / f".transaction-backup-{run_id}"
    backup.mkdir()
    (backup / STAGE_MARKER).write_text(backup.name, encoding="utf-8")
    promoted: list[str] = []
    moved_old: list[str] = []
    try:
        for name in ("01_给Codex审核", "02_工程源文件", "03_机器清单_勿手改"):
            current = project / name
            staged = stage / name
            if current.exists():
                os.replace(current, backup / name)
                moved_old.append(name)
            os.replace(staged, current)
            promoted.append(name)
    except Exception:
        for name in reversed(promoted):
            current = project / name
            if current.exists():
                os.replace(current, stage / name)
        for name in reversed(moved_old):
            archived = backup / name
            if archived.exists():
                os.replace(archived, project / name)
        if all(not (backup / name).exists() for name in ("01_给Codex审核", "02_工程源文件", "03_机器清单_勿手改")):
            remove_owned_stage(project, backup)
        raise
    remove_owned_stage(project, backup)
    (stage / STAGE_MARKER).unlink()
    stage.rmdir()


def apply_project(project: Path, source: Path, name: str, payload: dict[str, Any]) -> dict[str, Any]:
    if not payload["classification_gate"]["passed"]:
        raise GateError("分类门控未通过")
    run_id = dt.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f")
    assert_source_snapshot(source, payload)
    project_existed = project.exists()
    with project_lock(project):
        if project_existed:
            project = plain_dir(project, "资料库项目")
            validate_project_marker(project)
        else:
            project.mkdir()
            write_json(project / PROJECT_MARKER, managed_marker_payload(project))
        stage = project / f".transaction-staging-{run_id}"
        try:
            stage.mkdir()
            (stage / STAGE_MARKER).write_text(stage.name, encoding="utf-8")
            copy_existing_tree(project / "02_工程源文件", stage / "02_工程源文件", "工程源文件区")
            copy_existing_tree(project / "03_机器清单_勿手改", stage / "03_机器清单_勿手改", "机器清单区")
            manifest, _ = write_staged_state(stage, project, source, name, payload, run_id)
            assert_source_snapshot(source, payload)
            promote_transaction(project, stage, run_id)
            return manifest
        except Exception:
            if stage.exists():
                remove_owned_stage(project, stage)
            if not project_existed and project.exists():
                marker = project / PROJECT_MARKER
                if marker.is_file() and len(list(project.iterdir())) == 1:
                    marker.unlink()
                    project.rmdir()
            raise


def load_manifest(project: Path) -> dict[str, Any]:
    validate_project_marker(project)
    path = project / "03_机器清单_勿手改/01_项目清单/project-manifest.json"
    payload = load_json_object(path, "项目清单")
    if payload.get("project_name") != project.name:
        raise GateError("项目清单中的项目名与目录名不一致")
    if payload.get("library_project_root") != str(project):
        raise GateError("项目清单中的项目根目录与当前目录不一致")
    roots = payload.get("source_roots")
    if (not isinstance(roots, list) or not roots or not all(isinstance(item, dict) for item in roots)
            or roots[0].get("role") != "engineering"):
        raise GateError("项目清单缺少合法 source_roots")
    if roots[0].get("path") != payload.get("source_root"):
        raise GateError("项目清单中的工程源关系不一致")
    return payload


def init_library(args: argparse.Namespace) -> dict[str, Any]:
    library_input = require_absolute(Path(args.library_root), "资料库")
    shortcut_input = require_absolute(Path(args.desktop_shortcut), "桌面快捷方式")
    reject_link_components(library_input, "资料库")
    reject_link_components(shortcut_input.parent, "快捷方式父目录")
    library = library_input.resolve(strict=False); shortcut = shortcut_input.resolve(strict=False)
    plain_dir(library.parent, "资料库父目录")
    plain_dir(shortcut.parent, "快捷方式父目录")
    if shortcut.suffix.casefold() != ".lnk":
        raise GateError("桌面快捷方式必须使用 .lnk 扩展名")
    data = {"mode": "preview", "action": "init-library", "library_root": str(library), "desktop_shortcut": str(shortcut),
            "planned_actions": [{"action": "create_directory", "path": str(library / "项目")},
                                {"action": "create_directory", "path": str(library / "资料库管理")},
                                {"action": "create_shortcut", "path": str(shortcut), "target": str(library)}]}
    if args.apply:
        library_existed = library.exists()
        created: list[Path] = []
        try:
            for target in (library, library / "项目", library / "资料库管理"):
                if not target.exists():
                    target.mkdir()
                    created.append(target)
                elif not target.is_dir() or is_link(target):
                    raise GateError(f"资料库目标不是普通目录: {target}")
            shell = shutil.which("pwsh") or shutil.which("powershell")
            if not shell: raise GateError("未找到 PowerShell")
            helper = Path(__file__).with_name("create_desktop_shortcut.ps1")
            subprocess.run([shell, "-NoProfile", "-NonInteractive", "-File", str(helper), "-ShortcutPath", str(shortcut), "-TargetPath", str(library)], check=True)
            data["mode"] = "applied"
        except Exception:
            for target in reversed(created):
                if target.is_dir() and not any(target.iterdir()):
                    target.rmdir()
            if not library_existed and library.exists() and not any(library.iterdir()):
                library.rmdir()
            raise
    return data


def new_project(args: argparse.Namespace) -> dict[str, Any]:
    library = plain_dir(Path(args.library_root), "资料库"); project = library / "项目" / legal_name(args.project_name)
    plain_dir(library / "项目", "项目目录")
    if project.exists(): raise GateError(f"项目已存在: {project}")
    data = {"mode": "preview", "action": "new-project", "project_root": str(project), "planned_actions": [{"action": "create_directory", "path": str(p)} for p in structure(project)]}
    if args.apply:
        run_id = dt.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f")
        with project_lock(project):
            stage = project.parent / f".{project.name}.new-project-{run_id}"
            if stage.exists():
                raise GateError(f"新工程暂存目录已存在: {stage}")
            try:
                stage.mkdir()
                (stage / STAGE_MARKER).write_text(stage.name, encoding="utf-8")
                for path in structure(stage):
                    path.mkdir(parents=True, exist_ok=False)
                (stage / STAGE_MARKER).unlink()
                write_json(stage / PROJECT_MARKER, managed_marker_payload(project))
                os.replace(stage, project)
            except Exception:
                if stage.exists():
                    if not (stage / STAGE_MARKER).exists():
                        (stage / STAGE_MARKER).write_text(stage.name, encoding="utf-8")
                    remove_owned_sibling_stage(project.parent, stage, f".{project.name}.new-project-")
                raise
        data["mode"] = "applied"
    return data


def register(args: argparse.Namespace) -> dict[str, Any]:
    source = plain_dir(Path(args.source), "源工程"); library = plain_dir(Path(args.library_root), "资料库")
    plain_dir(library / "项目", "项目目录")
    review_sources = [plain_dir(Path(path), "审核源") for path in (getattr(args, "review_source", None) or [])]
    name = legal_name(args.project_name or source.name); project = library / "项目" / name
    if is_within(source, project) or is_within(project, source): raise GateError("源工程与登记目录不能互相包含")
    if len({str(path).casefold() for path in review_sources}) != len(review_sources): raise GateError("审核源重复")
    if any(is_within(path, project) or is_within(project, path) for path in review_sources): raise GateError("审核源与登记目录不能互相包含")
    if project.exists():
        project = plain_dir(project, "资料库项目")
        validate_project_marker(project)
    data = preview(source, review_sources, project, name)
    if args.apply: data["manifest"] = apply_project(project, source, name, data); data["mode"] = "applied"
    return data


def refresh(args: argparse.Namespace) -> dict[str, Any]:
    project = plain_dir(Path(args.project_root), "资料库项目"); manifest = load_manifest(project)
    source = plain_dir(Path(manifest["source_root"]), "源工程")
    review_sources = [plain_dir(Path(item["path"]), "审核源") for item in manifest.get("source_roots", []) if item.get("role", "").startswith("review-")]
    data = preview(source, review_sources, project, manifest["project_name"])
    if args.apply: data["manifest"] = apply_project(project, source, manifest["project_name"], data); data["mode"] = "applied"
    return data


def verify(args: argparse.Namespace) -> dict[str, Any]:
    project = plain_dir(Path(args.project_root), "资料库项目"); manifest = load_manifest(project)
    source = plain_dir(Path(manifest["source_root"]), "源工程")
    review_sources = [plain_dir(Path(item["path"]), "审核源") for item in manifest.get("source_roots", []) if item.get("role", "").startswith("review-")]
    records, curated, read_errors, source_count = scan_source_set(source, review_sources); check = gate(records, source_count)
    review_files, delivery_gate = build_review_selection(source, curated)
    if not delivery_gate["passed"]:
        check["errors"].extend(delivery_gate["errors"]); check["passed"] = False
    index_path = project / "03_机器清单_勿手改/02_文件索引/file-index.json"
    prior = load_json_object(index_path, "文件索引") if index_path.is_file() else {"files": []}
    old = {x["relative_path"]: x.get("sha256") for x in prior.get("files", [])}; new = {x["relative_path"]: x.get("sha256") for x in records}
    changes = {"added": sorted(set(new) - set(old)), "missing": sorted(set(old) - set(new)),
               "changed": sorted(p for p in set(old) & set(new) if old[p] != new[p])}
    index_ok = not any(changes.values())
    expected: dict[str, str] = {}
    for item in review_files:
        target = review_target(project, item)
        if target and str(item.get("review_relative_path", "")).startswith("当前正式版/"):
            expected[relative_under(target, project / "01_给Codex审核", "审核目标").as_posix()] = item["sha256"]
    current_root = project / "01_给Codex审核/当前正式版"
    if current_root.is_dir():
        ensure_plain_tree(current_root, "当前审核视图")
    actual = {
        relative_under(path, project / "01_给Codex审核", "审核文件").as_posix(): digest(path)
        for path in current_root.rglob("*") if path.is_file()
    } if current_root.is_dir() else {}
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    changed_review = sorted(path for path in set(expected) & set(actual) if expected[path] != actual[path])
    review_gate = {"passed": not (missing or extra or changed_review), "missing": missing,
                   "extra": extra, "changed": changed_review, "expected_file_count": len(expected),
                   "actual_file_count": len(actual)}
    source_note = project / "02_工程源文件/10_项目附属资料/原工程位置.txt"
    source_recorded = source_note.is_file() and str(source) in source_note.read_text(encoding="utf-8-sig")
    ok = check["passed"] and index_ok and delivery_gate["passed"] and review_gate["passed"] and source_recorded
    return {"ok": ok, "classification_gate": check, "delivery_gate": public_delivery_gate(delivery_gate),
            "review_gate": review_gate, "source_matches_latest_index": index_ok, "source_location_recorded": source_recorded,
            "changes": changes, "read_errors": read_errors}


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="安全维护视频工程资料库；默认只预演。")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("init-library"); p.add_argument("--library-root", default=DEFAULT_LIBRARY, required=not DEFAULT_LIBRARY); p.add_argument("--desktop-shortcut", required=True); p.add_argument("--apply", action="store_true")
    p = sub.add_parser("new-project"); p.add_argument("--library-root", default=DEFAULT_LIBRARY, required=not DEFAULT_LIBRARY); p.add_argument("--project-name", required=True); p.add_argument("--apply", action="store_true")
    p = sub.add_parser("register"); p.add_argument("--source", required=True); p.add_argument("--review-source", action="append", default=[]); p.add_argument("--project-name"); p.add_argument("--library-root", default=DEFAULT_LIBRARY, required=not DEFAULT_LIBRARY); p.add_argument("--apply", action="store_true")
    p = sub.add_parser("refresh"); p.add_argument("--project-root", required=True); p.add_argument("--apply", action="store_true")
    p = sub.add_parser("verify"); p.add_argument("--project-root", required=True)
    return parser


def main() -> int:
    args = make_parser().parse_args()
    try:
        data = {"init-library": init_library, "new-project": new_project, "register": register, "refresh": refresh, "verify": verify}[args.command](args)
        print(dump(data)); return 0 if args.command != "verify" or data["ok"] else 2
    except (GateError, OSError, ValueError, KeyError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print(dump({"ok": False, "error": f"{type(exc).__name__}: {exc}"}), file=sys.stderr); return 1


if __name__ == "__main__": raise SystemExit(main())
