<#
.SYNOPSIS
    Analyse Disk Storage - High-performance storage analysis and interactive HTML reporting utility.
.DESCRIPTION
    Performs a single-pass scan using native .NET I/O APIs to analyze directory and file storage.
    Generates an interactive, clean light-themed HTML report featuring top storage consumers (folders and files),
    interactive sorting, searching, jump-to-highlight navigation, and hierarchical drilldowns.
.PARAMETER Path
    The target root directory path to analyze.
.PARAMETER MaxDepth
    The maximum depth to expand and render in the hierarchy report (1 - 10).
.PARAMETER OutHtml
    Custom file path for the output HTML report.
.PARAMETER NoOpen
    Suppresses auto-opening the generated HTML report in the default browser.
.PARAMETER Version
    Displays the tool name and version, then exits.
.EXAMPLE
    .\AnalyseDiskStorage.ps1 -Path "C:\Data" -MaxDepth 2
.EXAMPLE
    .\AnalyseDiskStorage.ps1 -Version
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [string]$Path,

    [Parameter(Position = 1)]
    [ValidateRange(1, 10)]
    [int]$MaxDepth = -1,

    [Parameter()]
    [string]$OutHtml,

    [Parameter()]
    [switch]$NoOpen,

    [Parameter()]
    [switch]$Version
)

# ==============================================================================
# TOOL METADATA & CONSTANTS
# ==============================================================================
$TOOL_NAME    = "Analyse Disk Storage"
$TOOL_VERSION = "1.0.0"

if ($Version) {
    Write-Host "$TOOL_NAME v$TOOL_VERSION (PowerShell $($PSVersionTable.PSVersion))" -ForegroundColor Cyan
    return
}

# ==============================================================================
# DATA STRUCTURES
# ==============================================================================
class FileItem {
    [string]$FullPath
    [string]$Name
    [long]$Bytes = 0
    [string]$DomId = ""

    FileItem([string]$fullPath, [string]$name, [long]$bytes, [string]$domId) {
        $this.FullPath = $fullPath
        $this.Name = $name
        $this.Bytes = $bytes
        $this.DomId = $domId
    }
}

class StorageNode {
    [string]$FullPath
    [string]$Name
    [int]$Depth
    [long]$DirectBytes = 0
    [long]$TotalBytes = 0
    [long]$FileCount = 0
    [long]$DirCount = 0
    [string]$DomId = ""
    [System.Collections.Generic.List[StorageNode]]$Children
    [System.Collections.Generic.List[FileItem]]$Files

    StorageNode([string]$fullPath, [string]$name, [int]$depth, [string]$domId) {
        $this.FullPath = $fullPath
        $this.Name = $name
        $this.Depth = $depth
        $this.DomId = $domId
        $this.Children = [System.Collections.Generic.List[StorageNode]]::new()
        $this.Files = [System.Collections.Generic.List[FileItem]]::new()
    }
}

class ScanContext {
    [long]$TotalFilesProcessed = 0
    [long]$TotalFoldersProcessed = 0
    [long]$TotalAccessErrors = 0
    [long]$NodeCounter = 0
    [System.Collections.Generic.List[StorageNode]]$AllFolders
    [System.Collections.Generic.List[FileItem]]$AllFiles
    [System.Collections.Generic.List[string]]$ErrorDetails

    ScanContext() {
        $this.AllFolders = [System.Collections.Generic.List[StorageNode]]::new()
        $this.AllFiles = [System.Collections.Generic.List[FileItem]]::new()
        $this.ErrorDetails = [System.Collections.Generic.List[string]]::new()
    }

