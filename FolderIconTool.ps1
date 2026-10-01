# FolderIconTool.ps1 —— 文件夹图标工具（图形界面）
# 用途：识别文件夹内的应用程序图标，并把文件夹图标改为该图标，
#       让资源管理器里一眼看出文件夹装的是什么软件。
#
# 使用：双击「启动.cmd」，或在 PowerShell 中运行本脚本。

param(
    [string]$Folder,          # 命令行模式：直接处理指定文件夹
    [string]$Exe,             # 命令行模式：指定使用哪个 exe（省略则自动判定）
    [string]$ScanRoot,        # 命令行模式：批量扫描 + 自动处理
    [switch]$Auto,            # 批量自动模式（不弹选择框，歧义项跳过并记录）
    [switch]$Revert,          # 恢复模式：配合 -Folder 使用
    [switch]$NoGui,
    [switch]$SelfTest,        # 自检：构建界面后自动走一遍关键流程再关闭
    [string]$AutoScan,        # 打开界面后自动扫描该路径（用于演示/排错）
    [int]$AutoCloseSeconds = 0  # 配合 -AutoScan：若干秒后自动关闭窗口
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------- 控制台编码（仅命令行模式需要） ----------
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $script:Root 'FolderIcon.Core.cs') -ReferencedAssemblies System.Drawing, System.Windows.Forms

# ---------- 图标存放目录 ----------
$script:IconStore = Join-Path $env:LOCALAPPDATA 'FolderIconTool\icons'
if (-not (Test-Path $script:IconStore)) { New-Item -ItemType Directory -Path $script:IconStore -Force | Out-Null }

function Get-IconStorePath {
    param([string]$FolderPath)
    # 用文件夹完整路径的哈希命名，保证唯一且不污染原文件夹
    $normalized = $FolderPath.TrimEnd('\').ToLowerInvariant()
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = [BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::Unicode.GetBytes($normalized))).Replace('-', '')
    $md5.Dispose()
    return (Join-Path $script:IconStore ($hash.Substring(0, 16) + '.ico'))
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1048576) { return ('{0:0.##} MB' -f ($Bytes / 1048576.0)) }
    if ($Bytes -ge 1024) { return ('{0:0.#} KB' -f ($Bytes / 1024.0)) }
    return "$Bytes B"
}

function Get-CandidateKind {
    param($Pe)
    if ($null -eq $Pe -or -not $Pe.IsValidPe) { return '未知' }
    switch ($Pe.Subsystem) {
        'WindowsGui' { return '图形界面' }
        'WindowsConsole' { return '控制台' }
        'Native' { return '系统驱动' }
        default { return '其他' }
    }
}

# ---------- 命令行模式（无界面） ----------

if ($NoGui -or $Folder -or $ScanRoot) {
    if ($Revert -and $Folder) {
        $icon = Get-IconStorePath $Folder
        [FolderIconTool.FolderIconManager]::Revert($Folder, $true)
        if (Test-Path $icon) { Remove-Item $icon -Force -ErrorAction SilentlyContinue }
        Write-Host "已恢复：$Folder"
        exit 0
    }
    if ($Folder -and $Exe) {
        $icon = Get-IconStorePath $Folder
        [FolderIconTool.FolderIconManager]::Apply($Folder, $Exe, $icon, $false)
        Write-Host "已设置：$Folder  ->  $Exe"
        exit 0
    }
    if ($ScanRoot) {
        $dirs = @(Get-ChildItem -LiteralPath $ScanRoot -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notmatch '^(\$RECYCLE\.BIN|System Volume Information)$' })
        $stat = @{ ok = 0; ask = 0; skip = 0; fail = 0 }
        $askList = @()
        foreach ($d in $dirs) {
            $cands = @([FolderIconTool.CandidateFinder]::Find($d.FullName, 2))
            if ($cands.Count -eq 0) { $stat.skip++; continue }
            $explain = ''
            $need = [FolderIconTool.CandidateFinder]::NeedsUserChoice($cands, [ref]$explain)
            if ($need) {
                $stat.ask++
                $askList += $d.FullName
                Write-Host ("[需选择] {0}  —— {1}" -f $d.Name, $explain)
                $cands | Select-Object -First 5 | ForEach-Object {
                    Write-Host ("           · {0}（{1}，评分 {2}）" -f $_.FileName, $_.SizeText, $_.Score)
                }
                continue
            }
            $pick = $cands[0]
            $icon = Get-IconStorePath $d.FullName
            try {
                [FolderIconTool.FolderIconManager]::Apply($d.FullName, $pick.Path, $icon, $false)
                $stat.ok++
                Write-Host ("[已设置] {0}  <-  {1}   ({2})" -f $d.Name, $pick.FileName, $pick.Reason)
            } catch {
                $stat.fail++
                $msg = $_.Exception.Message
                if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
                Write-Host ("[失败]   {0} : {1}" -f $d.Name, $msg) -ForegroundColor Red
            }
        }
        Write-Host ""
        Write-Host ("完成：已设置 {0} 个，需人工选择 {1} 个，无可用程序 {2} 个，失败 {3} 个" -f `
            $stat.ok, $stat.ask, $stat.skip, $stat.fail)
        if ($askList.Count -gt 0) {
            Write-Host "`n需要在图形界面中手动选择的文件夹："
            $askList | ForEach-Object { Write-Host "  · $_" }
        }
        exit 0
    }
}

# ================= 图形界面 =================

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:DefaultFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

# ---------- 主窗口 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = '文件夹图标工具 —— 让文件夹一眼看出是什么软件'
$form.Size = New-Object System.Drawing.Size(1240, 760)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = $script:DefaultFont

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Padding = New-Object System.Drawing.Point(14, 6)
$form.Controls.Add($tabs)

# ---------- 状态栏 ----------
$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = '就绪'
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusLabel)
$form.Controls.Add($status)

function Set-Status {
    param([string]$Text, [string]$Color = 'ControlText')
    $statusLabel.Text = $Text
    $statusLabel.ForeColor = [System.Drawing.Color]::FromName($Color)
    [System.Windows.Forms.Application]::DoEvents()
}

# ---------- 共享小图标缓存 ----------
# 一个 ImageList 服务所有列表。注意：绝不清空它，
# 否则其它列表里引用旧索引的项会全部丢失图标。
$script:SharedIcons = New-Object System.Windows.Forms.ImageList
$script:SharedIcons.ImageSize = New-Object System.Drawing.Size(32, 32)
$script:SharedIcons.ColorDepth = 'Depth32Bit'

function Get-IconIndex {
    param([string]$Path, [int]$Size = 32)
    if (-not $Path) { return -1 }
    try {
        $bmp = [FolderIconTool.IconExtractor]::GetSize($Path, $Size)
        if (-not $bmp) { $bmp = [FolderIconTool.IconExtractor]::FallbackExtract($Path, $Size) }
        if (-not $bmp) { return -1 }
        $script:SharedIcons.Images.Add($bmp)
        return ($script:SharedIcons.Images.Count - 1)
    } catch { return -1 }
}

# 取某个来源在多个尺寸下的图标，用于预览
function Get-SourceFrames {
    param([string]$Path, [int[]]$Sizes = @(16, 32, 48, 64))
    $result = @{}
    if (-not $Path) { return $result }
    foreach ($s in $Sizes) {
        try {
            $bmp = $null
            if ($Path -match '\.ico$') {
                $bmp = [FolderIconTool.IconExtractor]::LoadLargestFrame($Path)
                if ($bmp) { $scaled = [FolderIconTool.IconExtractor]::ResizeWithAlpha($bmp, $s); $bmp.Dispose(); $bmp = $scaled }
            } else {
                $bmp = [FolderIconTool.IconExtractor]::GetSize($Path, $s)
                if (-not $bmp) { $bmp = [FolderIconTool.IconExtractor]::FallbackExtract($Path, $s) }
            }
            if ($bmp) { $result[$s] = $bmp }
        } catch { }
    }
    return $result
}

