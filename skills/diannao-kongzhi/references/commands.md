# 受限命令参考

## 调用方式

在标准用户 PowerShell 中调用固定包装器：

```powershell
$safeWinApp = $env:SAFE_WINAPP_WRAPPER
if ([string]::IsNullOrWhiteSpace($safeWinApp) -or -not (Test-Path -LiteralPath $safeWinApp -PathType Leaf)) {
    throw 'Set SAFE_WINAPP_WRAPPER to the reviewed Safe-WinApp.ps1 path.'
}
$expectedWrapperSha256 = $env:SAFE_WINAPP_WRAPPER_SHA256
if ($expectedWrapperSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
    throw 'Set SAFE_WINAPP_WRAPPER_SHA256 to the reviewed wrapper SHA-256.'
}
$actualWrapperSha256 = (Get-FileHash -LiteralPath $safeWinApp -Algorithm SHA256).Hash
if (-not $actualWrapperSha256.Equals($expectedWrapperSha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Safe-WinApp.ps1 SHA-256 does not match the reviewed value.'
}
$env:WINAPP_UI_WORKFLOW_ID = [guid]::NewGuid().ToString()
& powershell.exe -NoLogo -NoProfile -File $safeWinApp version
```

每个新的逻辑任务使用新的 `WINAPP_UI_WORKFLOW_ID`。不要永久写入用户或系统环境变量。包装器更新后必须重新人工审查并更新预期哈希；不得为了让未知脚本运行而使用 `-ExecutionPolicy Bypass`。

## 推荐顺序

```powershell
& powershell.exe -NoLogo -NoProfile -File $safeWinApp list-windows
& powershell.exe -NoLogo -NoProfile -File $safeWinApp search '保存' -w 123456
& powershell.exe -NoLogo -NoProfile -File $safeWinApp inspect -w 123456 --interactive --hide-disabled --hide-offscreen
& powershell.exe -NoLogo -NoProfile -File $safeWinApp get-value 'Document' -w 123456
& powershell.exe -NoLogo -NoProfile -File $safeWinApp set-value 'NameField' '新值' -w 123456
& powershell.exe -NoLogo -NoProfile -File $safeWinApp invoke 'ApplyButton' -w 123456
& powershell.exe -NoLogo -NoProfile -File $safeWinApp activate-window -w 123456 --expect-title 'Example App' --expect-process 'ExampleApp'
& powershell.exe -NoLogo -NoProfile -File $safeWinApp dismiss-modal -w 222222 --expect-title 'Promo' --expect-process 'ExampleApp' --main-w 111111 --expect-main-title 'Example App' --confirm-dismiss
& powershell.exe -NoLogo -NoProfile -File $safeWinApp wait-for '完成' -w 123456
& powershell.exe -NoLogo -NoProfile -File $safeWinApp screenshot -w 123456
```

控件标识和参数必须来自当前窗口的 `search` 或 `inspect` 结果，不要照抄示例中的名称和句柄。

## 允许的能力

`status`、`list-windows`、`inspect`、`search`、`get-focused`、`get-property`、`get-value`、`wait-for`、`set-value`、`invoke`、`focus`、精确身份校验且不发送输入的 `activate-window`、`scroll-into-view`、`scroll`、受约束的 `dismiss-modal`、窗口级 `screenshot` 和 `yield`。

包装器必须阻止按键注入、坐标点击、触摸、笔输入、录制、系统键、PostMessage、全屏捕获、覆盖写入、沙箱管理和安装签名相关操作。公开 Skill 不登记任何软件专用固定动作，也不得登记登录、验证码、付款、购买、订阅、发布、上传或账号安全动作。

## 自绘模态弹窗

只有同时满足以下条件时才能使用 `dismiss-modal`：

- 已用 `list-windows` 取得当前目标弹窗和同进程主窗口的句柄、标题与进程名；不得复用旧句柄。
- `search`、精简 `inspect` 和 `get-focused` 已确认弹窗不暴露可调用子控件；如果能 `invoke` 明确的“取消”“放弃”或关闭按钮，仍优先 `invoke`。
- 用户已经明确要求关闭这个已识别弹窗，并且已说明关闭会放弃或隐藏什么；若可能丢弃未保存内容，仍按高影响动作逐次确认。
- 命令必须同时提供精确的 `-w`、`--expect-title`、`--expect-process`、`--main-w`、`--expect-main-title` 和 `--confirm-dismiss`。包装器还会验证两窗口属于同一进程、目标明显小于主窗口、支持 UI Automation `WindowPattern`，并至少取得一项强模态证据：Win32 所有者是指定主窗口、UIA `IsModal` 为真，或指定主窗口已因模态关系被禁用。
- 动作后必须重新运行 `list-windows`：目标弹窗应消失，而主窗口必须仍存在。未同时验证这两点不得报告成功。

`dismiss-modal` 不用于关闭主窗口、文档窗口、编辑器、UAC、安全桌面、登录、验证码、付款或账号安全界面，也不得作为坐标点击失败后的泛化替代品。

## 失败处理

- 退出码 `2`：底层程序缺失。停止并报告固定路径。
- 退出码 `5`：当前进程已提升。改用标准用户终端，不要继续提权。
- 退出码 `6`：命令或参数被安全策略阻止。说明缺少的能力，不要绕过包装器。
- 找不到窗口或控件：重新运行 `list-windows`、`search` 或精简 `inspect`。
- 控件有多个匹配：补充窗口句柄和更精确的控件标识；仍有歧义则询问用户。
- 界面修改后无法验证：报告“动作已尝试但未验证”，不要报告成功。

## 输出节制

优先保留与目标相关的控件、值和错误。不要把完整 UI 树、无关窗口列表或大幅截图直接塞进回复；先在本地筛选，再向用户汇报结论。