    [string] GetNextId() {
        $this.NodeCounter++
        return "node_$($this.NodeCounter)"
    }
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
function Format-ByteUnit {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Show-HeaderBanner {
    Clear-Host
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "  $TOOL_NAME - v$TOOL_VERSION" -ForegroundColor Yellow
    Write-Host "  High-Performance Disk Engine & Reporting Tool" -ForegroundColor DarkGray
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Measure-DirectoryTree {
    param(
        [System.IO.DirectoryInfo]$DirInfo,
        [int]$CurrentDepth,
        [ScanContext]$Context
    )

    $domId = $Context.GetNextId()
    $node = [StorageNode]::new($DirInfo.FullName, $DirInfo.Name, $CurrentDepth, $domId)
    $Context.TotalFoldersProcessed++
    $Context.AllFolders.Add($node)

    # 1. Direct files enumeration
    try {
        foreach ($file in $DirInfo.EnumerateFiles()) {
            $len = $file.Length
            $fileDomId = $Context.GetNextId()
            $fileObj = [FileItem]::new($file.FullName, $file.Name, $len, $fileDomId)
            
            $node.Files.Add($fileObj)
            $Context.AllFiles.Add($fileObj)

            $node.DirectBytes += $len
            $node.FileCount++
            $Context.TotalFilesProcessed++
        }
    }
    catch {
        $Context.TotalAccessErrors++
        if ($Context.ErrorDetails.Count -lt 10) {
            $Context.ErrorDetails.Add("$($DirInfo.FullName): $($_.Exception.Message)")
        }
    }

    # 2. Recurse into subdirectories
    try {
        foreach ($subDir in $DirInfo.EnumerateDirectories()) {
            # Skip junction points and directory symlinks to avoid double-counting and loops
            if ($subDir.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                continue
            }

            $childNode = Measure-DirectoryTree -DirInfo $subDir -CurrentDepth ($CurrentDepth + 1) -Context $Context
            $node.Children.Add($childNode)
            $node.DirCount += (1 + $childNode.DirCount)
            $node.FileCount += $childNode.FileCount
            $node.TotalBytes += $childNode.TotalBytes
        }
    }
    catch {
        $Context.TotalAccessErrors++
        if ($Context.ErrorDetails.Count -lt 10) {
            $Context.ErrorDetails.Add("$($DirInfo.FullName): $($_.Exception.Message)")
        }
    }

    $node.TotalBytes += $node.DirectBytes

    # Live 2-line console progress tracker (100% ASCII-safe)
    if ($Context.TotalFoldersProcessed % 15 -eq 0) {
        $winWidth = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width)
        $blankLine = " " * ($winWidth - 1)

        # Line 1: Metrics
        $metricText = "  |-- Metrics : Folders: {0:N0}  |  Files: {1:N0}  |  Errors: {2:N0}" -f `
            $Context.TotalFoldersProcessed, $Context.TotalFilesProcessed, $Context.TotalAccessErrors
        
        # Line 2: Path Truncation based on visual terminal window (Middle-Ellipsis)
        $prefix = "  \-- Current : "
        $maxPathLen = [Math]::Max(15, $winWidth - $prefix.Length - 2)
        $curPath = $DirInfo.FullName
        if ($curPath.Length -gt $maxPathLen) {
            $tailLen = [Math]::Min(20, [int]($maxPathLen * 0.3))
            $headLen = $maxPathLen - $tailLen - 3
            if ($headLen -gt 0) {
                $curPath = $curPath.Substring(0, $headLen) + "..." + $curPath.Substring($curPath.Length - $tailLen)
            } else {
                $curPath = "..." + $curPath.Substring($curPath.Length - $maxPathLen + 3)
            }
        }
        $pathText = $prefix + $curPath

        # Reposition and render Line 1
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $script:ScanStatusPos.Y)
        Write-Host $blankLine -NoNewline
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $script:ScanStatusPos.Y)
        Write-Host $metricText -ForegroundColor Cyan -NoNewline

        # Reposition and render Line 2
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $script:ScanStatusPos.Y + 1)
        Write-Host $blankLine -NoNewline
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $script:ScanStatusPos.Y + 1)
        Write-Host $pathText -ForegroundColor DarkGray -NoNewline
    }

    return $node
}

# High-Performance Fast HTML Tree Builder using StringBuilder
function Add-HtmlHierarchy {
    param(
        [System.Text.StringBuilder]$Sb,
        [StorageNode]$Node,
        [long]$RootTotalBytes,
        [int]$RenderMaxDepth
    )

    $percent = if ($RootTotalBytes -gt 0) { [Math]::Round(($Node.TotalBytes / $RootTotalBytes) * 100, 2) } else { 0 }
    $formattedTotal = Format-ByteUnit $Node.TotalBytes
    $encodedPath = [System.Net.WebUtility]::HtmlEncode($Node.FullPath)
    $encodedName = [System.Net.WebUtility]::HtmlEncode($Node.Name)

    $barClass = if ($percent -ge 30) { "bar-danger" } elseif ($percent -ge 15) { "bar-warn" } else { "bar-normal" }
    $hasSubElements = ($Node.Depth -lt $RenderMaxDepth) -and (($Node.Children.Count -gt 0) -or ($Node.Files.Count -gt 0))

    if ($hasSubElements) {
        $openAttr = if ($Node.Depth -lt 1) { "open" } else { "" }
        [void]$Sb.Append("<li class='tree-node-item' id='$($Node.DomId)' data-type='folder' data-depth='$($Node.Depth)' data-size='$($Node.TotalBytes)' data-name='$encodedName'>")
        [void]$Sb.Append("<details $openAttr>")
        [void]$Sb.Append("<summary class='tree-row'>")
        [void]$Sb.Append("<div class='folder-col'><span class='icon icon-folder'></span> <span class='name-text'>$encodedName</span></div>")
        [void]$Sb.Append("<div class='meta-group'>")
        [void]$Sb.Append("<span class='size-total'>$formattedTotal</span>")
        [void]$Sb.Append("<span class='badge-pct'>$percent%</span>")
        [void]$Sb.Append("<div class='bar-container'><div class='bar-fill $barClass' style='width: ${percent}%;'></div></div>")
        [void]$Sb.Append("<button type='button' class='btn-table-action' data-path='$encodedPath' onclick='copyPath(this)' title='Copy Full Path'>Copy</button>")
        [void]$Sb.Append("</div>")
        [void]$Sb.Append("</summary>")
        [void]$Sb.Append("<ul class='tree-children-container'>")

        # Sort default by Name
        $sortedFolders = $Node.Children | Sort-Object Name
        foreach ($child in $sortedFolders) {
            Add-HtmlHierarchy -Sb $Sb -Node $child -RootTotalBytes $RootTotalBytes -RenderMaxDepth $RenderMaxDepth
        }

        $sortedFiles = $Node.Files | Sort-Object Name
        foreach ($file in $sortedFiles) {
            $fPercent = if ($RootTotalBytes -gt 0) { [Math]::Round(($file.Bytes / $RootTotalBytes) * 100, 2) } else { 0 }
            $fSizeFormatted = Format-ByteUnit $file.Bytes
            $fEncodedPath = [System.Net.WebUtility]::HtmlEncode($file.FullPath)
            $fEncodedName = [System.Net.WebUtility]::HtmlEncode($file.Name)
            $fBarClass = if ($fPercent -ge 30) { "bar-danger" } elseif ($fPercent -ge 15) { "bar-warn" } else { "bar-normal" }

            [void]$Sb.Append("<li class='tree-node-item file-node' id='$($file.DomId)' data-type='file' data-depth='$($Node.Depth + 1)' data-size='$($file.Bytes)' data-name='$fEncodedName'>")
            [void]$Sb.Append("<div class='tree-row file-row'>")
            [void]$Sb.Append("<div class='folder-col'><span class='icon icon-file'></span> <span class='name-text'>$fEncodedName</span></div>")
            [void]$Sb.Append("<div class='meta-group'>")
            [void]$Sb.Append("<span class='size-total'>$fSizeFormatted</span>")
            [void]$Sb.Append("<span class='badge-pct'>$fPercent%</span>")
            [void]$Sb.Append("<div class='bar-container'><div class='bar-fill $fBarClass' style='width: ${fPercent}%;'></div></div>")
            [void]$Sb.Append("<button type='button' class='btn-table-action' data-path='$fEncodedPath' onclick='copyPath(this)' title='Copy Full Path'>Copy</button>")
            [void]$Sb.Append("</div>")
            [void]$Sb.Append("</div>")
            [void]$Sb.Append("</li>")
        }

        [void]$Sb.Append("</ul>")
        [void]$Sb.Append("</details>")
        [void]$Sb.Append("</li>")
    }
    else {
        [void]$Sb.Append("<li class='tree-node-item' id='$($Node.DomId)' data-type='folder' data-depth='$($Node.Depth)' data-size='$($Node.TotalBytes)' data-name='$encodedName'>")
        [void]$Sb.Append("<div class='tree-row leaf-row'>")
        [void]$Sb.Append("<div class='folder-col'><span class='icon icon-folder'></span> <span class='name-text'>$encodedName</span></div>")
        [void]$Sb.Append("<div class='meta-group'>")
        [void]$Sb.Append("<span class='size-total'>$formattedTotal</span>")
        [void]$Sb.Append("<span class='badge-pct'>$percent%</span>")
        [void]$Sb.Append("<div class='bar-container'><div class='bar-fill $barClass' style='width: ${percent}%;'></div></div>")
        [void]$Sb.Append("<button type='button' class='btn-table-action' data-path='$encodedPath' onclick='copyPath(this)' title='Copy Full Path'>Copy</button>")
        [void]$Sb.Append("</div>")
        [void]$Sb.Append("</div>")
        [void]$Sb.Append("</li>")
    }
}

function Read-ValidatedPrompt {
    param(
        [string]$PromptText,
        [scriptblock]$ValidationBlock
    )

    $bufWidth = [Math]::Max($Host.UI.RawUI.WindowSize.Width, 80)
    $blankRow = " " * ($bufWidth - 1)
    $topPos = $Host.UI.RawUI.CursorPosition.Y
    $lastError = $null

    while ($true) {
        # 1. Clear error line below prompt
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $topPos + 1)
        Write-Host $blankRow -NoNewline

        # 2. Print error message if one occurred
        if (-not [string]::IsNullOrWhiteSpace($lastError)) {
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $topPos + 1)
            Write-Host ">> $lastError" -ForegroundColor Red -NoNewline
        }

        # 3. Clear and render prompt line
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $topPos)
        Write-Host $blankRow -NoNewline
        $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $topPos)
        Write-Host "$PromptText" -NoNewline
        
        $val = [Console]::ReadLine()
        $lastError = & $ValidationBlock $val

        # 4. If valid, erase the error line and place cursor on the clean next line
        if ([string]::IsNullOrWhiteSpace($lastError)) {
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $topPos + 1)
            Write-Host $blankRow -NoNewline
            $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $topPos + 1)
            return $val
        }
    }
}

# ==============================================================================
# USER INPUT RESOLUTION
# ==============================================================================
Show-HeaderBanner

if ([string]::IsNullOrWhiteSpace($Path) -or (-not (Test-Path -LiteralPath $Path))) {
    $Path = Read-ValidatedPrompt -PromptText "Enter Target Directory Path: " -ValidationBlock {
        param($inputVal)
        if ([string]::IsNullOrWhiteSpace($inputVal)) { return "Path cannot be empty. Enter a valid path." }
        if (-not (Test-Path -LiteralPath $inputVal)) { return "Directory path does not exist." }
        return $null
    }
}

$resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
$rootInfo = [System.IO.DirectoryInfo]::new($resolvedPath)

if ($MaxDepth -lt 1) {
    $depthInput = Read-ValidatedPrompt -PromptText "Enter Analysis Depth (1-10): " -ValidationBlock {
        param($inputVal)
        if ([string]::IsNullOrWhiteSpace($inputVal)) { return "Depth cannot be empty. Enter a number between 1 and 10." }
        if ($inputVal -match '^\d+$' -and [int]$inputVal -ge 1 -and [int]$inputVal -le 10) { return $null }
        return "Invalid depth! Enter an integer between 1 and 10."
    }
    $MaxDepth = [int]$depthInput
}

# ==============================================================================
# SCAN EXECUTION
# ==============================================================================
Write-Host "`n[*] Scanning Storage Tree..." -ForegroundColor Cyan
$script:ScanStatusPos = $Host.UI.RawUI.CursorPosition
Write-Host "" # Reserve Line 1 (Metrics)
Write-Host "" # Reserve Line 2 (Path)

$scanTimer = [System.Diagnostics.Stopwatch]::StartNew()
$scanContext = [ScanContext]::new()
$rootNode = Measure-DirectoryTree -DirInfo $rootInfo -CurrentDepth 0 -Context $scanContext
$scanTimer.Stop()

# Clear live status tracker lines cleanly
$winWidth = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width)
$clearBlank = " " * ($winWidth - 1)
$Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $script:ScanStatusPos.Y - 1)
Write-Host $clearBlank -NoNewline
$Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $script:ScanStatusPos.Y)
Write-Host $clearBlank -NoNewline
$Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $script:ScanStatusPos.Y + 1)
Write-Host $clearBlank -NoNewline
$Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new(0, $script:ScanStatusPos.Y - 1)

