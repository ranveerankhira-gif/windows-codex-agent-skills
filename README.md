# Windows 与 Codex 本地工具 Skills

**让 Codex 帮你整理 Windows，但每一步先预览、再确认、还能回退。**

这里有 6 个中文优先的本地 Agent Skills，用于磁盘清理、桌面布局、文件副本命名、Codex 任务整理和本地视频资料库维护。它们全部显式调用，不会因为一句宽泛指令就擅自移动、覆盖或删除文件。

> 6 explicit-only Codex skills for safer Windows cleanup, bounded desktop automation, task organization, and local file-library workflows.

[![Skills](https://img.shields.io/badge/skills-6-2563eb)](#skill-目录)
[![Latest release](https://img.shields.io/github/v/release/ranveerankhira-gif/windows-codex-agent-skills?label=release)](https://github.com/ranveerankhira-gif/windows-codex-agent-skills/releases/latest)
[![Validate](https://github.com/ranveerankhira-gif/windows-codex-agent-skills/actions/workflows/validate.yml/badge.svg)](https://github.com/ranveerankhira-gif/windows-codex-agent-skills/actions/workflows/validate.yml)
[![Explicit only](https://img.shields.io/badge/invocation-explicit--only-d97706)](#共同安全边界)
[![License: MIT](https://img.shields.io/badge/license-MIT-16a34a)](LICENSE)

## 30 秒找到适合你的 Skill

| 你现在想做什么 | 使用哪个 Skill |
|---|---|
| 查清磁盘空间被什么占用，再决定是否清理 | [`windows-storage-cleanup`](skills/windows-storage-cleanup) |
| 整理桌面图标，但不移动真实文件 | [`zhuomian-zhengli`](skills/zhuomian-zhengli) |
| 给 AI 输出副本生成易读中文名称，并保留撤销能力 | [`ai-output-renamer`](skills/ai-output-renamer) |
| 维护本地视频工程索引 | [`video-project-library-maintainer`](skills/video-project-library-maintainer) |
| 批量整理 Codex 侧栏任务名称 | [`codex-task-renamer`](skills/codex-task-renamer) |
| 必须操作桌面应用，且没有更可靠的 API 或 CLI | [`diannao-kongzhi`](skills/diannao-kongzhi) |

**立即使用：**前往 [最新 Release](https://github.com/ranveerankhira-gif/windows-codex-agent-skills/releases/latest)，按需下载单个 Skill，并用同一页面的 `SHA256SUMS.txt` 核对文件。

## 为什么建立这个仓库

本地自动化最大的风险不是“不会做”，而是做得太快：没有预览就移动文件、没有确认就清理磁盘、把示例路径写成真实路径，或让宽泛触发词悄悄控制桌面。

本仓库的六个Skill全部采用显式调用，并把盘点、计划、确认、执行和验收分开。安装Skill不等于授权执行删除、覆盖、桌面控制或账号修改。

## Skill 目录

| Skill | 用途 | 平台 |
|---|---|---|
| `diannao-kongzhi` | 通过用户预先审查并锁定哈希的受限包装器操作Windows桌面应用 | Windows |
| `windows-storage-cleanup` | 盘点磁盘占用，按风险分级并在确认后安全清理 | Windows |
| `zhuomian-zhengli` | 盘点、规划和调整Windows桌面图标布局 | Windows |
| `ai-output-renamer` | 对AI输出副本库生成中文语义名称，并提供事务与撤销保护 | Windows |
| `video-project-library-maintainer` | 登记、分类、索引和审计本地视频工程资料库 | Windows／跨平台 |
| `codex-task-renamer` | 先预览、经确认后批量修改Codex侧栏任务标题 | Codex环境 |

## 安装

正式版本请从 [GitHub Releases](https://github.com/ranveerankhira-gif/windows-codex-agent-skills/releases/latest) 下载，并核对同一版本中的 `SHA256SUMS.txt`。

### 安装单个Skill

1. 下载`<skill-name>-<version>.zip`并核对SHA-256。
2. 解压后先阅读`SKILL.md`、`agents/openai.yaml`、脚本和权限说明。
3. 把完整Skill目录复制到公共目录，例如：

   ```text
   C:\Users\<你的用户名>\.agents\skills\<skill-name>
   ```

4. 如果目标目录已有同名Skill，先逐文件比较，不要静默覆盖。
5. 重启Codex后，通过`$skill-name`显式调用。

整套下载文件名为`windows-codex-agent-skills-v0.1.1.zip`。建议只安装确实需要的Skill。

## 共同安全边界

- 六个Skill全部设置`allow_implicit_invocation: false`。
- 默认先做只读盘点或展示完整计划；高影响操作必须再次确认。
- 不处理密码、Token、付款、UAC、安全桌面或绕过权限。
- 示例配置只允许虚构值；真实路径、账号表和私人数据必须留在仓库外。
- 不自动下载第三方软件，不静默更新已有工具，不把安装解释为运行授权。
- 删除和覆盖操作必须限制在经过验证的明确目标内，并尽量保留恢复路径。

详细权限见各Skill的`references/security-and-permissions.md`，以及仓库的[安全政策](SECURITY.md)、[目录](catalog.json)和[来源审计](provenance.json)。

## 依赖说明

部分Skill需要用户自行准备并审查外部工具，例如WizTree或受限Windows UI Automation包装器。仓库不捆绑这些第三方程序，也不自动安装它们。

## 开发与验证

```powershell
python -X utf8 scripts/build_catalog.py
python -X utf8 scripts/validate_repo.py
python -X utf8 scripts/package_release.py --release all --verify-only
python -X utf8 -m unittest discover -s scripts/tests -v
```

---

如果你也希望本地自动化“先把计划摆在桌上，再碰文件”，欢迎点一个 ⭐，让更多 Windows 用户看到这套安全边界。

