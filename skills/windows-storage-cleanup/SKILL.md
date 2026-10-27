---
name: windows-storage-cleanup
description: >
  Safely inspect and reclaim Windows disk space using WizTree or native tools, with risk classification,
  active-process protection, duplicate and backup verification, Recycle Bin staging, and post-cleanup checks.
  Use when the user explicitly invokes this skill to audit a Windows drive, review exact cleanup candidates,
  verify duplicate or backup safety, perform an approved cleanup batch, or inspect pagefile space usage.
---

# Windows 存储空间清理

扫描或清理前读取 [安全与权限](references/security-and-permissions.md)。

查明占用，展示具体候选，按已有准确授权完成本批清理，核对实际释放量。下列流程按任务使用；执行专项操作前读取对应参考章节，不为普通占用查询加载全部资料。

## 范围与授权

先读取当前任务、文件和相关应用状态，只复用当前任务内仍然准确、范围未变的目标盘、保护范围和清单。“清理某盘”先形成候选，不等于批准删除一切；准确授权覆盖同批处理及必要验证，仅新增范围、改变处理方式或无法自行查明的实质问题需要用户决定。

只读扫描只读取容量、目录大小、文件元数据和已有材料；不调用应用维护接口，不移动文件、卸载软件或修改设置。明确要求某个应用的历史审查时，按下方专项入口处理。

## 工作流程

### 1. 查明占用

记录当前容量、可用空间和时间；有 WizTree 时优先用它发现热点，再用范围受限的原生命令调查。从大目录逐步缩小范围，避免无边界递归或海量输出。

- 容量读取见 [容量快照](references/windows-and-wiztree.md#read-only-capacity-snapshot)。
- 使用 WizTree 前读 [导出核验](references/windows-and-wiztree.md#wiztree-export-validation)，核验 CSV 实际内容而非只看退出码。大表使用现有 [流式汇总脚本](scripts/Summarize-WizTreeCsv.ps1)，保留 `-Roots`、`-Top` 接口。

### 2. 判断候选

处理具体候选前读 [风险分类](references/risk-classification.md)，保留四类名称：`official-cleanup-only`、`low-risk-after-preapproval`、`confirm-as-a-group`、`protected`。分类本身不增加批准轮次；软件残留需核对安装归属、共享依赖及用户数据，不能凭名称或没有活动进程认定。

以保留副本为删除依据，或涉及个人、科研文件时，先读 [副本与云端核验](references/backup-verification.md)。核对大小、SHA-256、必要成员、保留副本可读性、项目版本及备份／同步／占位符语义；同名、同大小或云端列表不足以认定可删。

普通清理优先处理占用大且确定无用的内容。明确要求稳定释放或解决反复占满时，按 [稳定释放与增长治理](references/risk-classification.md#stable-reclaim-and-recurring-growth) 判断；一次清理不自动扩展为长期配置调整。

### 3. 展示清单

按来源和用途用关键词分点，每组写明 **位置、大小、理由、处理方式、能否恢复、预计能否实际释放空间**。不明项说明具体缺口，副本给出核验结果，可重建缓存说明重建依据，无需额外备份。

- 个人及科研文件默认回收，回收暂存通常仍占原盘空间。
- 已核实缓存和卸载残留按清单采用官方清理、直接删除或回收，提前说明恢复限制。
- 本批回收条目的永久删除可明确纳入同一次授权；只批准回收时保留，整个回收站需授权覆盖全部内容。

### 4. 执行与保护

保护正在进行的工作、源码、用户历史、原始实验数据、唯一归档及活动应用数据；从本地规则和文件系统确认科研根目录。每次操作前复核绝对路径及批准根目录、类型、大小、修改时间、适用的哈希、文件数量、项目与依赖状态、必要副本及恢复方式。

优先安全的后台及官方接口，保留用户窗口和运行任务，不为清理强停应用、重启服务或抢占焦点。文件锁定、归属不明、路径穿越、重解析点异常或内容变化时保留该项，继续独立的已授权项。专项操作前读取：

- **应用历史**：[在线审查与清理](references/windows-and-wiztree.md#application-history-cleanup)，区分扫描、prepare 与 purge，处理忙碌状态及候选刷新。
- **系统组件与软件卸载**：[官方处理方式](references/windows-and-wiztree.md#windows-cleanup-order)；已安装软件使用注册卸载程序，残留按风险参考核验。
- **回收与永久删除**：[回收操作](references/windows-and-wiztree.md#recycle-bin-staging)，使用 Windows 回收接口；按目标盘精确匹配条目并保护其他条目，不能用清空整个回收站替代本批删除。
- **页面文件**：[页面文件检查](references/windows-and-wiztree.md#pagefile-inspection)，作为系统配置处理，保留实时配置、内存提交及崩溃转储判断。

在已有清单记录原路径、动作、字节数、核验依据、适用副本和哈希、时间、结果及恢复方式。扫描结果、候选清单和回收站快照可能暴露私人路径；只保存到用户批准的任务目录，不放入 Skill 目录或公开仓库，不默认增加长期日志或索引。

### 5. 核验与交付

核对批准动作的实际结果：回收条目存在、准确永久删除完成或官方清理成功；涉及回收站时按目标盘核对，确认非目标条目未受影响。重新读取可用空间，区分处理字节数与实际释放量，回收暂存不计作释放；后台应用造成的空间差异如实说明。

分点交付清理前后空间及时间、完成操作和处理量、跳过项及原因、适用的回收站状态与副本核验、仍需的重启或用户操作。只读任务交付调查和候选，不报清理成功。

批准批次完成并核验后结束，不等待最终签字，不为凑释放量、弥补失败或追逐零散小文件扩大清理；用户要求停止时停止。