$elapsed = $scanTimer.Elapsed
$formattedTime = "{0:00}:{1:00}:{2:00}.{3:000}" -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds, $elapsed.Milliseconds

# ==============================================================================
# TERMINAL OUTPUT (Structured Dashboard Layout)
# ==============================================================================
Write-Host "[+] Analysis Completed in $formattedTime" -ForegroundColor Green
Write-Host ""
Write-Host "STORAGE SUMMARY" -ForegroundColor Yellow
Write-Host ("-" * 50) -ForegroundColor DarkGray
Write-Host ("  * Total Size       : {0}" -f (Format-ByteUnit $rootNode.TotalBytes)) -ForegroundColor Cyan
Write-Host ("  * Total Files      : {0:N0}" -f $scanContext.TotalFilesProcessed)
Write-Host ("  * Total Folders    : {0:N0}" -f $scanContext.TotalFoldersProcessed)
Write-Host ("  * Access Errors    : {0:N0}" -f $scanContext.TotalAccessErrors) -ForegroundColor $(if ($scanContext.TotalAccessErrors -gt 0) { "Yellow" } else { "Gray" })
Write-Host ""

# Top 5 Subfolders CLI
Write-Host "TOP 5 LARGEST FOLDERS" -ForegroundColor Yellow
Write-Host ("-" * 70) -ForegroundColor DarkGray
Write-Host ("  {0,-4} {1,-28} {2,12} {3,10} {4,10}" -f "#", "Folder Name", "Total Size", "Usage %", "Files") -ForegroundColor DarkCyan
Write-Host ("-" * 70) -ForegroundColor DarkGray

