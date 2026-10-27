param(
    [ValidateSet('Inventory','Verify','Apply','Rollback')] [string] $Mode = 'Inventory',
    [string] $PlanPath,
    [string] $SnapshotPath,
    [string] $OutputPath,
    [string] $AuthorizationToken
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

[ComImport, Guid("85CB6900-4D95-11CF-960C-0080C7F4EE85"), InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
interface IShellWindowsLayout
{
    [DispId(1610743808)] int Count { get; }
    [DispId(0)] object Item([In, Optional] object index);
    [DispId(1610743811)] void Register([In] object pid,[In] int hwnd,[In] int swClass,out int cookie);
    [DispId(1610743812)] void RegisterPending([In] int threadId,[In,MarshalAs(UnmanagedType.Struct)] ref object location,[In,MarshalAs(UnmanagedType.Struct)] ref object root,[In] int swClass,out int cookie);
    [DispId(1610743813)] void Revoke([In] int cookie);
    [DispId(1610743814)] void OnNavigate([In] int cookie,[In,MarshalAs(UnmanagedType.Struct)] ref object location);
    [DispId(1610743815)] void OnActivated([In] int cookie,[In] bool active);
    [DispId(1610743816)] object FindWindowSW([In,MarshalAs(UnmanagedType.Struct)] ref object location,[In,MarshalAs(UnmanagedType.Struct)] ref object root,[In] int swClass,out int hwnd,[In] int options);
}
[ComImport, Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39")] class ShellWindowsLayoutClass { }
[ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IOleServiceProviderLayout { [PreserveSig] int QueryService(ref Guid service,ref Guid riid,out IntPtr obj); }
[ComImport, Guid("CDE725B0-CCC9-4519-917E-325D72FAB4CE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IFolderViewLayout
{
    [PreserveSig] int GetCurrentViewMode(out uint mode);
    [PreserveSig] int SetCurrentViewMode(uint mode);
    [PreserveSig] int GetFolder(ref Guid riid,out IntPtr obj);
    [PreserveSig] int Item(int index,out IntPtr pidl);
    [PreserveSig] int ItemCount(uint flags,out int count);
    [PreserveSig] int Items(uint flags,ref Guid riid,out IntPtr obj);
    [PreserveSig] int GetSelectionMarkedItem(out int index);
    [PreserveSig] int GetFocusedItem(out int index);
    [PreserveSig] int GetItemPosition(IntPtr pidl,out LayoutPoint point);
    [PreserveSig] int GetSpacing(out LayoutPoint point);
    [PreserveSig] int GetDefaultSpacing(out LayoutPoint point);
    [PreserveSig] int GetAutoArrange();
    [PreserveSig] int SelectItem(int index,uint flags);
    [PreserveSig] int SelectAndPositionItems(uint count,[MarshalAs(UnmanagedType.LPArray,SizeParamIndex=0)] IntPtr[] pidls,[MarshalAs(UnmanagedType.LPArray,SizeParamIndex=0)] LayoutPoint[] points,uint flags);
}
[StructLayout(LayoutKind.Sequential)] public struct LayoutPoint { public int X,Y; }
[StructLayout(LayoutKind.Sequential)] struct LayoutRect { public int Left,Top,Right,Bottom; }

public sealed class DesktopItemSnapshot
{
    public string Path { get; set; }
    public int X { get; set; }
    public int Y { get; set; }
    public bool IsDirectory { get; set; }
    public bool IsVirtual { get; set; }
}
public sealed class DesktopMetricsSnapshot
{
    public int Width { get; set; }
    public int Height { get; set; }
    public int SpacingX { get; set; }
    public int SpacingY { get; set; }
    public int OriginX { get; set; }
    public int OriginY { get; set; }
    public bool AutoArrange { get; set; }
}
public sealed class DesktopSnapshot
{
    public DesktopMetricsSnapshot Metrics { get; set; }
    public DesktopItemSnapshot[] Items { get; set; }
}
public sealed class DesktopApplyResult
{
    public int AssignmentCount { get; set; }
    public int MismatchCount { get; set; }
    public string[] Mismatches { get; set; }
}

public static class DesktopShellLayout
{
    class Node { public string Path; public IntPtr Pidl; }
    class Target { public string Path; public int X,Y; }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int QueryActiveShellView(IntPtr self,out IntPtr view);
    [DllImport("shell32.dll")] static extern int SHGetSpecialFolderLocation(IntPtr hwnd,int csidl,out IntPtr pidl);
    [DllImport("shell32.dll")] static extern IntPtr ILCombine(IntPtr first,IntPtr second);
    [DllImport("shell32.dll")] static extern int SHGetNameFromIDList(IntPtr pidl,uint nameType,out IntPtr name);
    [DllImport("ole32.dll")] static extern void CoTaskMemFree(IntPtr memory);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr FindWindow(string className,string windowName);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string className,string windowName);
    delegate bool EnumWindowsProc(IntPtr hwnd,IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback,IntPtr lParam);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd,out LayoutRect rect);
    [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd,int index);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

    static IFolderViewLayout GetView()
    {
        IShellWindowsLayout windows=(IShellWindowsLayout)new ShellWindowsLayoutClass();
        object location=null,root=null;int hwnd;
        object dispatch=windows.FindWindowSW(ref location,ref root,8,out hwnd,1);
        if(dispatch==null)throw new Exception("Desktop Shell view was not found.");
        IOleServiceProviderLayout provider=(IOleServiceProviderLayout)dispatch;
        Guid service=new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");
        Guid browserIid=new Guid("000214E2-0000-0000-C000-000000000046");
        IntPtr browser;int hr=provider.QueryService(ref service,ref browserIid,out browser);
        if(hr!=0)Marshal.ThrowExceptionForHR(hr);
        IntPtr view=IntPtr.Zero,folderView=IntPtr.Zero;
        try
        {
            IntPtr vtable=Marshal.ReadIntPtr(browser);
            IntPtr method=Marshal.ReadIntPtr(vtable,15*IntPtr.Size);
            var query=(QueryActiveShellView)Marshal.GetDelegateForFunctionPointer(method,typeof(QueryActiveShellView));
            hr=query(browser,out view);if(hr!=0)Marshal.ThrowExceptionForHR(hr);
            Guid iid=new Guid("CDE725B0-CCC9-4519-917E-325D72FAB4CE");
            hr=Marshal.QueryInterface(view,in iid,out folderView);if(hr!=0)Marshal.ThrowExceptionForHR(hr);
            return (IFolderViewLayout)Marshal.GetObjectForIUnknown(folderView);
        }
        finally
        {
            if(folderView!=IntPtr.Zero)Marshal.Release(folderView);
            if(view!=IntPtr.Zero)Marshal.Release(view);
            Marshal.Release(browser);
        }
    }

    static IntPtr FindDesktopList()
    {
        IntPtr definition=IntPtr.Zero;
        IntPtr progman=FindWindow("Progman",null);
        if(progman!=IntPtr.Zero)definition=FindWindowEx(progman,IntPtr.Zero,"SHELLDLL_DefView",null);
        if(definition==IntPtr.Zero)
        {
            EnumWindows((hwnd,lParam)=>{IntPtr candidate=FindWindowEx(hwnd,IntPtr.Zero,"SHELLDLL_DefView",null);if(candidate!=IntPtr.Zero){definition=candidate;return false;}return true;},IntPtr.Zero);
        }
        return definition==IntPtr.Zero?IntPtr.Zero:FindWindowEx(definition,IntPtr.Zero,"SysListView32",null);
    }

    static List<Node> Enumerate(IFolderViewLayout view)
    {
        int count;int hr=view.ItemCount(2,out count);if(hr!=0)Marshal.ThrowExceptionForHR(hr);
        IntPtr desktop;hr=SHGetSpecialFolderLocation(IntPtr.Zero,0,out desktop);if(hr!=0)Marshal.ThrowExceptionForHR(hr);
        var nodes=new List<Node>();
        try
        {
            for(int i=0;i<count;i++)
            {
                IntPtr child;hr=view.Item(i,out child);if(hr!=0||child==IntPtr.Zero)continue;
                IntPtr absolute=ILCombine(desktop,child);
                if(absolute==IntPtr.Zero){CoTaskMemFree(child);continue;}
                try
                {
                    IntPtr name;hr=SHGetNameFromIDList(absolute,0x80028000,out name);
                    string path=hr==0&&name!=IntPtr.Zero?Marshal.PtrToStringUni(name):"";
                    if(name!=IntPtr.Zero)CoTaskMemFree(name);
                    if(String.IsNullOrWhiteSpace(path)){CoTaskMemFree(child);continue;}
                    nodes.Add(new Node{Path=path,Pidl=child});
                }
                finally{CoTaskMemFree(absolute);}
            }
        }
        finally{CoTaskMemFree(desktop);}
        return nodes;
    }

    static Target ParseTarget(string raw)
    {
        string[] parts=raw.Split((char)0x1F);
        if(parts.Length!=3)throw new Exception("Invalid assignment record.");
        return new Target{Path=parts[0],X=Int32.Parse(parts[1]),Y=Int32.Parse(parts[2])};
    }

    public static DesktopSnapshot Capture()
    {
        IFolderViewLayout view=GetView();List<Node> nodes=null;
        try
        {
            nodes=Enumerate(view);
            var items=new List<DesktopItemSnapshot>();
            foreach(Node node in nodes)
            {
                LayoutPoint point;int hr=view.GetItemPosition(node.Pidl,out point);if(hr!=0)Marshal.ThrowExceptionForHR(hr);
                items.Add(new DesktopItemSnapshot{Path=node.Path,X=point.X,Y=point.Y,IsDirectory=Directory.Exists(node.Path),IsVirtual=node.Path.StartsWith("::",StringComparison.Ordinal)});
            }
            LayoutPoint spacing;int spacingHr=view.GetSpacing(out spacing);
            if(spacingHr!=0||spacing.X<=0||spacing.Y<=0){spacingHr=view.GetDefaultSpacing(out spacing);if(spacingHr!=0)Marshal.ThrowExceptionForHR(spacingHr);}
            IntPtr list=FindDesktopList();int width=0,height=0;bool styleAuto=false;
            if(list!=IntPtr.Zero)
            {
                LayoutRect rect;if(GetClientRect(list,out rect)){width=rect.Right-rect.Left;height=rect.Bottom-rect.Top;}
                styleAuto=(GetWindowLongPtr(list,-16).ToInt64()&0x100)!=0;
            }
            if(width<=0)width=GetSystemMetrics(78);
            if(height<=0)height=GetSystemMetrics(79);
            int originX=items.Count==0?0:items.Min(x=>x.X);
            int originY=items.Count==0?0:items.Min(x=>x.Y);
            int autoHr=view.GetAutoArrange();
            return new DesktopSnapshot{
                Metrics=new DesktopMetricsSnapshot{Width=width,Height=height,SpacingX=spacing.X,SpacingY=spacing.Y,OriginX=originX,OriginY=originY,AutoArrange=styleAuto||autoHr==0},
                Items=items.OrderBy(x=>x.Path,StringComparer.OrdinalIgnoreCase).ToArray()
            };
        }
        finally
        {
            if(nodes!=null)foreach(Node node in nodes)if(node.Pidl!=IntPtr.Zero)CoTaskMemFree(node.Pidl);
            if(view!=null)Marshal.FinalReleaseComObject(view);
        }
    }

    public static DesktopApplyResult Apply(string[] rawAssignments)
    {
        List<Target> targets=rawAssignments.Select(ParseTarget).ToList();
        IFolderViewLayout view=GetView();List<Node> nodes=null;
        try
        {
            nodes=Enumerate(view);
            if(nodes.Count!=targets.Count)throw new Exception("Live desktop item count changed before apply.");
            var lookup=nodes.GroupBy(x=>x.Path,StringComparer.OrdinalIgnoreCase).ToDictionary(g=>g.Key,g=>new Queue<Node>(g),StringComparer.OrdinalIgnoreCase);
            var selected=new List<Node>();
            foreach(Target target in targets)
            {
                Queue<Node> queue;
                if(!lookup.TryGetValue(target.Path,out queue)||queue.Count==0)throw new Exception("PIDL path missing: "+target.Path);
                selected.Add(queue.Dequeue());
            }
            IntPtr[] pidls=selected.Select(x=>x.Pidl).ToArray();
            LayoutPoint[] points=targets.Select(x=>new LayoutPoint{X=x.X,Y=x.Y}).ToArray();
            int hr=view.SelectAndPositionItems((uint)pidls.Length,pidls,points,0x80);if(hr!=0)Marshal.ThrowExceptionForHR(hr);
            Thread.Sleep(1200);
            var mismatches=new List<string>();
            for(int i=0;i<targets.Count;i++)
            {
                LayoutPoint actual;hr=view.GetItemPosition(pidls[i],out actual);
                if(hr!=0||actual.X!=targets[i].X||actual.Y!=targets[i].Y)mismatches.Add(targets[i].Path);
            }
            return new DesktopApplyResult{AssignmentCount=targets.Count,MismatchCount=mismatches.Count,Mismatches=mismatches.ToArray()};
        }
        finally
        {
            if(nodes!=null)foreach(Node node in nodes)if(node.Pidl!=IntPtr.Zero)CoTaskMemFree(node.Pidl);
            if(view!=null)Marshal.FinalReleaseComObject(view);
        }
    }
}
'@

function Convert-SnapshotPayload($Snapshot) {
    return [pscustomobject]@{
        schemaVersion = 1
        capturedAt = [DateTimeOffset]::Now.ToString('o')
        metrics = [pscustomobject]@{
            width = $Snapshot.Metrics.Width
            height = $Snapshot.Metrics.Height
            spacingX = $Snapshot.Metrics.SpacingX
            spacingY = $Snapshot.Metrics.SpacingY
            originX = $Snapshot.Metrics.OriginX
            originY = $Snapshot.Metrics.OriginY
            autoArrange = $Snapshot.Metrics.AutoArrange
        }
        items = @($Snapshot.Items | ForEach-Object {
            [pscustomobject]@{ path=$_.Path; x=$_.X; y=$_.Y; isDirectory=$_.IsDirectory; isVirtual=$_.IsVirtual }
        })
    }
}

function Write-NewUtf8([string] $Path, [string] $Content) {
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { throw "Output directory does not exist: $parent" }
    if ([IO.File]::Exists($full)) { throw "Refusing to overwrite existing file: $full" }
    [IO.File]::WriteAllText($full, $Content, [Text.UTF8Encoding]::new($false))
    return $full
}

function Read-JsonFile([string] $Path) {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30
}

function Convert-PlanToAssignments($Plan) {
    $separator = [char]0x1F
    return @($Plan.items | ForEach-Object { "$($_.path)$separator$([int]$_.x)$separator$([int]$_.y)" })
}

function Convert-InventoryToRollbackPlan($Inventory) {
    return [pscustomobject]@{
        schemaVersion = 1
        inventoryCapturedAt = $Inventory.capturedAt
        grid = [pscustomobject]@{
            originX=$Inventory.metrics.originX; originY=$Inventory.metrics.originY
            spacingX=$Inventory.metrics.spacingX; spacingY=$Inventory.metrics.spacingY
        }
        items = @($Inventory.items | ForEach-Object {
            [pscustomobject]@{ path=$_.path; x=$_.x; y=$_.y; group='rollback'; fixed=([bool]$_.isVirtual) }
        })
        constraints = @()
        zones = @()
    }
}

function Get-ExplorerProcessSignature {
    return (@(Get-Process -Name explorer -ErrorAction SilentlyContinue | Sort-Object Id | ForEach-Object { $_.Id }) -join ',')
}

function Invoke-Validation($PlanFile, $InventoryPayload, [string] $ValidationMode, [bool] $AllowLargeReflow = $false) {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("desktop-inventory-" + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($temp, ($InventoryPayload | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        $validator = Join-Path $PSScriptRoot 'validate_layout_plan.ps1'
        $json = & $validator -PlanPath $PlanFile -InventoryPath $temp -Mode $ValidationMode -AllowLargeReflow:$AllowLargeReflow
        $parsed = $json | ConvertFrom-Json -Depth 20
        $code = if ([bool]$parsed.success) { 0 } else { 2 }
        return [pscustomobject]@{ ExitCode=$code; Result=$parsed }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Compare-ExactCoordinates($Plan, $Inventory) {
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Inventory.items)) { $map[[string]$item.path] = $item }
    $mismatches = [Collections.Generic.List[string]]::new()
    foreach ($item in @($Plan.items)) {
        if (-not $map.ContainsKey([string]$item.path)) { $mismatches.Add("missing: $($item.path)"); continue }
        $actual = $map[[string]$item.path]
        if ([int]$actual.x -ne [int]$item.x -or [int]$actual.y -ne [int]$item.y) { $mismatches.Add([string]$item.path) }
    }
    return @($mismatches)
}

function Emit-Result($Value) {
    $json = $Value | ConvertTo-Json -Depth 20
    if ($OutputPath) { $saved = Write-NewUtf8 $OutputPath $json; return [pscustomobject]@{ savedTo=$saved; result=$Value } | ConvertTo-Json -Depth 20 }
    return $json
}

if ($Mode -eq 'Inventory') {
    $inventory = Convert-SnapshotPayload ([DesktopShellLayout]::Capture())
    Emit-Result $inventory
    exit 0
}

if ($Mode -in @('Verify','Apply') -and [string]::IsNullOrWhiteSpace($PlanPath)) { throw 'PlanPath is required.' }
if ($Mode -eq 'Rollback' -and [string]::IsNullOrWhiteSpace($SnapshotPath)) { throw 'SnapshotPath is required.' }

if ($Mode -eq 'Verify') {
    $plan = Read-JsonFile $PlanPath
    $inventory = Convert-SnapshotPayload ([DesktopShellLayout]::Capture())
    $validation = Invoke-Validation $PlanPath $inventory 'Postflight'
    Emit-Result ([pscustomobject]@{ success=($validation.ExitCode -eq 0); validation=$validation.Result })
    if ($validation.ExitCode -ne 0) { exit 2 }
    exit 0
}

if ($Mode -eq 'Rollback') {
    if ($AuthorizationToken -cne 'ROLLBACK-ICON-LAYOUT') { throw 'Rollback requires AuthorizationToken ROLLBACK-ICON-LAYOUT.' }
    $snapshot = Read-JsonFile $SnapshotPath
    $rollbackPlan = Convert-InventoryToRollbackPlan $snapshot
    $apply = [DesktopShellLayout]::Apply((Convert-PlanToAssignments $rollbackPlan))
    $after = Convert-SnapshotPayload ([DesktopShellLayout]::Capture())
    $mismatches = Compare-ExactCoordinates $rollbackPlan $after
    $result = [pscustomobject]@{ success=($apply.MismatchCount -eq 0 -and $mismatches.Count -eq 0); mode='Rollback'; assignmentCount=$apply.AssignmentCount; mismatches=$mismatches }
    Emit-Result $result
    if (-not $result.success) { exit 3 }
    exit 0
}

$allowLargeReflow = $AuthorizationToken -ceq 'APPLY-LARGE-REFLOW'
if ($AuthorizationToken -cne 'APPLY-ICON-LAYOUT' -and -not $allowLargeReflow) { throw 'Apply requires AuthorizationToken APPLY-ICON-LAYOUT, or APPLY-LARGE-REFLOW after separate user authorization.' }
if ([string]::IsNullOrWhiteSpace($SnapshotPath)) { throw 'Apply requires a new SnapshotPath for rollback.' }
if (Test-Path -LiteralPath $SnapshotPath) { throw "Refusing to overwrite existing snapshot: $SnapshotPath" }

$plan = Read-JsonFile $PlanPath
$before = Convert-SnapshotPayload ([DesktopShellLayout]::Capture())
$preflight = Invoke-Validation $PlanPath $before 'Preflight' $allowLargeReflow
if ($preflight.ExitCode -ne 0) {
    Emit-Result ([pscustomobject]@{ success=$false; mode='Apply'; mutated=$false; preflight=$preflight.Result })
    exit 2
}
$rollbackPlan = Convert-InventoryToRollbackPlan $before
$savedSnapshot = Write-NewUtf8 $SnapshotPath ($before | ConvertTo-Json -Depth 12)
$explorerBefore = Get-ExplorerProcessSignature
$applyError = $null
$applyResult = $null
$postflight = $null
$explorerRestarted = $false
try {
    $applyResult = [DesktopShellLayout]::Apply((Convert-PlanToAssignments $plan))
    $explorerAfter = Get-ExplorerProcessSignature
    $after = Convert-SnapshotPayload ([DesktopShellLayout]::Capture())
    $postflight = Invoke-Validation $PlanPath $after 'Postflight' $allowLargeReflow
    $explorerRestarted = $explorerBefore -ne $explorerAfter
} catch {
    $applyError = $_.Exception.Message
    $explorerAfter = Get-ExplorerProcessSignature
    $explorerRestarted = $explorerBefore -ne $explorerAfter
}
$needsRollback = $null -ne $applyError -or $explorerRestarted -or $applyResult.MismatchCount -ne 0 -or $postflight.ExitCode -ne 0

if ($needsRollback) {
    $rollbackApply = $null
    $rollbackMismatches = @()
    $rollbackError = $null
    try {
        $rollbackApply = [DesktopShellLayout]::Apply((Convert-PlanToAssignments $rollbackPlan))
        $rollbackAfter = Convert-SnapshotPayload ([DesktopShellLayout]::Capture())
        $rollbackMismatches = Compare-ExactCoordinates $rollbackPlan $rollbackAfter
    } catch {
        $rollbackError = $_.Exception.Message
    }
    $rollbackSucceeded = $null -eq $rollbackError -and $null -ne $rollbackApply -and
        $rollbackApply.MismatchCount -eq 0 -and $rollbackMismatches.Count -eq 0
    $result = [pscustomobject]@{
        success=$false; mode='Apply'; mutationAttempted=$true; explorerRestarted=$explorerRestarted
        snapshotPath=$savedSnapshot; applyError=$applyError; apply=$applyResult
        postflight=$(if ($null -ne $postflight) { $postflight.Result } else { $null })
        rollbackAttempted=$true; rollbackSucceeded=$rollbackSucceeded; rollbackError=$rollbackError
        rollbackMismatches=$rollbackMismatches
    }
    Emit-Result $result
    exit 3
}

Emit-Result ([pscustomobject]@{
    success=$true; mode='Apply'; mutated=$true; explorerRestarted=$false; snapshotPath=$savedSnapshot
    assignmentCount=$applyResult.AssignmentCount; coordinateMismatches=$applyResult.MismatchCount
    preflight=$preflight.Result; postflight=$postflight.Result; largeReflowAuthorized=$allowLargeReflow; rollbackAttempted=$false
})