# 绘制图标预览条：同一图标在多种尺寸下的效果
function Draw-PreviewStrip {
    param(
        [System.Windows.Forms.PictureBox]$Box,
        [string]$Path,
        [string]$Caption = ''
    )
    if ($Box.Image) { $Box.Image.Dispose(); $Box.Image = $null }
    $w = $Box.Width; $h = $Box.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.TextRenderingHint = 'ClearTypeGridFit'

    $frames = Get-SourceFrames -Path $Path -Sizes @(16, 24, 32, 48, 64, 128, 256)
    if ($frames.Count -eq 0) {
        $f = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
        $fH = $f.GetHeight($g)
        $g.DrawString('（无法预览该来源的图标）', $f, [System.Drawing.Brushes]::Gray, 12, ($h - $fH) / 2)
        $f.Dispose()
    } else {
        # 先算出实际要画的最大尺寸，再据此垂直居中，避免大图标超出预览框
        $maxFit = $h - 42
        if ($maxFit -lt 16) { $maxFit = 16 }
        $drawSizes = @()
        foreach ($s in @(16, 24, 32, 48, 64, 128, 256)) {
            if (-not $frames.ContainsKey($s)) { continue }
            $d = [Math]::Min($s, $maxFit)
            $drawSizes += @{ Size = $s; Draw = $d }
        }
        $maxDraw = 0
        foreach ($e in $drawSizes) { if ($e.Draw -gt $maxDraw) { $maxDraw = $e.Draw } }
        $baseline = [int](($h - 16) / 2)
        $x = 14
        foreach ($e in $drawSizes) {
            $d = $e.Draw
            $y = $baseline - [int]($d / 2)
            if ($y -lt 4) { $y = 4 }
            $g.DrawImage($frames[$e.Size], $x, $y, $d, $d)
            $f = New-Object System.Drawing.Font('Microsoft YaHei UI', 7)
            $lbl = "$($e.Size)"
            $g.DrawString($lbl, $f, [System.Drawing.Brushes]::Gray, $x, $h - 17)
            $f.Dispose()
            $x += ($d + 18)
            if ($x -gt ($w - 36)) { break }
        }
        foreach ($k in $frames.Keys) { $frames[$k].Dispose() }
    }
    if ($Caption) {
        $f = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
        $g.DrawString($Caption, $f, [System.Drawing.Brushes]::DimGray, 12, 5)
        $f.Dispose()
    }
    $g.Dispose()
    $Box.Image = $bmp
}

# =========================================================
# 选项卡一：批量处理
# =========================================================
$tabBatch = New-Object System.Windows.Forms.TabPage
$tabBatch.Text = '  批量处理  '
$tabBatch.BackColor = [System.Drawing.Color]::White
$tabs.TabPages.Add($tabBatch)

$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'
$panelTop.Height = 132
$panelTop.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
$panelTop.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 8)
$tabBatch.Controls.Add($panelTop)

$lblRoot = New-Object System.Windows.Forms.Label
$lblRoot.Text = '扫描位置：'
$lblRoot.Location = New-Object System.Drawing.Point(14, 16)
$lblRoot.AutoSize = $true
$panelTop.Controls.Add($lblRoot)

$txtRoot = New-Object System.Windows.Forms.TextBox
$txtRoot.Location = New-Object System.Drawing.Point(90, 13)
$txtRoot.Width = 430
$txtRoot.Text = 'E:\'
$panelTop.Controls.Add($txtRoot)

$btnBrowseRoot = New-Object System.Windows.Forms.Button
$btnBrowseRoot.Text = '浏览...'
$btnBrowseRoot.Location = New-Object System.Drawing.Point(528, 12)
$btnBrowseRoot.Size = New-Object System.Drawing.Size(72, 26)
$panelTop.Controls.Add($btnBrowseRoot)

$lblDepth = New-Object System.Windows.Forms.Label
$lblDepth.Text = '查找深度：'
$lblDepth.Location = New-Object System.Drawing.Point(614, 16)
$lblDepth.AutoSize = $true
$panelTop.Controls.Add($lblDepth)

$cmbDepth = New-Object System.Windows.Forms.ComboBox
$cmbDepth.DropDownStyle = 'DropDownList'
$cmbDepth.Location = New-Object System.Drawing.Point(684, 13)
$cmbDepth.Width = 168
[void]$cmbDepth.Items.Add('仅文件夹内（推荐）')
[void]$cmbDepth.Items.Add('含一级子文件夹')
[void]$cmbDepth.Items.Add('含两级子文件夹')
$cmbDepth.SelectedIndex = 0
$panelTop.Controls.Add($cmbDepth)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '提示：双击任意一行可以换图标（可选文件夹内的 exe，也可以挑一个 .ico 或图片）'
$lblHint.Location = New-Object System.Drawing.Point(14, 106)
$lblHint.AutoSize = $true
$lblHint.MaximumSize = New-Object System.Drawing.Size(1180, 22)
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$panelTop.Controls.Add($lblHint)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = '开始扫描'
$btnScan.Location = New-Object System.Drawing.Point(90, 50)
$btnScan.Size = New-Object System.Drawing.Size(96, 30)
$btnScan.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnScan.ForeColor = [System.Drawing.Color]::White
$btnScan.FlatStyle = 'Flat'
$panelTop.Controls.Add($btnScan)

$btnAutoAll = New-Object System.Windows.Forms.Button
$btnAutoAll.Text = '自动设置（跳过歧义项）'
$btnAutoAll.Location = New-Object System.Drawing.Point(194, 50)
$btnAutoAll.Size = New-Object System.Drawing.Size(180, 30)
$btnAutoAll.Enabled = $false
$panelTop.Controls.Add($btnAutoAll)

$btnApplySelected = New-Object System.Windows.Forms.Button
$btnApplySelected.Text = '设置选中项'
$btnApplySelected.Location = New-Object System.Drawing.Point(382, 50)
$btnApplySelected.Size = New-Object System.Drawing.Size(110, 30)
$btnApplySelected.Enabled = $false
$panelTop.Controls.Add($btnApplySelected)

$btnRevertSelected = New-Object System.Windows.Forms.Button
$btnRevertSelected.Text = '恢复选中项'
$btnRevertSelected.Location = New-Object System.Drawing.Point(500, 50)
$btnRevertSelected.Size = New-Object System.Drawing.Size(110, 30)
$btnRevertSelected.Enabled = $false
$panelTop.Controls.Add($btnRevertSelected)

$btnRefreshCache = New-Object System.Windows.Forms.Button
$btnRefreshCache.Text = '刷新图标缓存'
$btnRefreshCache.Location = New-Object System.Drawing.Point(618, 50)
$btnRefreshCache.Size = New-Object System.Drawing.Size(120, 30)
$panelTop.Controls.Add($btnRefreshCache)

$btnCleanIcons = New-Object System.Windows.Forms.Button
$btnCleanIcons.Text = '清理未使用的图标文件'
$btnCleanIcons.Location = New-Object System.Drawing.Point(746, 50)
$btnCleanIcons.Size = New-Object System.Drawing.Size(170, 30)
$panelTop.Controls.Add($btnCleanIcons)

# 内层选项卡：未设置 / 已设置（已设置好的文件夹处理完会自动归档到右边）
$tabsInner = New-Object System.Windows.Forms.TabControl
$tabsInner.Dock = 'Fill'
$tabsInner.Padding = New-Object System.Drawing.Point(16, 4)
$tabUnset = New-Object System.Windows.Forms.TabPage
$tabUnset.Text = '  未设置的文件夹  '
$tabUnset.BackColor = [System.Drawing.Color]::White
$tabSet = New-Object System.Windows.Forms.TabPage
$tabSet.Text = '  已设置的文件夹  '
$tabSet.BackColor = [System.Drawing.Color]::White
$tabsInner.TabPages.Add($tabUnset)
$tabsInner.TabPages.Add($tabSet)
$tabBatch.Controls.Add($tabsInner)
$tabsInner.BringToFront()

function New-FolderListView {
    param([string]$NameColumnWidth = 240)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines = $false
    $lv.MultiSelect = $true
    $lv.HideSelection = $false
    $lv.BorderStyle = 'None'
    $lv.Scrollable = $true
    [void]$lv.Columns.Add('文件夹', 210)
    [void]$lv.Columns.Add('当前图标', 78)
    [void]$lv.Columns.Add('候选', 52)
    [void]$lv.Columns.Add('使用的应用 / 图标来源', 270)
    [void]$lv.Columns.Add('判定依据', 340)
    return $lv
}

$lvUnset = New-FolderListView -NameColumnWidth 240
$tabUnset.Controls.Add($lvUnset)
$lvSet = New-FolderListView -NameColumnWidth 240
$tabSet.Controls.Add($lvSet)

$script:BatchRows = @{}

function Get-DepthValue {
    switch ($cmbDepth.SelectedIndex) {
        0 { return 1 }
        1 { return 2 }
        default { return 3 }
    }
}

function Get-ActiveBatchList {
    if ($tabsInner.SelectedIndex -eq 1) { return $lvSet }
    return $lvUnset
}

function Update-BatchButtons {
    $lv = Get-ActiveBatchList
    $hasItems = $lv.Items.Count -gt 0
    $btnAutoAll.Enabled = ($lvUnset.Items.Count -gt 0)
    $btnApplySelected.Enabled = ($lv.SelectedItems.Count -gt 0)
    $btnRevertSelected.Enabled = ($lv.SelectedItems.Count -gt 0)
}