$topSubFolders = $rootNode.Children | Sort-Object TotalBytes -Descending | Select-Object -First 5
if ($topSubFolders) {
    $idx = 1
    foreach ($f in $topSubFolders) {
        $pct = if ($rootNode.TotalBytes -gt 0) { "{0:N2} %" -f (($f.TotalBytes / $rootNode.TotalBytes) * 100) } else { "0.00 %" }
        $fName = $f.Name
        if ($fName.Length -gt 26) { $fName = $fName.Substring(0, 23) + "..." }
        Write-Host ("  {0,-4} {1,-28} {2,12} {3,10} {4,10:N0}" -f $idx, $fName, (Format-ByteUnit $f.TotalBytes), $pct, $f.FileCount)
        $idx++
    }
} else {
    Write-Host "  No subdirectories detected underneath root path." -ForegroundColor DarkGray
}
Write-Host ""

# Top 5 Files CLI
Write-Host "TOP 5 LARGEST FILES" -ForegroundColor Yellow
Write-Host ("-" * 70) -ForegroundColor DarkGray
Write-Host ("  {0,-4} {1,-28} {2,12} {3,10} {4,-12}" -f "#", "File Name", "Size", "Share %", "Location") -ForegroundColor DarkCyan
Write-Host ("-" * 70) -ForegroundColor DarkGray

