---
name: zhuomian-zhengli
description: 当用户明确要求“整理桌面”“清理桌面”“桌面图标分区”或修复桌面布局时，安全盘点、清理、分类并按空间分区排列 Windows 桌面图标。默认保持文件位于桌面根目录；仅提及某个桌面文件或应用时不要调用。
---

# 桌面整理

盘点或调整桌面前读取 [安全与权限](references/security-and-permissions.md)。

Organize the Windows desktop by icon position rather than by creating classification folders. Preserve the user's files, spatial familiarity, and requested semantic relationships. The included scripts require Windows 10/11 and PowerShell 7 (`pwsh`).

## Boundaries

- Start read-only. Inventory the live Shell desktop before planning or changing anything.
- Do not create classification folders, move files into folders, rename items, modify file contents, uninstall software, clear the Recycle Bin, or change wallpaper/theme/display settings unless the user separately asks for that action.
- Pre-existing filesystem folders may move when doing so is necessary for the requested result. Treat virtual desktop items as fixed unless the user explicitly authorizes moving them.
- Preserve spatial familiarity by default: start from the live coordinates, keep unaffected icons in place, and move the smallest practical set by the shortest practical distance. Do not perform a broad reflow merely to make the desktop more regular or alphabetical.
- Never infer deletion permission from a request to arrange icons. Read [references/cleanup-policy.md](references/cleanup-policy.md) when cleanup or deletion is requested.
- Require explicit user authorization immediately before applying icon coordinates or moving deletion candidates to the Recycle Bin. A previous approval, a general request to "tidy the desktop," or possession of an execution token is not current authorization for a different plan.
- Use complete Shell parsing paths/PIDLs for identity. Never identify items by display name or cached ListView index.
- Do not use `LVM_SETITEMPOSITION32`, sequential index-based repair, or mouse dragging for the final layout.
- Treat inventories, plans, rollback snapshots, and screenshots as private local artifacts because they can reveal filenames, coordinates, applications, and monitor layout. Keep them outside the Skill directory and any public repository unless the user explicitly asks to share a reviewed, redacted copy.

## Workflow

1. Run `scripts/desktop_shell_layout.ps1 -Mode Inventory` with `pwsh` and save the JSON inventory in a user-approved private task directory outside the Skill and public repository. This is read-only. The script refuses to overwrite an existing output file.
2. Classify every visible item exactly once. Re-inventory after any approved deletion; never reuse a stale plan.
3. Build a complete plan using the schema in [references/plan-schema.md](references/plan-schema.md). Base zones on the detected work area and icon spacing, not hard-coded coordinates. Every moved item must have a concrete `moveReason`; unchanged items keep their live coordinates.
4. Apply semantic proximity before alphabetical ordering. Read [references/layout-principles.md](references/layout-principles.md). If the user maintains a private desktop profile outside the Skill directory, read it only as a dated hint rather than current truth; `references/desktop-profile.example.md` documents the safe schema and contains no real coordinates.
5. Run `scripts/validate_layout_plan.ps1` against the live inventory. Stop on missing/extra items, unexplained moves, duplicate targets, moved fixed items, out-of-bounds targets, failed semantic constraints, or an unauthorized large reflow.
6. Show the user the exact plan identity or path, category counts, moved-item count, moved-folder count, total grid-cell displacement, movement-budget result, deletion candidates, and major spatial plan. Obtain current authorization for that exact mutation plan. If the budget is exceeded, explain why the broad reflow is necessary and obtain separate authorization for it.
7. Apply all coordinates in one Shell `IFolderView.SelectAndPositionItems` call with `scripts/desktop_shell_layout.ps1 -Mode Apply`. Use `APPLY-ICON-LAYOUT` for a confirmed within-budget change; use `APPLY-LARGE-REFLOW` only after the user explicitly approves the reported broad change. Save the new rollback snapshot to a private, user-approved path. The script refuses to overwrite it and automatically attempts rollback on coordinate mismatch or Explorer restart.
8. Verify by full parsing path and `IFolderView.GetItemPosition`. Then, when a screenshot is available and the user permits capturing the visible desktop, keep it private and perform the visual checks in [references/layout-principles.md](references/layout-principles.md).

## Stop Conditions

Stop without mutation if auto-arrange is enabled, the desktop item count or path set changed, any move lacks a concrete reason, the default movement budget is exceeded without separate large-reflow authorization, target coordinates collide, a requested semantic relationship fails, Explorer restarts before verification, or a deletion candidate lacks evidence.

If rollback also fails, report the exact snapshot path and mismatches. Do not continue with piecemeal repair.

## Final Report

Report category counts; moved-item and moved-folder counts; total and maximum grid-cell displacement; whether the default movement budget was exceeded or separately authorized; cleaned, retained, and recoverable items; PIDL/path mismatches; coordinate mismatches; fixed-item errors; semantic-constraint results; Explorer restart state; rollback state; and visual-review outcome. Do not claim success unless every required check passes.