# 清理图标存放目录里已不再被任何文件夹引用的 .ico
function Clear-UnusedIcons {
    $used = New-Object System.Collections.Generic.HashSet[string]
    $roots = @()
    foreach ($row in @($lvUnset.Items) + @($lvSet.Items)) { $roots += $row.Tag.Dir }
    foreach ($dir in $roots) {
        try {
            $cur = [FolderIconTool.FolderIconManager]::GetCurrentIconResource($dir)
            if (-not $cur) { continue }
            $p = ($cur -replace ',\s*-?\d+\s*$', '').Trim('"')
            if ($p) { [void]$used.Add($p.ToLowerInvariant()) }
        } catch { }
    }
    $removed = 0
    Get-ChildItem $script:IconStore -File -Filter '*.ico' -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $used.Contains($_.FullName.ToLowerInvariant())) {
            try { Remove-Item $_.FullName -Force; $removed++ } catch { }
        }
    }
    return $removed
}

$tabsInner.Add_SelectedIndexChanged({
    Update-BatchButtons
    $n1 = $lvUnset.Items.Count
    $n2 = $lvSet.Items.Count
    Set-Status "未设置 $n1 个，已设置 $n2 个。"
})

# ---------- 扫描 ----------
$btnScan.Add_Click({
    $rootPath = $txtRoot.Text.Trim()
    if (-not (Test-Path -LiteralPath $rootPath)) {
        [System.Windows.Forms.MessageBox]::Show('路径不存在：' + $rootPath, '提示', 'OK', 'Warning') | Out-Null
        return
    }
    $lvUnset.Items.Clear()
    $lvSet.Items.Clear()
    $script:BatchRows = @{}
    Update-BatchButtons
    $btnScan.Enabled = $false
    Set-Status '正在扫描...'

    $depth = Get-DepthValue
    $dirs = @(Get-ChildItem -LiteralPath $rootPath -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notmatch '^(\$RECYCLE\.BIN|System Volume Information)$' })

    $i = 0
    foreach ($d in $dirs) {
        $i++
        Set-Status ("正在扫描 ({0}/{1})：{2}" -f $i, $dirs.Count, $d.Name)

        # 已有自定义图标的文件夹归入「已设置」，其余归入「未设置」
        $current = [FolderIconTool.FolderIconManager]::GetCurrentIconResource($d.FullName)
        $alreadySet = [bool]$current

        $cands = @()
        if (-not $alreadySet) {
            try { $cands = @([FolderIconTool.CandidateFinder]::Find($d.FullName, $depth)) } catch { }
        }

        $item = New-Object System.Windows.Forms.ListViewItem($d.Name)
        $item.SubItems.Add($(if ($alreadySet) { '已自定义' } else { '默认' })) | Out-Null
        $item.SubItems.Add($(if ($alreadySet) { '—' } else { $cands.Count.ToString() })) | Out-Null

        $statusKind = 'skip'
        if ($alreadySet) {
            # 已设置的：显示它当前用的图标来源
            $iconSrc = $current
            if ($iconSrc) {
                # IconResource 形如 "路径,索引"，去掉索引部分
                $iconSrc = ($iconSrc -replace ',\s*-?\d+\s*$', '').Trim('"')
            }
            $item.SubItems.Add($(if ($iconSrc) { $iconSrc } else { '未知' })) | Out-Null
            $item.SubItems.Add('已设置图标') | Out-Null
            $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 60)
            $statusKind = 'done'
        }
        elseif ($cands.Count -eq 0) {
            $item.SubItems.Add('—') | Out-Null
            $item.SubItems.Add('文件夹内没有 .exe') | Out-Null
            $item.ForeColor = [System.Drawing.Color]::Gray
        } else {
            $explain = ''
            $need = $false
            try { $need = [FolderIconTool.CandidateFinder]::NeedsUserChoice($cands, [ref]$explain) } catch { $need = $true }
            $item.SubItems.Add($cands[0].FileName) | Out-Null
            $item.SubItems.Add($explain) | Out-Null
            if ($need) {
                $statusKind = 'ask'
                $item.ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 0)
                $item.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 235)
            } else {
                $statusKind = 'ok'
            }
        }

        $item.Tag = @{ Dir = $d.FullName; Candidates = $cands; Kind = $statusKind }
        if ($alreadySet) { [void]$lvSet.Items.Add($item) } else { [void]$lvUnset.Items.Add($item) }
        $script:BatchRows[$d.FullName] = $item
    }

    $btnScan.Enabled = $true
    Update-BatchButtons
    $okCount = @($lvUnset.Items | Where-Object { $_.Tag.Kind -eq 'ok' }).Count
    $askCount = @($lvUnset.Items | Where-Object { $_.Tag.Kind -eq 'ask' }).Count
    $noExeCount = @($lvUnset.Items | Where-Object { $_.Tag.Kind -eq 'skip' }).Count
    Set-Status ("扫描完成：未设置 {0} 个（可自动判定 {1}，需你选择 {2}，无 .exe {3}），已设置 {4} 个。" -f `
        $lvUnset.Items.Count, $okCount, $askCount, $noExeCount, $lvSet.Items.Count)
})

foreach ($lv in @($lvUnset, $lvSet)) {
    $lv.Add_SelectedIndexChanged({ Update-BatchButtons })
    $lv.Add_DoubleClick({
        $list = $this
        if ($list.SelectedItems.Count -eq 0) { return }
        Show-PickDialog $list.SelectedItems[0]
    })
    $lv.Add_KeyDown({
        if ($_.KeyCode -eq 'Return') {
            $list = $this
            if ($list.SelectedItems.Count -gt 0) { Show-PickDialog $list.SelectedItems[0] }
        }
    })
}

$btnBrowseRoot.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择要批量处理的父文件夹（例如 E:\）'
    if ($dlg.ShowDialog() -eq 'OK') { $txtRoot.Text = $dlg.SelectedPath }
})

$btnRefreshCache.Add_Click({
    Set-Status '正在通知资源管理器刷新图标...'
    [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
    Start-Sleep -Milliseconds 600
    Set-Status '已发送刷新通知。若图标仍未更新，请按 F5 刷新资源管理器窗口，或点击「重建图标缓存」。' 'DarkGreen'
})

$btnCleanIcons.Add_Click({
    if ($lvUnset.Items.Count -eq 0 -and $lvSet.Items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先扫描一次，这样才能知道哪些图标文件还在使用。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "将删除图标存放目录里没有被任何文件夹引用的 .ico。`r`n`r`n只会删除工具自己生成的缓存文件，不影响目录里其它文件。继续吗？",
        '清理未使用的图标文件', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Set-Status '正在清理...'
    try {
        $n = Clear-UnusedIcons
        $left = @(Get-ChildItem $script:IconStore -File -Filter '*.ico' -ErrorAction SilentlyContinue).Count
        Set-Status ("已清理 {0} 个未使用的图标文件，剩余 {1} 个。" -f $n, $left) 'DarkGreen'
    } catch {
        Set-Status ('清理失败：' + $_.Exception.Message) 'Red'
    }
})

# ---------- 应用图标 ----------

# 把已设置好的行从「未设置」页归档到「已设置」页
function Move-RowToSetTab {
    param([System.Windows.Forms.ListViewItem]$Row)
    if (-not $Row) { return }
    if ($Row.ListView -eq $lvSet) { return }
    if ($Row.ListView) { $Row.ListView.Items.Remove($Row) }
    [void]$lvSet.Items.Add($Row)
}

function Move-RowToUnsetTab {
    param([System.Windows.Forms.ListViewItem]$Row)
    if (-not $Row) { return }
    if ($Row.ListView -eq $lvUnset) { return }
    if ($Row.ListView) { $Row.ListView.Items.Remove($Row) }
    [void]$lvUnset.Items.Add($Row)
}

function Set-IconForFolder {
    param([string]$FolderPath, [string]$SourcePath, [System.Windows.Forms.ListViewItem]$Row)
    $iconPath = Get-IconStorePath $FolderPath
    [FolderIconTool.FolderIconManager]::Apply($FolderPath, $SourcePath, $iconPath, $false)
    if ($Row) {
        $Row.SubItems[1].Text = '已自定义'
        $Row.SubItems[3].Text = $SourcePath
        $Row.SubItems[4].Text = '已设置图标'
        $Row.Tag.Kind = 'done'
        $Row.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 60)
        $Row.BackColor = [System.Drawing.Color]::White
        Move-RowToSetTab $Row
    }
}

function Apply-BatchItem {
    param([System.Windows.Forms.ListViewItem]$Row)
    $info = $Row.Tag
    # 已设置过的行双击后直接打开选择窗口，方便换图标
    if ($info.Kind -eq 'done') {
        return (Show-PickDialog $Row)
    }
    if ($info.Candidates.Count -eq 0) { return $false }
    $explain = ''
    $need = [FolderIconTool.CandidateFinder]::NeedsUserChoice($info.Candidates, [ref]$explain)
    if ($need) {
        # 需要用户选择
        return (Show-PickDialog $Row)
    }
    Set-IconForFolder $info.Dir $info.Candidates[0].Path $Row
    return $true
}

$btnApplySelected.Add_Click({
    $lv = Get-ActiveBatchList
    if ($lv.SelectedItems.Count -eq 0) { return }
    $ok = 0; $fail = 0
    $rows = @($lv.SelectedItems)
    foreach ($row in $rows) {
        try {
            if (Apply-BatchItem $row) { $ok++ }
        } catch {
            $fail++
            $row.SubItems[4].Text = '失败：' + $_.Exception.Message
            $row.ForeColor = [System.Drawing.Color]::Red
        }
    }
    [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
    Update-BatchButtons
    Set-Status ("已设置 {0} 个，失败 {1} 个。未设置 {2} 个，已设置 {3} 个。" -f `
        $ok, $fail, $lvUnset.Items.Count, $lvSet.Items.Count) 'DarkGreen'
})