$top5FilesCli = $scanContext.AllFiles | Sort-Object Bytes -Descending | Select-Object -First 5
if ($top5FilesCli) {
    $idx = 1
    foreach ($fi in $top5FilesCli) {
        $pct = if ($rootNode.TotalBytes -gt 0) { "{0:N2} %" -f (($fi.Bytes / $rootNode.TotalBytes) * 100) } else { "0.00 %" }
        $flName = $fi.Name
        if ($flName.Length -gt 26) { $flName = $flName.Substring(0, 23) + "..." }
        
        $loc = [System.IO.Path]::GetDirectoryName($fi.FullPath)
        if ($loc.Length -gt 12) { $loc = "..." + $loc.Substring($loc.Length - 9) }
        
        Write-Host ("  {0,-4} {1,-28} {2,12} {3,10} {4,-12}" -f $idx, $flName, (Format-ByteUnit $fi.Bytes), $pct, $loc)
        $idx++
    }
} else {
    Write-Host "  No files detected." -ForegroundColor DarkGray
}
Write-Host ""

# ==============================================================================
# HTML REPORT PREPARATION
# ==============================================================================
Write-Host "Generating HTML Report..." -NoNewline -ForegroundColor Cyan

# 1. Top 5 Largest Folders HTML
$top5Folders = $scanContext.AllFolders | Where-Object { $_.Depth -gt 0 } | Sort-Object TotalBytes -Descending | Select-Object -First 5
$topFolderRows = ""
$rankF = 1
foreach ($f in $top5Folders) {
    $pct = if ($rootNode.TotalBytes -gt 0) { [Math]::Round(($f.TotalBytes / $rootNode.TotalBytes) * 100, 2) } else { 0 }
    $encPath = [System.Net.WebUtility]::HtmlEncode($f.FullPath)
    $encName = [System.Net.WebUtility]::HtmlEncode($f.Name)
    $topFolderRows += @"
    <tr>
        <td class='rank-cell'>#$rankF</td>
        <td>
            <a href='javascript:void(0)' class='jump-link' onclick="jumpToNode('$($f.DomId)')"><b>$encName</b></a>
            <div class='path-subtext'>$encPath</div>
        </td>
        <td><b>$(Format-ByteUnit $f.TotalBytes)</b></td>
        <td>$pct%</td>
        <td>$($f.FileCount)</td>
        <td><button type='button' class='btn-table-action' data-path='$encPath' onclick='copyPath(this)'>Copy</button></td>
    </tr>
"@
    $rankF++
}
if ([string]::IsNullOrWhiteSpace($topFolderRows)) {
    $topFolderRows = "<tr><td colspan='6' style='text-align:center;color:#64748b;'>No subfolders found.</td></tr>"
}

# 2. Top 5 Largest Files HTML
$top5Files = $scanContext.AllFiles | Sort-Object Bytes -Descending | Select-Object -First 5
$topFileRows = ""
$rankFile = 1
foreach ($file in $top5Files) {
    $pct = if ($rootNode.TotalBytes -gt 0) { [Math]::Round(($file.Bytes / $rootNode.TotalBytes) * 100, 2) } else { 0 }
    $encPath = [System.Net.WebUtility]::HtmlEncode($file.FullPath)
    $encName = [System.Net.WebUtility]::HtmlEncode($file.Name)
    $topFileRows += @"
    <tr>
        <td class='rank-cell'>#$rankFile</td>
        <td>
            <a href='javascript:void(0)' class='jump-link' onclick="jumpToNode('$($file.DomId)')"><b>$encName</b></a>
            <div class='path-subtext'>$encPath</div>
        </td>
        <td><b>$(Format-ByteUnit $file.Bytes)</b></td>
        <td>$pct%</td>
        <td><button type='button' class='btn-table-action' data-path='$encPath' onclick='copyPath(this)'>Copy</button></td>
    </tr>
"@
    $rankFile++
}
if ([string]::IsNullOrWhiteSpace($topFileRows)) {
    $topFileRows = "<tr><td colspan='5' style='text-align:center;color:#64748b;'>No files found.</td></tr>"
}

# 3. Hierarchy Tree HTML with Fast StringBuilder
$treeSb = [System.Text.StringBuilder]::new(1024 * 512)
Add-HtmlHierarchy -Sb $treeSb -Node $rootNode -RootTotalBytes $rootNode.TotalBytes -RenderMaxDepth $MaxDepth
$treeHtml = $treeSb.ToString()

# Error Notice Block in Header (Only rendered if errors > 0)
$errorNoticeHtml = ""
if ($scanContext.TotalAccessErrors -gt 0) {
    $errListItems = ($scanContext.ErrorDetails | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join ""
    $errorNoticeHtml = @"
    <div class="warning-banner">
        <b>Warning:</b> $($scanContext.TotalAccessErrors) item(s) could not be accessed due to system permissions or locks.
        <details style="margin-top: 4px;">
            <summary style="cursor: pointer; color: var(--accent);">View details</summary>
            <ul style="padding-left: 20px; margin-top: 4px; font-size: 0.8rem; color: #b91c1c;">
                $errListItems
            </ul>
        </details>
    </div>
"@
}

if ([string]::IsNullOrWhiteSpace($OutHtml)) {
    $reportsDir = Join-Path $PSScriptRoot "Reports"
    if (-not (Test-Path -LiteralPath $reportsDir)) {
        New-Item -Path $reportsDir -ItemType Directory -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $cleanRootName = ($rootInfo.Name -replace '[\\/:*?"<>|]', '_')
    $OutHtml = Join-Path $reportsDir "DiskAnalysis_${cleanRootName}_${timestamp}.html"
}

# ==============================================================================
# HTML TEMPLATE (Light Theme, Modern Clean UI)
# ==============================================================================
$fullHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$TOOL_NAME - $($rootInfo.FullName)</title>
    <style>
        :root {
            --bg-body: #f8fafc;
            --bg-card: #ffffff;
            --border-color: #e2e8f0;
            --text-main: #0f172a;
            --text-muted: #64748b;
            --accent: #2563eb;
            --accent-hover: #1d4ed8;
            --accent-light: #eff6ff;
            --bar-normal: #3b82f6;
            --bar-warn: #f59e0b;
            --bar-danger: #ef4444;
            --row-hover: #f8fafc;
            --font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: var(--font-family); background-color: var(--bg-body); color: var(--text-main); padding: 32px 24px; line-height: 1.5; }
        .container { max-width: 1400px; margin: 0 auto; }

        /* HEADER */
        .page-header { margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--border-color); }
        .page-header h1 { font-size: 1.75rem; font-weight: 700; color: var(--text-main); letter-spacing: -0.02em; }
        .page-header p { color: var(--text-muted); font-size: 0.95rem; margin-top: 4px; }
        .page-header p b { color: var(--text-main); font-weight: 600; }
        
        .warning-banner { background: #fef2f2; border: 1px solid #fecaca; border-radius: 6px; padding: 10px 14px; margin-top: 10px; font-size: 0.85rem; color: #991b1b; }

        /* KPI CARDS */
        .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 28px; }
        .kpi-card { background: var(--bg-card); border: 1px solid var(--border-color); border-radius: 8px; padding: 18px 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.03); }
        .kpi-label { font-size: 0.75rem; color: var(--text-muted); text-transform: uppercase; font-weight: 700; letter-spacing: 0.05em; }
        .kpi-val { font-size: 1.4rem; font-weight: 700; margin-top: 6px; color: var(--accent); }

        /* SECTION CARDS & TABLES */
        .card-panel { background: var(--bg-card); border: 1px solid var(--border-color); border-radius: 8px; padding: 24px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.03); }
        .card-panel h2 { font-size: 1.15rem; font-weight: 700; color: var(--text-main); margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; }
        
        table.styled-table { width: 100%; border-collapse: collapse; font-size: 0.875rem; }
        table.styled-table th, table.styled-table td { padding: 10px 12px; text-align: left; border-bottom: 1px solid var(--border-color); }
        table.styled-table th { background-color: #f8fafc; color: var(--text-muted); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.03em; }
        table.styled-table tr:hover td { background-color: var(--row-hover); }
        .rank-cell { font-weight: 700; color: var(--accent); width: 44px; }
        .path-subtext { font-size: 0.75rem; color: var(--text-muted); margin-top: 2px; word-break: break-all; }
        
        /* JUMP LINKS & BUTTONS */
        .jump-link { color: var(--text-main); text-decoration: none; }
        .jump-link:hover { color: var(--accent); text-decoration: underline; }

        .btn { background: var(--bg-card); border: 1px solid var(--border-color); color: var(--text-main); padding: 7px 14px; border-radius: 6px; cursor: pointer; font-size: 0.85rem; font-weight: 500; transition: all 0.15s ease-in-out; }
        .btn:hover { background: var(--bg-body); border-color: #cbd5e1; }
        .btn-active { background: var(--accent-light); border-color: var(--accent); color: var(--accent); font-weight: 600; }
        
        .btn-table-action { background: #f1f5f9; border: 1px solid #e2e8f0; color: var(--text-main); padding: 4px 10px; border-radius: 4px; cursor: pointer; font-size: 0.75rem; font-weight: 600; transition: background 0.15s; }
        .btn-table-action:hover { background: #e2e8f0; }

        /* TREE VIEW */
        .tree-toolbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 18px; flex-wrap: wrap; gap: 12px; }
        .search-box { background: var(--bg-card); border: 1px solid var(--border-color); color: var(--text-main); padding: 8px 14px; border-radius: 6px; width: 320px; font-size: 0.875rem; }
        .search-box:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px rgba(37,99,235,0.1); }
        .tree-actions { display: flex; gap: 8px; }

        ul.tree-children-container { list-style: none; padding-left: 24px; }
        .card-panel > ul.tree-children-container { padding-left: 0; }
        li.tree-node-item { margin: 2px 0; }

        .tree-row { display: flex; align-items: center; justify-content: space-between; padding: 7px 10px; border-radius: 6px; cursor: pointer; user-select: none; transition: background 0.1s; }
        .tree-row:hover { background: var(--row-hover); }
        .file-row { cursor: default; }

        .folder-col { display: flex; align-items: center; gap: 8px; font-weight: 600; font-size: 0.9rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .file-node .folder-col { font-weight: 400; color: #334155; }
        
        .icon { display: inline-block; width: 14px; height: 14px; border-radius: 2px; flex-shrink: 0; }
        .icon-folder { background-color: #f59e0b; }
        .icon-file { background-color: #94a3b8; }

        .meta-group { display: flex; align-items: center; gap: 14px; font-size: 0.85rem; flex-shrink: 0; }
        .size-total { font-weight: 700; width: 85px; text-align: right; color: var(--text-main); }
        .badge-pct { font-size: 0.75rem; font-weight: 600; width: 48px; text-align: right; color: var(--text-muted); }

        .bar-container { width: 90px; height: 8px; background: #e2e8f0; border-radius: 4px; overflow: hidden; }
        .bar-fill { height: 100%; border-radius: 4px; }
        .bar-normal { background: var(--bar-normal); }
        .bar-warn { background: var(--bar-warn); }
        .bar-danger { background: var(--bar-danger); }

        /* TOAST NOTIFICATION */
        #toast { position: fixed; bottom: 24px; right: 24px; background: #0f172a; color: #fff; padding: 10px 18px; border-radius: 6px; font-weight: 600; font-size: 0.85rem; opacity: 0; pointer-events: none; transition: opacity 0.2s ease; z-index: 9999; box-shadow: 0 4px 12px rgba(0,0,0,0.15); }
        #toast.show { opacity: 1; }

        /* FOOTER (Centered) */
        .page-footer { margin-top: 36px; padding-top: 20px; border-top: 1px solid var(--border-color); font-size: 0.8rem; color: var(--text-muted); text-align: center; }
        
        .hidden-node { display: none !important; }
        .highlight-target { animation: flashNode 2.5s ease-out; }
        @keyframes flashNode {
            0% { background-color: #fef08a; }
            70% { background-color: #fef08a; }
            100% { background-color: transparent; }
        }
    </style>
</head>
<body>
    <div id="toast">Copied to Clipboard!</div>
    <div class="container">
        <header class="page-header">
            <h1>$TOOL_NAME</h1>
            <p>Target Folder: <b>$($rootInfo.FullName)</b></p>
            <p style="margin-top: 2px; font-size: 0.85rem; color: var(--text-muted);">
                Generated: <b>$([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"))</b> &nbsp;|&nbsp; System: <b>$env:COMPUTERNAME</b>
            </p>
            $errorNoticeHtml
        </header>

        <!-- KPI SUMMARY METRICS -->
        <section class="kpi-grid">
            <div class="kpi-card">
                <div class="kpi-label">Total Allocated Size</div>
                <div class="kpi-val">$(Format-ByteUnit $rootNode.TotalBytes)</div>
            </div>
            <div class="kpi-card">
                <div class="kpi-label">Analysis Depth</div>
                <div class="kpi-val">Level $MaxDepth</div>
            </div>
            <div class="kpi-card">
                <div class="kpi-label">Total Files</div>
                <div class="kpi-val">$("{0:N0}" -f $scanContext.TotalFilesProcessed)</div>
            </div>
            <div class="kpi-card">
                <div class="kpi-label">Total Folders</div>
                <div class="kpi-val">$("{0:N0}" -f $scanContext.TotalFoldersProcessed)</div>
            </div>
            <div class="kpi-card">
                <div class="kpi-label">Scan Runtime</div>
                <div class="kpi-val" style="font-size: 1.2rem; margin-top: 8px;">$formattedTime</div>
            </div>
        </section>

        <!-- 1. TOP 5 FOLDERS -->
        <section class="card-panel">
            <h2>Top 5 Highest Storage Consuming Folders</h2>
            <table class="styled-table">
                <thead>
                    <tr>
                        <th>#</th>
                        <th>Folder Name & Path</th>
                        <th>Total Size</th>
                        <th>Usage Share</th>
                        <th>Files Inside</th>
                        <th>Copy Path</th>
                    </tr>
                </thead>
                <tbody>
                    $topFolderRows
                </tbody>
            </table>
        </section>

        <!-- 2. TOP 5 FILES -->
        <section class="card-panel">
            <h2>Top 5 Largest Files</h2>
            <table class="styled-table">
                <thead>
                    <tr>
                        <th>#</th>
                        <th>File Name & Path</th>
                        <th>Size</th>
                        <th>Usage Share</th>
                        <th>Copy Path</th>
                    </tr>
                </thead>
                <tbody>
                    $topFileRows
                </tbody>
            </table>
        </section>

        <!-- 3. DETAILED HIERARCHICAL BREAKDOWN -->
        <section class="card-panel">
            <h2>Complete Storage Breakdown</h2>
            <div class="tree-toolbar">
                <input type="text" id="filterInput" class="search-box" placeholder="Filter folders & files instantly..." onkeyup="filterTree()">
                <div class="tree-actions">
                    <button type="button" class="btn" id="sortNameBtn" onclick="sortHierarchy('name')">Sort by Name</button>
                    <button type="button" class="btn" id="sortSizeBtn" onclick="sortHierarchy('size')">Sort by Size</button>
                    <button type="button" class="btn" onclick="setAllDetails(true)">Expand All</button>
                    <button type="button" class="btn" onclick="setAllDetails(false)">Collapse All</button>
                </div>
            </div>

            <ul class="tree-children-container" id="rootTree">
                $treeHtml
            </ul>
        </section>

        <!-- FOOTER -->
        <footer class="page-footer">
            <b>$TOOL_NAME - v$TOOL_VERSION</b>
        </footer>
    </div>

    <script>
        async function copyPath(btnElement) {
            const text = btnElement.getAttribute('data-path') || '';
            try {
                if (navigator.clipboard && window.isSecureContext) {
                    await navigator.clipboard.writeText(text);
                } else {
                    const tempInput = document.createElement('textarea');
                    tempInput.value = text;
                    tempInput.style.position = 'fixed';
                    tempInput.style.opacity = '0';
                    document.body.appendChild(tempInput);
                    tempInput.focus();
                    tempInput.select();
                    document.execCommand('copy');
                    document.body.removeChild(tempInput);
                }
                showToast("Path copied to clipboard!");
            } catch (err) {
                showToast("Failed to copy path.");
            }
        }

        function showToast(msg) {
            const toast = document.getElementById('toast');
            toast.textContent = msg;
            toast.classList.add('show');
            setTimeout(() => { toast.classList.remove('show'); }, 1800);
        }

        function setAllDetails(isOpen) {
            document.querySelectorAll('#rootTree details').forEach(el => el.open = isOpen);
        }

        function jumpToNode(elementId) {
            const target = document.getElementById(elementId);
            if (!target) {
                showToast("Item is deeper than the rendered depth limit.");
                return;
            }

            let parent = target.parentElement;
            while (parent && parent.id !== 'rootTree') {
                if (parent.tagName === 'DETAILS') parent.open = true;
                parent = parent.parentElement;
            }

            target.scrollIntoView({ behavior: 'smooth', block: 'center' });
            target.classList.remove('highlight-target');
            void target.offsetWidth;
            target.classList.add('highlight-target');
        }

        function filterTree() {
            const term = document.getElementById('filterInput').value.toLowerCase();
            const nodes = document.querySelectorAll('#rootTree li.tree-node-item');

            if (!term) {
                nodes.forEach(node => node.classList.remove('hidden-node'));
                return;
            }

            nodes.forEach(node => {
                const name = node.getAttribute('data-name')?.toLowerCase() || '';
                if (name.includes(term)) {
                    node.classList.remove('hidden-node');
                    let parent = node.parentElement;
                    while (parent && parent.id !== 'rootTree') {
                        if (parent.tagName === 'DETAILS') parent.open = true;
                        if (parent.classList.contains('tree-node-item')) parent.classList.remove('hidden-node');
                        parent = parent.parentElement;
                    }
                } else {
                    node.classList.add('hidden-node');
                }
            });
        }

        let currentSort = 'name';
        function sortHierarchy(criteria) {
            currentSort = criteria;
            document.getElementById('sortNameBtn').classList.toggle('btn-active', criteria === 'name');
            document.getElementById('sortSizeBtn').classList.toggle('btn-active', criteria === 'size');

            const containers = document.querySelectorAll('.tree-children-container');
            containers.forEach(container => {
                const items = Array.from(container.children).filter(el => el.tagName === 'LI');
                items.sort((a, b) => {
                    const typeA = a.getAttribute('data-type');
                    const typeB = b.getAttribute('data-type');
                    
                    if (typeA !== typeB) {
                        return typeA === 'folder' ? -1 : 1;
                    }

                    if (criteria === 'size') {
                        const sizeA = parseInt(a.getAttribute('data-size') || 0, 10);
                        const sizeB = parseInt(b.getAttribute('data-size') || 0, 10);
                        return sizeB - sizeA;
                    } else {
                        const nameA = a.getAttribute('data-name') || '';
                        const nameB = b.getAttribute('data-name') || '';
                        return nameA.localeCompare(nameB, undefined, { numeric: true, sensitivity: 'base' });
                    }
                });
                items.forEach(item => container.appendChild(item));
            });
        }

        document.getElementById('sortNameBtn').classList.add('btn-active');
    </script>
</body>
</html>
"@

$fullHtml | Out-File -FilePath $OutHtml -Encoding UTF8

# Wipe the 'Generating HTML Report...' line completely and print relative location
$clearRow = " " * ([Math]::Max(40, $Host.UI.RawUI.WindowSize.Width) - 1)
Write-Host ("`r$clearRow`r") -NoNewline

$displayReportPath = $OutHtml
if ($displayReportPath.StartsWith($PSScriptRoot)) {
    $displayReportPath = $displayReportPath.Substring($PSScriptRoot.Length).TrimStart('\', '/')
}

Write-Host "HTML Report generated: " -ForegroundColor Yellow -NoNewline
Write-Host "$displayReportPath" -ForegroundColor Cyan
Write-Host ""

if (-not $NoOpen) {
    Invoke-Item $OutHtml
}