$btnRevertSelected.Add_Click({
    $lv = Get-ActiveBatchList
    if ($lv.SelectedItems.Count -eq 0) { return }
    $n = 0
    foreach ($row in @($lv.SelectedItems)) {
        $dir = $row.Tag.Dir
        try {
            [FolderIconTool.FolderIconManager]::Revert($dir, $true)
            $icon = Get-IconStorePath $dir
            if (Test-Path $icon) { Remove-Item $icon -Force -ErrorAction SilentlyContinue }
            $row.SubItems[1].Text = '默认'
            $row.SubItems[3].Text = '—'
            $row.SubItems[4].Text = '已恢复默认图标'
            $row.ForeColor = [System.Drawing.Color]::Gray
            $row.BackColor = [System.Drawing.Color]::White
            $row.Tag.Kind = 'skip'
            # 恢复后重新分析候选，方便再次设置
            try {
                $again = @([FolderIconTool.CandidateFinder]::Find($dir, 2))
                $row.Tag.Candidates = $again
                $row.SubItems[2].Text = $again.Count.ToString()
                if ($again.Count -gt 0) {
                    $explain = ''
                    $need = [FolderIconTool.CandidateFinder]::NeedsUserChoice($again, [ref]$explain)
                    $row.SubItems[3].Text = $again[0].FileName
                    $row.SubItems[4].Text = $explain
                    if ($need) {
                        $row.Tag.Kind = 'ask'
                        $row.ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 0)
                        $row.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 235)
                    } else {
                        $row.Tag.Kind = 'ok'
                        $row.ForeColor = [System.Drawing.Color]::Black
                    }
                } else {
                    $row.SubItems[3].Text = '—'
                    $row.SubItems[4].Text = '文件夹内没有 .exe'
                }
            } catch { }
            Move-RowToUnsetTab $row
            $n++
        } catch { }
    }
    [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
    Update-BatchButtons
    Set-Status ("已恢复 {0} 个文件夹的默认图标，并移回「未设置」页。" -f $n) 'DarkGreen'
})

$btnAutoAll.Add_Click({
    $rows = @($lvUnset.Items | Where-Object { $_.Tag.Kind -eq 'ok' })
    if ($rows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "「未设置」页里没有可自动判定的文件夹。`r`n`r`n橙色的条目需要你双击手动选择，灰条目里没有 .exe。",
            '提示', 'OK', 'Information') | Out-Null
        return
    }
    $btnAutoAll.Enabled = $false
    $ok = 0; $fail = 0; $i = 0
    foreach ($row in $rows) {
        $i++
        Set-Status ("正在设置 ({0}/{1})：{2}" -f $i, $rows.Count, $row.Text)
        try { Set-IconForFolder $row.Tag.Dir $row.Tag.Candidates[0].Path $row; $ok++ }
        catch {
            $fail++
            $row.SubItems[4].Text = '失败：' + $_.Exception.Message
            $row.ForeColor = [System.Drawing.Color]::Red
        }
    }
    [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
    $btnAutoAll.Enabled = $true
    Update-BatchButtons
    Set-Status ("自动设置完成：成功 {0} 个，失败 {1} 个，已归入「已设置」页。剩余未设置 {2} 个。" -f `
        $ok, $fail, $lvUnset.Items.Count) 'DarkGreen'
})

# =========================================================
# 选项卡二：单个文件夹
# =========================================================
$tabOne = New-Object System.Windows.Forms.TabPage
$tabOne.Text = '  单个文件夹  '
$tabOne.BackColor = [System.Drawing.Color]::White
$tabs.TabPages.Add($tabOne)

$panelOneTop = New-Object System.Windows.Forms.Panel
$panelOneTop.Dock = 'Top'
$panelOneTop.Height = 52
$panelOneTop.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
$panelOneTop.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 8)
$tabOne.Controls.Add($panelOneTop)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text = '文件夹：'
$lblFolder.Location = New-Object System.Drawing.Point(14, 17)
$lblFolder.AutoSize = $true
$panelOneTop.Controls.Add($lblFolder)

$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(76, 14)
$txtFolder.Width = 520
$panelOneTop.Controls.Add($txtFolder)

$btnBrowseFolder = New-Object System.Windows.Forms.Button
$btnBrowseFolder.Text = '浏览...'
$btnBrowseFolder.Location = New-Object System.Drawing.Point(604, 13)
$btnBrowseFolder.Size = New-Object System.Drawing.Size(72, 26)
$panelOneTop.Controls.Add($btnBrowseFolder)

$btnAnalyze = New-Object System.Windows.Forms.Button
$btnAnalyze.Text = '分析'
$btnAnalyze.Location = New-Object System.Drawing.Point(684, 13)
$btnAnalyze.Size = New-Object System.Drawing.Size(72, 26)
$btnAnalyze.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnAnalyze.ForeColor = [System.Drawing.Color]::White
$btnAnalyze.FlatStyle = 'Flat'
$panelOneTop.Controls.Add($btnAnalyze)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = '在资源管理器中打开'
$btnOpenFolder.Location = New-Object System.Drawing.Point(764, 13)
$btnOpenFolder.Size = New-Object System.Drawing.Size(150, 26)
$panelOneTop.Controls.Add($btnOpenFolder)

$splitOne = New-Object System.Windows.Forms.SplitContainer
$splitOne.Dock = 'Fill'
$splitOne.SplitterDistance = 620
$splitOne.FixedPanel = 'None'
$tabOne.Controls.Add($splitOne)
$splitOne.BringToFront()

# 左侧：候选列表
$lvCands = New-Object System.Windows.Forms.ListView
$lvCands.Dock = 'Fill'
$lvCands.View = 'Details'
$lvCands.FullRowSelect = $true
$lvCands.MultiSelect = $false
$lvCands.HideSelection = $false
$lvCands.BorderStyle = 'None'
[void]$lvCands.Columns.Add('可执行文件', 210)
[void]$lvCands.Columns.Add('大小', 80)
[void]$lvCands.Columns.Add('类型', 80)
[void]$lvCands.Columns.Add('匹配度', 70)
[void]$lvCands.Columns.Add('判定依据', 240)
$splitOne.Panel1.Controls.Add($lvCands)

$lvCands.SmallImageList = $script:SharedIcons
$lvCands.LargeImageList = $script:SharedIcons

# 右侧：预览与操作
$panelRight = New-Object System.Windows.Forms.Panel
$panelRight.Dock = 'Fill'
$panelRight.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
$splitOne.Panel2.Controls.Add($panelRight)

$lblPreviewTitle = New-Object System.Windows.Forms.Label
$lblPreviewTitle.Text = '图标预览'
$lblPreviewTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$lblPreviewTitle.Location = New-Object System.Drawing.Point(16, 12)
$lblPreviewTitle.AutoSize = $true
$panelRight.Controls.Add($lblPreviewTitle)

$lblPreviewHint = New-Object System.Windows.Forms.Label
$lblPreviewHint.Text = '（同一图标在资源管理器各种视图下的显示效果）'
$lblPreviewHint.Location = New-Object System.Drawing.Point(16, 34)
$lblPreviewHint.AutoSize = $true
$lblPreviewHint.ForeColor = [System.Drawing.Color]::Gray
$panelRight.Controls.Add($lblPreviewHint)

$previewBox = New-Object System.Windows.Forms.PictureBox
$previewBox.Location = New-Object System.Drawing.Point(16, 58)
$previewBox.Size = New-Object System.Drawing.Size(400, 132)
$previewBox.BorderStyle = 'FixedSingle'
$previewBox.BackColor = [System.Drawing.Color]::White
$previewBox.SizeMode = 'Normal'
$panelRight.Controls.Add($previewBox)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Location = New-Object System.Drawing.Point(16, 200)
$lblInfo.Size = New-Object System.Drawing.Size(400, 90)
$lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$panelRight.Controls.Add($lblInfo)

$btnApplyOne = New-Object System.Windows.Forms.Button
$btnApplyOne.Text = '把选中程序设为文件夹图标'
$btnApplyOne.Location = New-Object System.Drawing.Point(16, 300)
$btnApplyOne.Size = New-Object System.Drawing.Size(220, 36)
$btnApplyOne.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnApplyOne.ForeColor = [System.Drawing.Color]::White
$btnApplyOne.FlatStyle = 'Flat'
$btnApplyOne.Enabled = $false
$panelRight.Controls.Add($btnApplyOne)

$btnApplyBest = New-Object System.Windows.Forms.Button
$btnApplyBest.Text = '自动判定并设置'
$btnApplyBest.Location = New-Object System.Drawing.Point(244, 300)
$btnApplyBest.Size = New-Object System.Drawing.Size(160, 36)
$btnApplyBest.Enabled = $false
$panelRight.Controls.Add($btnApplyBest)

$btnUseIconFile = New-Object System.Windows.Forms.Button
$btnUseIconFile.Text = '用图标文件设置（.ico / 图片）...'
$btnUseIconFile.Location = New-Object System.Drawing.Point(16, 344)
$btnUseIconFile.Size = New-Object System.Drawing.Size(258, 32)
$panelRight.Controls.Add($btnUseIconFile)

$btnRevertOne = New-Object System.Windows.Forms.Button
$btnRevertOne.Text = '恢复默认图标'
$btnRevertOne.Location = New-Object System.Drawing.Point(282, 344)
$btnRevertOne.Size = New-Object System.Drawing.Size(122, 32)
$panelRight.Controls.Add($btnRevertOne)

$btnRefreshOne = New-Object System.Windows.Forms.Button
$btnRefreshOne.Text = '刷新图标显示'
$btnRefreshOne.Location = New-Object System.Drawing.Point(16, 382)
$btnRefreshOne.Size = New-Object System.Drawing.Size(160, 32)
$panelRight.Controls.Add($btnRefreshOne)

$btnOpenIni = New-Object System.Windows.Forms.Button
$btnOpenIni.Text = '查看 desktop.ini'
$btnOpenIni.Location = New-Object System.Drawing.Point(184, 382)
$btnOpenIni.Size = New-Object System.Drawing.Size(140, 32)
$panelRight.Controls.Add($btnOpenIni)

$btnRebuildCache = New-Object System.Windows.Forms.Button
$btnRebuildCache.Text = '重建图标缓存'
$btnRebuildCache.Location = New-Object System.Drawing.Point(184, 386)
$btnRebuildCache.Size = New-Object System.Drawing.Size(140, 32)
$panelRight.Controls.Add($btnRebuildCache)

# ---------- 预览绘制 ----------
function Update-Preview {
    param([string]$SourcePath, [string]$FolderPath)
    if ($previewBox.Image) { $previewBox.Image.Dispose(); $previewBox.Image = $null }
    if (-not $SourcePath -or -not (Test-Path -LiteralPath $SourcePath)) { return }
    Draw-PreviewStrip -Box $previewBox -Path $SourcePath -Caption '同一图标在各种尺寸下的显示效果'
}

function Refresh-FolderTab {
    param([string]$FolderPath)
    if (-not (Test-Path -LiteralPath $FolderPath)) { return }
    Set-Status '正在分析文件夹...'
    $lvCands.Items.Clear()
    $script:CurrentCands = @()

    $cands = @()
    try { $cands = @([FolderIconTool.CandidateFinder]::Find($FolderPath, 2)) } catch { }
    $script:CurrentCands = $cands

    # 若该文件夹已设置过图标，先把当前图标显示出来
    $currentIcon = $null
    try {
        $cur = [FolderIconTool.FolderIconManager]::GetCurrentIconResource($FolderPath)
        if ($cur) {
            $cur = ($cur -replace ',\s*-?\d+\s*$', '').Trim('"')
            if (Test-Path -LiteralPath $cur) { $currentIcon = $cur }
        }
    } catch { }

    if ($cands.Count -eq 0) {
        if ($currentIcon) {
            Update-Preview $currentIcon $FolderPath
            $lblInfo.Text = "该文件夹当前已设置图标，来源：`r`n$currentIcon`r`n`r`n文件夹内没有找到 .exe，`r`n可点「恢复默认图标」撤销。"
        } else {
            if ($previewBox.Image) { $previewBox.Image.Dispose(); $previewBox.Image = $null }
            $lblInfo.Text = "该文件夹（及其一级子文件夹）内没有找到 .exe 文件。`r`n无法提取应用程序图标。"
        }
        $btnApplyOne.Enabled = $false
        $btnApplyBest.Enabled = $false
        Set-Status '没有找到可执行文件。'
        return
    }

    $explain = ''
    $need = [FolderIconTool.CandidateFinder]::NeedsUserChoice($cands, [ref]$explain)

    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $item = New-Object System.Windows.Forms.ListViewItem($c.FileName)
        $item.SubItems.Add((Format-Size $c.Size)) | Out-Null
        $item.SubItems.Add((Get-CandidateKind $c.Pe)) | Out-Null
        $item.SubItems.Add($c.Score.ToString()) | Out-Null
        $item.SubItems.Add($c.Reason) | Out-Null
        $idx = Get-IconIndex -Path $c.Path -Size 32
        if ($idx -ge 0) { $item.ImageIndex = $idx }
        if ($i -eq 0 -and -not $need) {
            $item.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
            $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 60)
        }
        $item.Tag = $c
        [void]$lvCands.Items.Add($item)
    }

    $extra = ''
    if ($currentIcon) { $extra = "`r`n`r`n当前图标来源：$currentIcon" }
    if (-not $need) {
        $lvCands.Items[0].Selected = $true
        $lblInfo.Text = "自动判定结果：$($cands[0].FileName)`r`n$($cands[0].Reason)`r`n`r`n直接点「自动判定并设置」即可。$extra"
    } else {
        $lvCands.Items[0].Selected = $true
        $lblInfo.Text = "有 $($cands.Count) 个候选程序，无法确定哪个是应用本体。`r`n请在左侧选择你认为的主程序，再点「把选中程序设为文件夹图标」。$extra"
    }
    # 代码设置 Selected 不会触发 SelectedIndexChanged，必须手动刷新一次预览
    $lvCands.Select()
    $lvCands.EnsureVisible(0)
    Update-Preview $cands[0].Path $FolderPath
    $btnApplyOne.Enabled = $true
    $btnApplyBest.Enabled = $true
    Set-Status "分析完成，共 $($cands.Count) 个可执行文件。"
}

$btnBrowseFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择要设置图标的文件夹'
    if ($txtFolder.Text.Trim() -and (Test-Path -LiteralPath $txtFolder.Text.Trim())) { $dlg.SelectedPath = $txtFolder.Text.Trim() }
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtFolder.Text = $dlg.SelectedPath
        Refresh-FolderTab $dlg.SelectedPath
    }
})

$btnAnalyze.Add_Click({
    $p = $txtFolder.Text.Trim()
    if ($script:SelfTest) { Write-Host "SELFTEST: 分析处理器已执行，读到路径 = '$p'" }
    if (-not (Test-Path -LiteralPath $p)) {
        if ($script:SelfTest) { Write-Host "SELFTEST: 路径不存在，直接返回" }
        [System.Windows.Forms.MessageBox]::Show('文件夹不存在：' + $p, '提示', 'OK', 'Warning') | Out-Null
        return
    }
    Refresh-FolderTab $p
})

$txtFolder.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { $btnAnalyze.PerformClick() } })

$lvCands.Add_SelectedIndexChanged({
    if ($lvCands.SelectedItems.Count -eq 0) { return }
    $c = $lvCands.SelectedItems[0].Tag
    Update-Preview $c.Path $txtFolder.Text.Trim()
    $lblInfo.Text = "$($c.FileName)`r`n路径：$($c.Path)`r`n大小：$(Format-Size $c.Size)　类型：$(Get-CandidateKind $c.Pe)　匹配度：$($c.Score)`r`n依据：$(if ($c.Reason) { $c.Reason } else { '无特殊特征' })"
})

$btnOpenFolder.Add_Click({
    $p = $txtFolder.Text.Trim()
    if (Test-Path -LiteralPath $p) { Start-Process explorer.exe -ArgumentList "`"$p`"" }
})

# 选一个本地的 .ico / 图片 / 程序文件作为图标来源
function Select-IconSourceFile {
    param([string]$Title = '选择图标来源文件（.ico / .exe / 图片）')
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = $Title
    $ofd.Filter = '所有支持的格式 (*.ico;*.exe;*.dll;*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.ico;*.exe;*.dll;*.png;*.jpg;*.jpeg;*.bmp;*.gif|' +
                  '图标文件 (*.ico)|*.ico|' +
                  '程序文件 (*.exe;*.dll)|*.exe;*.dll|' +
                  '图片文件 (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif|' +
                  '所有文件 (*.*)|*.*'
    if ($ofd.ShowDialog() -ne 'OK') { return $null }
    return $ofd.FileName
}

$btnUseIconFile.Add_Click({
    $p = $txtFolder.Text.Trim()
    if (-not (Test-Path -LiteralPath $p)) {
        [System.Windows.Forms.MessageBox]::Show('请先选择一个有效的文件夹。', '提示', 'OK', 'Warning') | Out-Null
        return
    }
    $src = Select-IconSourceFile
    if (-not $src) { return }
    Set-Status "正在生成图标并设置：$(Split-Path $src -Leaf)"
    try {
        $iconPath = Get-IconStorePath $p
        [FolderIconTool.FolderIconManager]::Apply($p, $src, $iconPath, $false)
        [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
        Update-Preview $src $p
        Set-Status "已设置：$p  <-  $(Split-Path $src -Leaf)" 'DarkGreen'
    } catch {
        [System.Windows.Forms.MessageBox]::Show("设置失败：`r`n$($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
        Set-Status '设置失败。' 'Red'
    }
})

$btnApplyOne.Add_Click({
    $p = $txtFolder.Text.Trim()
    if ($lvCands.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先在左侧选择一个可执行文件。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $c = $lvCands.SelectedItems[0].Tag
    Set-Status "正在生成图标并设置：$($c.FileName)"
    try {
        $iconPath = Get-IconStorePath $p
        [FolderIconTool.FolderIconManager]::Apply($p, $c.Path, $iconPath, $false)
        [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
        Set-Status "已设置：$p  <-  $($c.FileName)。若资源管理器未立即更新，按 F5 刷新即可。" 'DarkGreen'
    } catch {
        [System.Windows.Forms.MessageBox]::Show("设置失败：`r`n$($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
        Set-Status '设置失败。' 'Red'
    }
})

$btnApplyBest.Add_Click({
    $p = $txtFolder.Text.Trim()
    if ($script:CurrentCands.Count -eq 0) { return }
    $explain = ''
    $need = [FolderIconTool.CandidateFinder]::NeedsUserChoice($script:CurrentCands, [ref]$explain)
    if ($need) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "自动判定不确定：`r`n$explain`r`n`r`n仍然使用评分最高的「$($script:CurrentCands[0].FileName)」吗？",
            '需要确认', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
    }
    $c = $script:CurrentCands[0]
    Set-Status "正在生成图标并设置：$($c.FileName)"
    try {
        $iconPath = Get-IconStorePath $p
        [FolderIconTool.FolderIconManager]::Apply($p, $c.Path, $iconPath, $false)
        [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
        Set-Status "已设置：$p  <-  $($c.FileName)" 'DarkGreen'
    } catch {
        [System.Windows.Forms.MessageBox]::Show("设置失败：`r`n$($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
    }
})

$btnRevertOne.Add_Click({
    $p = $txtFolder.Text.Trim()
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        [FolderIconTool.FolderIconManager]::Revert($p, $true)
        $icon = Get-IconStorePath $p
        if (Test-Path $icon) { Remove-Item $icon -Force -ErrorAction SilentlyContinue }
        [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
        Set-Status "已恢复 $p 的默认文件夹图标。" 'DarkGreen'
    } catch {
        [System.Windows.Forms.MessageBox]::Show("恢复失败：`r`n$($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
    }
})

$btnRefreshOne.Add_Click({
    $p = $txtFolder.Text.Trim()
    if ($p -and (Test-Path -LiteralPath $p)) {
        [FolderIconTool.FolderIconManager]::NotifyFolderChanged($p)
        # 更新修改时间，促使资源管理器重新评估该目录
        try { (Get-Item -LiteralPath $p -Force).LastWriteTime = Get-Date } catch { }
    }
    [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
    Set-Status '已发送刷新通知。若仍未更新，请按 F5 刷新资源管理器窗口，或点「重建图标缓存」。' 'DarkGreen'
})

$btnOpenIni.Add_Click({
    $p = $txtFolder.Text.Trim()
    $ini = Join-Path $p 'desktop.ini'
    if (Test-Path -LiteralPath $ini) { Start-Process notepad.exe -ArgumentList "`"$ini`"" }
    else { [System.Windows.Forms.MessageBox]::Show("该文件夹没有 desktop.ini：`r`n$ini", '提示', 'OK', 'Information') | Out-Null }
})

$btnRebuildCache.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "重建图标缓存会删除本机图标缓存数据库（iconcache*.db）。`r`n`r`n" +
        "资源管理器会在几秒内自动重建缓存，过程中新设置的文件夹图标会立即显示，`r`n" +
        "桌面与已打开的窗口可能有极短暂的重绘。`r`n`r`n" +
        "只有在图标改完却不更新时才需要使用。继续吗？",
        '确认重建图标缓存', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    Set-Status '正在删除图标缓存...'
    try {
        $deleted = 0; $failed = 0
        $msg = [FolderIconTool.FolderIconManager]::DeleteIconCache([ref]$deleted, [ref]$failed)
        Set-Status $msg $(if ($failed -eq 0) { 'DarkGreen' } else { 'DarkGoldenrod' })
        if ($failed -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                $msg + "`r`n`r`n提示：若反复失败，可先关闭所有资源管理器窗口再试。",
                '图标缓存', 'OK', 'Information') | Out-Null
        }
    } catch {
        Set-Status ('重建失败：' + $_.Exception.Message) 'Red'
    }
})

# =========================================================
# 选择对话框
#   双击文件夹后打开，既可以挑文件夹内的 exe，
#   也可以浏览到任意位置的 .ico / 图片，或打开资源管理器去找
# =========================================================
function Show-PickDialog {
    param([System.Windows.Forms.ListViewItem]$Row)

    $dir = $Row.Tag.Dir
    $allCands = @()
    if ($Row.Tag.Candidates) { $allCands = @($Row.Tag.Candidates) }
    # 已设置的文件夹在扫描时没有分析候选，这里补上
    if ($allCands.Count -eq 0) {
        try { $allCands = @([FolderIconTool.CandidateFinder]::Find($dir, 2)) } catch { }
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "为文件夹选择图标 —— $(Split-Path $dir -Leaf)"
    $dlg.Size = New-Object System.Drawing.Size(940, 640)
    $dlg.MinimumSize = New-Object System.Drawing.Size(880, 560)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.Font = $script:DefaultFont

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "文件夹：$dir"
    $lbl.Location = New-Object System.Drawing.Point(14, 10)
    $lbl.Size = New-Object System.Drawing.Size(900, 20)
    $lbl.AutoEllipsis = $true
    $dlg.Controls.Add($lbl)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = '从下面选一个程序作为图标来源；如果列表里没有想要的，可以点「从文件选择图标」挑一个 .ico 或图片。'
    $lblHint.Location = New-Object System.Drawing.Point(14, 32)
    $lblHint.Size = New-Object System.Drawing.Size(900, 20)
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $dlg.Controls.Add($lblHint)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(14, 58)
    $lv.Size = New-Object System.Drawing.Size(620, 470)
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.HideSelection = $false
    $lv.SmallImageList = $script:SharedIcons
    [void]$lv.Columns.Add('可执行文件 / 图标来源', 250)
    [void]$lv.Columns.Add('大小', 80)
    [void]$lv.Columns.Add('类型', 80)
    [void]$lv.Columns.Add('匹配度', 70)
    [void]$lv.Columns.Add('说明', 130)
    $dlg.Controls.Add($lv)

    $preview = New-Object System.Windows.Forms.PictureBox
    $preview.Location = New-Object System.Drawing.Point(648, 58)
    $preview.Size = New-Object System.Drawing.Size(268, 180)
    $preview.BorderStyle = 'FixedSingle'
    $preview.BackColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($preview)

    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object System.Drawing.Point(648, 246)
    $info.Size = New-Object System.Drawing.Size(268, 282)
    $info.Text = '尚未选择。'
    $dlg.Controls.Add($info)

    $script:DlgInfo = $info
    $script:DlgPreview = $preview
    $script:DlgList = $lv
    $script:DlgFolder = $dir
    $script:DlgRow = $Row

    # 往列表里放一行（exe 候选 或 手动挑选的图标文件都走这里）
    function Add-DlgRow {
        param(
            [string]$Path,
            [string]$FileName,
            [string]$TypeText,
            [string]$ScoreText,
            [string]$NoteText,
            [bool]$Recommended = $false,
            [bool]$IsExeCandidate = $false
        )
        $item = New-Object System.Windows.Forms.ListViewItem($FileName)
        $sizeText = '—'
        try { $sizeText = Format-Size (Get-Item -LiteralPath $Path -Force).Length } catch { }
        $item.SubItems.Add($sizeText) | Out-Null
        $item.SubItems.Add($TypeText) | Out-Null
        $item.SubItems.Add($ScoreText) | Out-Null
        $item.SubItems.Add($NoteText) | Out-Null
        $idx = Get-IconIndex -Path $Path -Size 32
        if ($idx -ge 0) { $item.ImageIndex = $idx }
        if ($Recommended) {
            $item.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
            $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 60)
        }
        $item.Tag = @{
            Path = $Path; FileName = $FileName; Note = $NoteText
            IsExe = $IsExeCandidate; Score = $ScoreText
        }
        [void]$lv.Items.Add($item)
        return $item
    }

    for ($i = 0; $i -lt $allCands.Count; $i++) {
        $c = $allCands[$i]
        $note = ''
        if ($i -eq 0) { $note = '★ 推荐' }
        if ($c.IsHelper) { if ($note) { $note += ' / ' } ; $note += '疑似辅助程序' }
        [void](Add-DlgRow -Path $c.Path -FileName $c.FileName -TypeText (Get-CandidateKind $c.Pe) `
            -ScoreText $c.Score.ToString() -NoteText $note -Recommended ($i -eq 0) -IsExeCandidate $true)
    }
    if ($allCands.Count -eq 0) {
        $lblHint.Text = '这个文件夹里没有找到 .exe。请点「从文件选择图标」挑一个 .ico 或图片，或用「打开所在文件夹」自己找。'
    }

    # 选中项变化 → 刷新右侧预览
    function Update-DlgSel {
        if ($lv.SelectedItems.Count -eq 0) { return }
        $t = $lv.SelectedItems[0].Tag
        Draw-PreviewStrip -Box $preview -Path $t.Path -Caption '图标在各种尺寸下的效果'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("文件夹：")
        [void]$sb.AppendLine("  $dir")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("将用作图标：")
        [void]$sb.AppendLine("  $($t.FileName)")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("完整路径：")
        [void]$sb.AppendLine("  $($t.Path)")
        if ($t.IsExe) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("匹配度：$($t.Score)")
            [void]$sb.AppendLine("说明：$($t.Note)")
        }
        $info.Text = $sb.ToString()
    }

    $lv.Add_SelectedIndexChanged({ Update-DlgSel })

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '使用这个图标'
    $btnOk.Location = New-Object System.Drawing.Point(648, 545)
    $btnOk.Size = New-Object System.Drawing.Size(268, 38)
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.FlatStyle = 'Flat'
    $btnOk.Add_Click({
        if ($lv.SelectedItems.Count -gt 0) { $dlg.DialogResult = 'OK' }
        else { [System.Windows.Forms.MessageBox]::Show('请先在左侧选择一项。', '提示', 'OK', 'Information') | Out-Null }
    })
    $dlg.Controls.Add($btnOk)

    $btnPickFile = New-Object System.Windows.Forms.Button
    $btnPickFile.Text = '从文件选择图标...'
    $btnPickFile.Location = New-Object System.Drawing.Point(14, 545)
    $btnPickFile.Size = New-Object System.Drawing.Size(170, 38)
    $btnPickFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = '选择图标来源文件（.ico / .exe / 图片）'
        $ofd.Filter = '所有支持的格式 (*.ico;*.exe;*.dll;*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.ico;*.exe;*.dll;*.png;*.jpg;*.jpeg;*.bmp;*.gif|' +
                      '图标文件 (*.ico)|*.ico|' +
                      '程序文件 (*.exe;*.dll)|*.exe;*.dll|' +
                      '图片文件 (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif|' +
                      '所有文件 (*.*)|*.*'
        if ($ofd.ShowDialog() -ne 'OK') { return }
        $path = $ofd.FileName
        if (-not [FolderIconTool.IconExtractor]::IsSupportedIconSource($path)) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "这个文件类型可能无法提取图标：`r`n$(Split-Path $path -Leaf)`r`n`r`n仍然尝试使用吗？",
                '提示', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
        $name = Split-Path $path -Leaf
        $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        $typeText = switch ($ext) {
            '.ico' { '图标文件' }
            '.exe' { '程序' }
            '.dll' { '动态库' }
            { $_ -in '.png', '.jpg', '.jpeg', '.bmp', '.gif', '.tif', '.tiff', '.webp' } { '图片' }
            default { '未知' }
        }
        Add-DlgRow -Path $path -FileName $name -TypeText $typeText -ScoreText '—' -NoteText '手动挑选' | Out-Null
        $lv.Items[$lv.Items.Count - 1].Selected = $true
        $lv.Select()
        $lv.EnsureVisible($lv.Items.Count - 1)
        Update-DlgSel
    })
    $dlg.Controls.Add($btnPickFile)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '打开所在文件夹'
    $btnBrowse.Location = New-Object System.Drawing.Point(194, 545)
    $btnBrowse.Size = New-Object System.Drawing.Size(150, 38)
    $btnBrowse.Add_Click({
        try { Start-Process explorer.exe -ArgumentList "`"$dir`"" } catch { }
    })
    $dlg.Controls.Add($btnBrowse)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(354, 545)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 38)
    $btnCancel.Add_Click({ $dlg.DialogResult = 'Cancel' })
    $dlg.Controls.Add($btnCancel)

    $lv.Add_DoubleClick({
        if ($lv.SelectedItems.Count -gt 0) { $dlg.DialogResult = 'OK' }
    })

    if ($lv.Items.Count -gt 0) {
        $lv.Items[0].Selected = $true
        $lv.Select()
        Update-DlgSel
    }
    $dlg.CancelButton = $btnCancel

    $result = $dlg.ShowDialog($form)
    $chosenPath = $null
    $chosenName = ''
    if ($result -eq 'OK' -and $lv.SelectedItems.Count -gt 0) {
        $t = $lv.SelectedItems[0].Tag
        $chosenPath = $t.Path
        $chosenName = $t.FileName
    }
    $dlg.Dispose()
    $script:DlgPreview = $null
    $script:DlgInfo = $null
    $script:DlgList = $null

    if (-not $chosenPath) { return $false }

    try {
        $iconPath = Get-IconStorePath $dir
        [FolderIconTool.FolderIconManager]::Apply($dir, $chosenPath, $iconPath, $false)
        if ($Row) {
            $Row.SubItems[1].Text = '已自定义'
            $Row.SubItems[3].Text = $chosenPath
            $Row.SubItems[4].Text = '手动选择'
            $Row.Tag.Kind = 'done'
            $Row.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 60)
            $Row.BackColor = [System.Drawing.Color]::White
            Move-RowToSetTab $Row
        }
        [FolderIconTool.FolderIconManager]::RefreshShellIconCache()
        Set-Status "已设置：$dir  <-  $chosenName" 'DarkGreen'
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show("设置失败：`r`n$($_.Exception.Message)", '错误', 'OK', 'Error') | Out-Null
        return $false
    }
}

# ---------- 资源清理 ----------
$form.Add_FormClosing({
    if ($previewBox.Image) { $previewBox.Image.Dispose() }
    $script:SharedIcons.Dispose()
})

# ---------- 启动 ----------
$form.Add_Shown({
    Set-Status '就绪。建议先点「开始扫描」看看 E 盘各文件夹的识别情况。'
})

if ($AutoScan -or $AutoCloseSeconds -gt 0) {
    # 演示/排错用：打开界面后自动扫描并可选自动关闭
    $form.Add_Shown({
        Start-Sleep -Milliseconds 800
        if ($AutoScan) {
            $txtRoot.Text = $AutoScan
            $btnScan.PerformClick()
        }
        if ($AutoCloseSeconds -gt 0) {
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = $AutoCloseSeconds * 1000
            $t.Add_Tick({
                $f = [System.Windows.Forms.Application]::OpenForms | Select-Object -First 1
                if ($f) { $f.Close() }
                $t.Stop()
            })
            $t.Start()
        }
    })
}

if ($SelfTest) {
    # 自检模式：构建界面后自动走一遍关键路径，用于确认界面与事件绑定没有运行时错误。
    # 注意：事件处理器运行在自己的作用域里，必须显式解析控件引用，
    # 否则处理器内会静默抛出“变量为 null”的异常而看不到任何提示。
    $script:SelfTestErrors = @()
    $form.Add_Shown({
        Start-Sleep -Milliseconds 900
        function ST-Find {
            param($Root, [Type]$Type)
            $q = New-Object System.Collections.Queue
            $q.Enqueue($Root)
            while ($q.Count -gt 0) {
                $c = $q.Dequeue()
                if ($c -is $Type) { return $c }
                foreach ($ch in $c.Controls) { $q.Enqueue($ch) }
            }
            return $null
        }
        function ST-FindAll {
            param($Root, [Type]$Type)
            $out = @()
            $q = New-Object System.Collections.Queue
            $q.Enqueue($Root)
            while ($q.Count -gt 0) {
                $c = $q.Dequeue()
                if ($c -is $Type) { $out += $c }
                foreach ($ch in $c.Controls) { $q.Enqueue($ch) }
            }
            return $out
        }

        try {
            $f = [System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like '*文件夹图标工具*' } | Select-Object -First 1
            $tabCtl = ST-Find $f ([System.Windows.Forms.TabControl])
            Write-Host "SELFTEST: 主选项卡数 = $($tabCtl.TabPages.Count)、名称 = $(($tabCtl.TabPages | ForEach-Object { $_.Text.Trim() }) -join ' / ')"

            # ---- A. 批量处理：扫描 + 未设置/已设置分栏 ----
            $tabCtl.SelectedIndex = 0
            Start-Sleep -Milliseconds 400
            $batchPage = $tabCtl.TabPages[0]
            $inner = ST-Find $batchPage ([System.Windows.Forms.TabControl])
            Write-Host "SELFTEST: 批量页内层选项卡 = $($inner.TabPages.Count) 个、名称 = $(($inner.TabPages | ForEach-Object { $_.Text.Trim() }) -join ' / ')"
            $lvs = ST-FindAll $inner ([System.Windows.Forms.ListView])
            Write-Host "SELFTEST: 批量页列表数量 = $($lvs.Count)（应为 2）"

            $btnScan = ST-FindAll $batchPage ([System.Windows.Forms.Button]) | Where-Object { $_.Text -eq '开始扫描' } | Select-Object -First 1
            if ($btnScan) {
                $btnScan.PerformClick()
                Start-Sleep -Milliseconds 3500
                $nUnset = $lvs[0].Items.Count
                $nSet = $lvs[1].Items.Count
                Write-Host "SELFTEST: 扫描后 未设置 = $nUnset 个、已设置 = $nSet 个"
                if ($nSet -eq 0) { Write-Host "SELFTEST-ERROR: 已设置的文件夹没有被归档到「已设置」页" }
                if ($nUnset -eq 0) { Write-Host "SELFTEST-ERROR: 未设置页为空，可能有归档错误" }
                if ($nSet -gt 0) {
                    $it = $lvs[1].Items[0]
                    Write-Host "SELFTEST: 已设置页首行 = '$($it.Text)' / 图标来源 = '$($it.SubItems[3].Text)'"
                }
            } else { Write-Host "SELFTEST-ERROR: 找不到开始扫描按钮" }

            # ---- B. 单个文件夹页：分析 + 预览 ----
            $tabCtl.SelectedIndex = 1
            Start-Sleep -Milliseconds 400
            $page = $tabCtl.TabPages[1]
            $txt = ST-Find $page ([System.Windows.Forms.TextBox])
            $btnGo = ST-FindAll $page ([System.Windows.Forms.Button]) | Where-Object { $_.Text -eq '分析' } | Select-Object -First 1
            $txt.Text = 'E:\HxD'
            $btnGo.PerformClick()
            Start-Sleep -Milliseconds 1500
            $lvOne = ST-Find (ST-Find $page ([System.Windows.Forms.SplitContainer])).Panel1 ([System.Windows.Forms.ListView])
            Write-Host "SELFTEST: 分析 E:\HxD 候选行数 = $($lvOne.Items.Count)、首行 = $(if ($lvOne.Items.Count) { $lvOne.Items[0].Text })"
            $pv = ST-Find $page ([System.Windows.Forms.PictureBox])
            Write-Host "SELFTEST: 预览图 = $(if ($pv.Image) { "$($pv.Image.Width)x$($pv.Image.Height)" } else { '空（异常）' })"

            # ---- C. 图标来源解析：ico / png ----
            $testIco = Join-Path $env:TEMP 'selftest-src.ico'
            Add-Type -AssemblyName System.Drawing
            $bmp = New-Object System.Drawing.Bitmap(64, 64)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.FillEllipse([System.Drawing.Brushes]::OrangeRed, 4, 4, 56, 56)
            $g.Dispose()
            $hicon = $bmp.GetHicon()
            $ico = [System.Drawing.Icon]::FromHandle($hicon)
            $fs = [System.IO.File]::Create($testIco)
            $ico.Save($fs)
            $fs.Close(); $ico.Dispose(); $bmp.Dispose()
            $testPng = Join-Path $env:TEMP 'selftest-src.png'
            $b2 = New-Object System.Drawing.Bitmap(200, 120)
            $g2 = [System.Drawing.Graphics]::FromImage($b2)
            $g2.Clear([System.Drawing.Color]::Transparent)
            $g2.FillRectangle([System.Drawing.Brushes]::SeaGreen, 10, 10, 180, 100)
            $g2.Dispose(); $b2.Save($testPng, [System.Drawing.Imaging.ImageFormat]::Png); $b2.Dispose()

            foreach ($src in @($testIco, $testPng, 'E:\HxD\HxD.exe')) {
                try {
                    $frames = [FolderIconTool.IconExtractor]::GetFrames($src)
                    Write-Host "SELFTEST: GetFrames('$(Split-Path $src -Leaf)') -> 尺寸 [$(($frames.Keys | Sort-Object) -join ',')]"
                    foreach ($k in $frames.Keys) { $frames[$k].Dispose() }
                } catch {
                    Write-Host "SELFTEST-ERROR: GetFrames('$src') 失败: $($_.Exception.Message)"
                }
            }
            # 实际把 png 设成 E:\HxD 的图标，验证端到端可用，然后还原
            try {
                $tmpFolder = Join-Path $env:TEMP 'selftest-folder'
                if (-not (Test-Path $tmpFolder)) { New-Item -ItemType Directory -Path $tmpFolder | Out-Null }
                $outIco = Join-Path $env:TEMP 'selftest-out.ico'
                [FolderIconTool.FolderIconManager]::Apply($tmpFolder, $testPng, $outIco, $false)
                Write-Host "SELFTEST: 用 PNG 设置文件夹图标 -> 成功，生成 ICO $((Get-Item $outIco).Length) 字节"
                Write-Host "SELFTEST: desktop.ini 内容 = $((Get-Content (Join-Path $tmpFolder 'desktop.ini') -Encoding Unicode) -join ' | ')"
                [FolderIconTool.FolderIconManager]::Revert($tmpFolder, $true)
                Write-Host "SELFTEST: 还原成功，desktop.ini 存在 = $(Test-Path (Join-Path $tmpFolder 'desktop.ini'))"
                Remove-Item $tmpFolder -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "SELFTEST-ERROR: PNG 端到端测试失败: $($_.Exception.Message)"
            }
            Remove-Item $testIco, $testPng -Force -ErrorAction SilentlyContinue

            # ---- D. 选择对话框：确认能打开、列出行、按「取消」能正常关闭 ----
            $tabCtl.SelectedIndex = 0
            Start-Sleep -Milliseconds 300
            $target = $null
            foreach ($lvw in @($lvs[1], $lvs[0])) {
                foreach ($it in $lvw.Items) { if ($it.Text -eq 'HxD') { $target = $it; break } }
                if ($target) { break }
            }
            if (-not $target -and $lvs[1].Items.Count -gt 0) { $target = $lvs[1].Items[0] }
            if ($target) {
                Write-Host "SELFTEST: 准备为 '$($target.Text)' 打开选择对话框"
                $closeTimer = New-Object System.Windows.Forms.Timer
                $closeTimer.Interval = 2500
                $closeTimer.Add_Tick({
                    $d = [System.Windows.Forms.Application]::OpenForms |
                         Where-Object { $_.Text -like '为文件夹选择图标*' } | Select-Object -First 1
                    if ($d) {
                        $q = New-Object System.Collections.Queue
                        $q.Enqueue($d)
                        $dlgLv = $null; $dlgPv = $null; $btns = @(); $infoLbl = $null
                        while ($q.Count -gt 0) {
                            $c = $q.Dequeue()
                            if ($c -is [System.Windows.Forms.ListView] -and -not $dlgLv) { $dlgLv = $c }
                            if ($c -is [System.Windows.Forms.PictureBox] -and -not $dlgPv) { $dlgPv = $c }
                            if ($c -is [System.Windows.Forms.Button]) { $btns += $c.Text }
                            foreach ($ch in $c.Controls) { $q.Enqueue($ch) }
                        }
                        Write-Host "SELFTEST: 对话框候选行数 = $(if ($dlgLv) { $dlgLv.Items.Count } else { '未找到列表' })"
                        Write-Host "SELFTEST: 对话框按钮 = $($btns -join ' / ')"
                        Write-Host "SELFTEST: 对话框预览图 = $(if ($dlgPv -and $dlgPv.Image) { "$($dlgPv.Image.Width)x$($dlgPv.Image.Height)" } else { '空' })"
                        $d.DialogResult = 'Cancel'
                        $d.Close()
                    }
                    $closeTimer.Stop()
                })
                $closeTimer.Start()
                $r = Show-PickDialog $target
                Write-Host "SELFTEST: 对话框已关闭，返回值 = $r（取消应为 False）"
                $closeTimer.Dispose()
            }
        } catch {
            Write-Host "SELFTEST-ERROR: $($_.Exception.Message)"
            Write-Host "SELFTEST-ERROR 堆栈: $($_.ScriptStackTrace)"
        }
        Write-Host "SELFTEST: 自检结束"
        $f = [System.Windows.Forms.Application]::OpenForms | Select-Object -First 1
        if ($f) { $f.Close() }
    })
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 30000
    $timer.Add_Tick({
        $f = [System.Windows.Forms.Application]::OpenForms | Select-Object -First 1
        if ($f) { Write-Host "SELFTEST: 超时强制关闭"; $f.Close() }
    })
    $timer.Start()
}

[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
