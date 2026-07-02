[CmdletBinding()]
param(
    [ValidateSet("handoff", "validate", "next", "start", "show", "init", "add-task", "set-route", "advance", "add-design", "reject", "complete", "reopen", "deprecate", "check", "migrate")]
    [string]$Command = "handoff",

    [ValidateSet("PM", "CTO", "UX", "DEV", "QA")]
    [string]$Role = "DEV",

    [string]$Archive,

    [int]$TaskIndex = -1,
    [int]$TaskId = -1,

    [string]$Tasks,
    [string]$TasksFile,
    [string]$Title,
    [string]$Requirement,
    [string]$CurrentOwners,
    [string]$To,
    [string]$From,
    [Alias("Path")]
    [string]$DesignPath,
    [string]$Reason,

    [ValidateSet("json", "markdown")]
    [string]$Format = "json",

    [string]$OutFile
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$repoRoot = git rev-parse --show-toplevel

function ConvertTo-PortableJson {
    param($Object, [int]$Depth = 6)
    return ($Object | ConvertTo-Json -Depth $Depth -Compress)
}

function Write-ErrorResult {
    param(
        [string]$Code,
        [string]$Message,
        [int]$ExitCode = 1
    )

    ConvertTo-PortableJson @{
        success = $false
        error   = @{ code = $Code; message = $Message }
    } -Depth 3
    exit $ExitCode
}

function Resolve-ArchivePath {
    param([string]$ArchiveArg)

    if (-not [string]::IsNullOrWhiteSpace($ArchiveArg)) {
        $candidate = $ArchiveArg
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $repoRoot $candidate
        }
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        if ($ArchiveArg -match "\.\.\.$" -or $ArchiveArg -like "*<*>*") {
            $WarningPreference = "Continue"
            Write-Warning "Archive path '$ArchiveArg' contains placeholder, falling back to auto-discovery."
        }
        else {
            $WarningPreference = "Continue"
            Write-Warning "Archive directory not found: '$ArchiveArg', falling back to auto-discovery."
        }
    }

    $archiveRoot = Join-Path $repoRoot ".rdd/changes/archive"
    if (-not (Test-Path -LiteralPath $archiveRoot -PathType Container)) {
        Write-ErrorResult "ARCHIVE_ROOT_NOT_FOUND" "Archive root not found: .rdd/changes/archive" 2
    }

    $latest = Get-ChildItem -LiteralPath $archiveRoot -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        Write-ErrorResult "NO_ARCHIVES" "No archive directories found under .rdd/changes/archive" 2
    }

    return $latest.FullName
}

function Get-RelativePath {
    param([string]$Path)

    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    $root = $repoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($root.Length).Replace("\", "/")
    }
    return $fullPath.Replace("\", "/")
}

function Read-TextFile {
    param([string]$Path)
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Clean-Cell {
    param([string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ($Value -replace [regex]::Escape('`'), "" -replace '<br\s*/?>', " " -replace '\s+', " ").Trim()
}

function Parse-MarkdownTable {
    param(
        [string[]]$Lines,
        [string]$RequiredHeader
    )

    $headerIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\s*\|" -and $Lines[$i].Contains($RequiredHeader)) {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -lt 0 -or $headerIndex + 1 -ge $Lines.Count) {
        return @()
    }

    $headers = $Lines[$headerIndex].Trim().Trim("|").Split("|") | ForEach-Object { Clean-Cell $_ }
    $rows = @()

    for ($i = $headerIndex + 2; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -notmatch "^\s*\|") {
            break
        }

        $cells = $line.Trim().Trim("|").Split("|") | ForEach-Object { Clean-Cell $_ }
        if ($cells.Count -lt $headers.Count) {
            continue
        }

        $row = [ordered]@{}
        for ($j = 0; $j -lt $headers.Count; $j++) {
            $row[$headers[$j]] = $cells[$j]
        }
        $rows += [pscustomobject]$row
    }

    return $rows
}

function Get-DocField {
    param(
        [string]$Content,
        [string]$Name
    )

    $escaped = [regex]::Escape($Name)
    $patterns = @(
        ('(?m)^\s*-\s*\*\*' + $escaped + '\*\*[：:]\s*(.+?)\s*$'),
        ('(?m)^\s*\*\*' + $escaped + '\*\*[：:]\s*(.+?)\s*$')
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Content, $pattern)
        if ($match.Success) {
            return (Clean-Cell $match.Groups[1].Value)
        }
    }

    return $null
}

function Get-FirstHeading {
    param([string]$Content)

    $match = [regex]::Match($Content, '(?m)^#\s+(.+?)\s*$')
    if ($match.Success) {
        return (Clean-Cell $match.Groups[1].Value)
    }
    return $null
}

function Get-FlowControl {
    param([string]$Content)

    $owner = Get-DocField -Content $Content -Name "当前责任人"
    $docStatus = Get-DocField -Content $Content -Name "文档状态"
    $frontStatus = $null
    $frontMatch = [regex]::Match($Content, '(?m)^status:\s*(.+?)\s*$')
    if ($frontMatch.Success) {
        $frontStatus = Clean-Cell $frontMatch.Groups[1].Value
    }

    $status = $null
    if ($docStatus) {
        $status = $docStatus
    }
    elseif ($frontStatus) {
        $status = $frontStatus
    }

    $hasPendingRejection = $Content -match "待回应|待裁决"

    return @{
        owner = $owner
        status = $status
        hasPendingRejection = $hasPendingRejection
    }
}

function Get-Section {
    param(
        [string]$Content,
        [string]$HeadingPattern
    )

    $pattern = '(?m)^##\s+' + $HeadingPattern + '[ \t]*\r?\n([\s\S]*?)(?=^##\s+|\z)'
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return $null
}

function Get-InvolvedFiles {
    param([string]$Content)

    $files = New-Object System.Collections.Generic.List[string]
    $section = Get-Section -Content $Content -HeadingPattern '.*涉及文件.*'
    if ([string]::IsNullOrWhiteSpace($section)) {
        return @()
    }

    foreach ($match in [regex]::Matches($section, '`([^`]+)`')) {
        $value = Clean-Cell $match.Groups[1].Value
        if ($value -and -not $files.Contains($value)) {
            $files.Add($value)
        }
    }

    return @($files.ToArray())
}

function Get-MockupPaths {
    param([string]$Content)

    $files = New-Object System.Collections.Generic.List[string]
    $section = Get-Section -Content $Content -HeadingPattern '.*视觉稿参考.*'
    if ([string]::IsNullOrWhiteSpace($section)) {
        return @()
    }

    foreach ($match in [regex]::Matches($section, '`([^`]+)`')) {
        $value = Clean-Cell $match.Groups[1].Value
        if ($value -and -not $files.Contains($value)) {
            $files.Add($value)
        }
    }

    return @($files.ToArray())
}

function Resolve-ArchiveFile {
    param(
        [string]$ArchivePath,
        [string]$CellValue
    )

    $value = Clean-Cell $CellValue
    if ([string]::IsNullOrWhiteSpace($value) -or $value -eq "-") {
        return $null
    }

    $value = ($value -replace '\s*\(.+?\)\s*$', "").Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value -eq "-") {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($value)) {
        return $value
    }

    $directPath = Join-Path $ArchivePath $value
    if (Test-Path -LiteralPath $directPath -PathType Leaf) {
        return $directPath
    }

    $requirementsPath = Join-Path (Join-Path $ArchivePath "requirements") $value
    if (Test-Path -LiteralPath $requirementsPath -PathType Leaf) {
        return $requirementsPath
    }

    return $directPath
}

# === task.json data layer ===

function Get-TaskJsonPath { param([string]$ArchivePath); Join-Path $ArchivePath "task.json" }
function Get-TaskMdPath    { param([string]$ArchivePath); Join-Path $ArchivePath "task.md" }

function Test-TaskJsonExists {
    param([string]$ArchivePath)
    return (Test-Path -LiteralPath (Get-TaskJsonPath $ArchivePath) -PathType Leaf)
}

function Read-TaskJson {
    param([string]$ArchivePath)
    $p = Get-TaskJsonPath $ArchivePath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function Write-TaskJson {
    param(
        [string]$ArchivePath,
        $Data
    )

    $dir = $ArchivePath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $cleanTasks = @()
    foreach ($t in $Data.tasks) {
        $designDocs = @()
        if ($t.designDocs) {
            foreach ($d in $t.designDocs) {
                $designDocs += @{ path = $d.path; status = $d.status }
            }
        }
        $cleanTasks += @{
            id           = $t.id
            title        = $t.title
            requirement  = $t.requirement
            currentOwners = @($t.currentOwners)
            designDocs   = $designDocs
            remark       = $t.remark
            lifecycle    = $t.lifecycle
        }
    }

    $payload = @{
        version     = $Data.version
        archive     = $Data.archive
        generatedAt = (Get-Date).ToString("s")
        tasks       = $cleanTasks
    } | ConvertTo-Json -Depth 8

    [System.IO.File]::WriteAllText(
        (Get-TaskJsonPath $ArchivePath),
        $payload,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Convert-OwnersArrayToString {
    param([array]$Owners)
    if ($Owners -and $Owners.Count -gt 0) {
        return ($Owners -join "+")
    }
    return ""
}

function Convert-DesignDocsToString {
    param([array]$DesignDocs)
    if (-not $DesignDocs -or $DesignDocs.Count -eq 0) { return "-" }
    $parts = @()
    foreach ($d in $DesignDocs) {
        if ($d.status -eq "pending") {
            $parts += "$($d.path) (待产出)"
        }
        else {
            $parts += $d.path
        }
    }
    return ($parts -join " + ")
}

# Convert task.json tasks into the same row format produced by Parse-MarkdownTable,
# so the entire existing pipeline (Resolve-TaskRow, Build-Handoff, etc.) works unchanged.
function Convert-TasksToRows {
    param($Tasks)

    $rows = @()
    foreach ($t in $Tasks) {
        $lifecycle = if ($t.lifecycle) { $t.lifecycle } else { "active" }
        $owners = if ($lifecycle -eq "completed") {
            "已完成"
        }
        elseif ($lifecycle -eq "deprecated") {
            (Convert-OwnersArrayToString $t.currentOwners)
        }
        else {
            (Convert-OwnersArrayToString $t.currentOwners)
        }

        $rows += [pscustomobject]@{
            TaskId        = $t.id
            "需求"         = $t.title
            "需求文件"     = $t.requirement
            "当前责任人"   = $owners
            "关联设计文档" = (Convert-DesignDocsToString $t.designDocs)
            "备注"         = if ($t.remark) { $t.remark } else { "-" }
        }
    }
    return $rows
}

# === Handoff building blocks ===

function Test-DocEligible {
    param(
        $FlowControl,
        [string]$TargetRole,
        [string]$Label
    )

    if ($FlowControl.status -eq "deprecated") {
        return @{ eligible = $false; reason = "$($Label)Status=deprecated" }
    }
    if ($FlowControl.hasPendingRejection) {
        return @{ eligible = $false; reason = "$($Label)HasPendingRejection" }
    }
    if ($FlowControl.owner -and $FlowControl.owner -ne $TargetRole) {
        return @{ eligible = $false; reason = "$($Label)Owner=$($FlowControl.owner)" }
    }
    return @{ eligible = $true; reason = "" }
}

function Get-RequirementSummary {
    param(
        [string]$RequirementPath,
        [string]$Content
    )

    return @{
        path = (Get-RelativePath $RequirementPath)
        title = (Get-FirstHeading $Content)
        description = (Get-DocField -Content $Content -Name "描述")
        acceptance = (Get-DocField -Content $Content -Name "验收标准")
        priority = (Get-DocField -Content $Content -Name "优先级")
        impact = (Get-DocField -Content $Content -Name "影响范围")
        userScenario = (Get-DocField -Content $Content -Name "用户场景")
        edgeCases = (Get-DocField -Content $Content -Name "边界与异常")
        dependencies = (Get-DocField -Content $Content -Name "依赖关系")
    }
}

function Get-DesignSummary {
    param(
        [string]$DesignPath,
        [string]$Content
    )

    return @{
        path = (Get-RelativePath $DesignPath)
        title = (Get-FirstHeading $Content)
        overview = (Get-Section -Content $Content -HeadingPattern '.*需求概述.*')
        technicalPlan = (Get-Section -Content $Content -HeadingPattern '.*技术方案.*')
        risks = (Get-Section -Content $Content -HeadingPattern '.*风险提示.*')
        involvedFiles = @(Get-InvolvedFiles $Content)
        mockups = @(Get-MockupPaths $Content)
    }
}

function Resolve-TaskRow {
    param(
        $Row,
        [string]$ArchivePath,
        [string]$TargetRole
    )

    $routeOwner = Clean-Cell $Row."当前责任人"
    $requirementCell = Clean-Cell $Row."需求文件"
    $designCell = Clean-Cell $Row."关联设计文档"
    $title = Clean-Cell $Row."需求"
    $remark = Clean-Cell $Row."备注"

    if ($routeOwner -ne $TargetRole) {
        return @{ outcome = "ignored"; entry = @{ requirement = $requirementCell; reason = "currentOwner=$routeOwner" } }
    }

    $requirementPath = Resolve-ArchiveFile -ArchivePath $ArchivePath -CellValue $requirementCell
    if ($null -eq $requirementPath -or -not (Test-Path -LiteralPath $requirementPath -PathType Leaf)) {
        return @{ outcome = "warning"; entry = "Requirement file not found for row '$title': $requirementCell" }
    }

    $requirementContent = Read-TextFile $requirementPath
    $requirementFlow = Get-FlowControl $requirementContent
    $eligibility = Test-DocEligible -FlowControl $requirementFlow -TargetRole $TargetRole -Label "requirement"
    if (-not $eligibility.eligible) {
        return @{ outcome = "ignored"; entry = @{ requirement = (Get-RelativePath $requirementPath); reason = $eligibility.reason } }
    }

    $designPath = Resolve-ArchiveFile -ArchivePath $ArchivePath -CellValue $designCell
    $designSummary = $null
    $workMode = "requirement-guided"
    $involvedFiles = @()

    if ($TargetRole -ne "QA" -and $designPath -and (Test-Path -LiteralPath $designPath -PathType Leaf)) {
        $designContent = Read-TextFile $designPath
        $designFlow = Get-FlowControl $designContent
        $eligibility = Test-DocEligible -FlowControl $designFlow -TargetRole $TargetRole -Label "design"
        if (-not $eligibility.eligible) {
            return @{ outcome = "ignored"; entry = @{ requirement = (Get-RelativePath $requirementPath); design = (Get-RelativePath $designPath); reason = $eligibility.reason } }
        }
        $workMode = "design-guided"
        $involvedFiles = @(Get-InvolvedFiles $designContent)
        $designSummary = Get-DesignSummary -DesignPath $designPath -Content $designContent
    }
    elseif ($TargetRole -eq "DEV" -and $designCell -and $designCell -ne "-") {
        return @{ outcome = "warning"; entry = "Design file not found for row '$title': $designCell" }
    }

    $requirementSummary = Get-RequirementSummary -RequirementPath $requirementPath -Content $requirementContent

    return @{ outcome = "task"; entry = @{
        id          = if ($null -ne $Row.TaskId) { [int]$Row.TaskId } else { 0 }
        title       = $title
        workMode    = $workMode
        routeOwner  = $routeOwner
        remark      = $remark
        requirement = $requirementSummary
        design      = $designSummary
        involvedFiles = @($involvedFiles)
    }}
}

function Build-Handoff {
    param(
        [string]$ArchivePath,
        [string]$TargetRole
    )

    $route = Get-RouteRows -ArchivePath $ArchivePath

    $tasks = @()
    $ignored = @()
    $warnings = @()

    foreach ($row in $route.rows) {
        $result = Resolve-TaskRow -Row $row -ArchivePath $ArchivePath -TargetRole $TargetRole
        switch ($result.outcome) {
            "task"    { $tasks += $result.entry }
            "ignored" { $ignored += $result.entry }
            "warning" { $warnings += $result.entry }
        }
    }

    if ($TaskId -ge 1) {
        $filtered = @($tasks | Where-Object { $_.id -eq $TaskId })
        if ($filtered.Count -eq 0) {
            Write-ErrorResult "TASK_ID_NOT_FOUND" "TaskId $TaskId not found among resolved tasks" 2
        }
        $tasks = $filtered
    }
    elseif ($TaskIndex -ge 0) {
        if ($TaskIndex -ge $tasks.Count) {
            Write-ErrorResult "TASK_INDEX_OUT_OF_RANGE" "TaskIndex $TaskIndex is out of range (max $($tasks.Count - 1))" 2
        }
        $tasks = @($tasks[$TaskIndex])
    }

    return @{
        success = $true
        data = @{
            type = "rdd-handoff"
            role = $TargetRole
            archive = (Get-RelativePath $ArchivePath)
            taskTracker = (Get-RelativePath $route.taskPath)
            generatedAt = (Get-Date).ToString("s")
            instructions = @(
                "Use this handoff packet as the entry context.",
                "Read only the listed requirement/design documents first.",
                "Do not scan unrelated archive documents unless a listed dependency is missing or unclear.",
                "Treat ignored items as out of scope for this role."
            )
            tasks = $tasks
            ignored = $ignored
            warnings = $warnings
        }
    }
}

function Get-RoleSkillPath {
    param([string]$TargetRole)

    $map = @{
        PM = "rdd-pm/SKILL.md"
        CTO = "rdd-cto/SKILL.md"
        UX = "rdd-ux/SKILL.md"
        DEV = "rdd-dev/SKILL.md"
        QA = "rdd-qa/SKILL.md"
    }

    return $map[$TargetRole]
}

function Get-RoleCommand {
    param([string]$TargetRole)
    return "/rdd-$($TargetRole.ToLower())"
}

function Get-RouteRows {
    param([string]$ArchivePath)

    # Primary: task.json
    $jsonPath = Get-TaskJsonPath $ArchivePath
    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        $data = Read-TaskJson -ArchivePath $ArchivePath
        if ($null -ne $data -and $data.tasks) {
            return @{
                taskPath = $jsonPath
                rows     = @(Convert-TasksToRows -Tasks $data.tasks)
            }
        }
    }

    # Legacy fallback: task.md
    $taskPath = Get-TaskMdPath $ArchivePath
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        Write-ErrorResult "TASK_NOT_FOUND" "Neither task.json nor task.md found in archive: $ArchivePath" 2
    }

    $taskContent = Read-TextFile $taskPath
    $rows = Parse-MarkdownTable -Lines ($taskContent -split "\r?\n") -RequiredHeader "当前责任人"
    if ($rows.Count -eq 0) {
        Write-ErrorResult "ROUTE_TABLE_NOT_FOUND" "No route overview table with 当前责任人 was found in task.md" 2
    }

    return @{
        taskPath = $taskPath
        rows     = $rows
    }
}

function Build-NextFlow {
    param([string]$ArchivePath)

    $route = Get-RouteRows -ArchivePath $ArchivePath
    $roleMap = @{}
    $warnings = @()

    $validRoles = @("PM", "CTO", "UX", "DEV", "QA")
    $completedCount = 0

    foreach ($row in $route.rows) {
        $owner = Clean-Cell $row."当前责任人"
        if ([string]::IsNullOrWhiteSpace($owner) -or $owner -eq "-") {
            $warnings += "Route row has no 当前责任人: $(Clean-Cell $row."需求")"
            continue
        }

        if ($owner -ieq "已完成") {
            $completedCount++
            continue
        }

        if ($validRoles -notcontains $owner) {
            $warnings += "Unknown 当前责任人 '$owner' in row '$(Clean-Cell $row."需求")' (expected one of: $($validRoles -join ', '), 已完成)"
            continue
        }

        if (-not $roleMap.ContainsKey($owner)) {
            $roleMap[$owner] = New-Object System.Collections.Generic.List[object]
        }

        $roleMap[$owner].Add([pscustomobject]@{
            id = if ($null -ne $row.TaskId) { [int]$row.TaskId } else { 0 }
            title = Clean-Cell $row."需求"
            requirement = Clean-Cell $row."需求文件"
            design = Clean-Cell $row."关联设计文档"
            remark = Clean-Cell $row."备注"
        })
    }

    $roles = @()
    foreach ($owner in $roleMap.Keys) {
        $roles += [pscustomobject]@{
            role = $owner
            command = (Get-RoleCommand $owner)
            skill = (Get-RoleSkillPath $owner)
            taskCount = $roleMap[$owner].Count
            tasks = @($roleMap[$owner].ToArray())
        }
    }

    $roles = @($roles | Sort-Object role)

    return @{
        success = $true
        data = @{
            type = "rdd-flow-next"
            archive = (Get-RelativePath $ArchivePath)
            taskTracker = (Get-RelativePath $route.taskPath)
            generatedAt = (Get-Date).ToString("s")
            roles = $roles
            completedCount = $completedCount
            warnings = $warnings
            usage = "Choose a role, then /new to open a new session and run /rdd-<role> (auto-loads skill + handoff). Preview packet here: rdd-engine/scripts/rdd-flow.cmd -Command start -Role <ROLE> -Archive `"$((Get-RelativePath $ArchivePath))`""
        }
    }
}

function Build-StartGuide {
    param(
        [string]$ArchivePath,
        [string]$TargetRole
    )

    $handoff = Build-Handoff -ArchivePath $ArchivePath -TargetRole $TargetRole
    $skillPath = Get-RoleSkillPath $TargetRole
    $roleCommand = Get-RoleCommand $TargetRole
    $relativeArchive = Get-RelativePath $ArchivePath

    $scopeLine = "请使用以下 handoff packet 作为入口上下文，只读取其中列出的需求/设计文档。"
    if ($TargetRole -eq "QA") {
        $scopeLine = "请使用以下 handoff packet 作为入口上下文；QA 只能读取需求文档和项目代码，禁止读取 design/ 目录。"
    }

    $promptLines = @(
        "角色交接：进入 $TargetRole 需要新的会话窗口，以保证上下文纯净。",
        "",
        "请在当前会话完成后：",
        "  1. 按 Ctrl+X N（或输入 /new）开新 session",
        "  2. 在新 session 输入 $roleCommand（自动加载 $skillPath + 本交接包）",
        "",
        $scopeLine,
        "不要默认扫描整个归档目录；ignored 项不属于本次处理范围。",
        "",
        "归档路径：$relativeArchive",
        "目标角色：$TargetRole",
        "",
        "新角色启动后执行要求：",
        "1. 先确认 handoff 中的 tasks 和 warnings。",
        "2. 按 task 的 workMode 进入对应工作模式。",
        "3. 如 handoff 为空或 warning 阻塞执行，先向用户说明并请求裁决。",
        "4. 流转状态更新必须同时同步 task.json 和文档自身的流转控制。"
    )

    return @{
        success = $true
        data = @{
            type = "rdd-flow-start"
            role = $TargetRole
            command = $roleCommand
            skill = $skillPath
            archive = $relativeArchive
            generatedAt = (Get-Date).ToString("s")
            prompt = ($promptLines -join [System.Environment]::NewLine)
            handoff = $handoff.data
        }
    }
}

function Convert-NextToMarkdown {
    param($Next)

    $data = $Next.data
    $lines = @(
        "# RDD Next Flow",
        "",
        "- Archive: ``$($data.archive)``",
        "- Task tracker: ``$($data.taskTracker)``",
        "- Generated at: $($data.generatedAt)",
        ""
    )

    $lines += "- Usage: ``$($data.usage)``"

    if ($data.completedCount -gt 0) {
        $lines += "- Completed (已闭环): $($data.completedCount) 个需求（当前责任人 = 已完成，不在可启动角色内）"
    }

    $lines += ""
    $lines += "## Available Roles"

    foreach ($role in $data.roles) {
        $lines += ""
        $lines += "### $($role.role)"
        $lines += ""
        $lines += "- Command: ``$($role.command)``"
        $lines += "- Skill: ``$($role.skill)``"
        $lines += "- Task count: $($role.taskCount)"
        foreach ($task in $role.tasks) {
            $lines += "- $($task.title): ``$($task.requirement)``"
        }
    }

    if ($data.warnings.Count -gt 0) {
        $lines += ""
        $lines += "## Warnings"
        foreach ($warning in $data.warnings) {
            $lines += "- $warning"
        }
    }

    return ($lines -join [System.Environment]::NewLine)
}

function Convert-StartToMarkdown {
    param($Start)

    $data = $Start.data
    $lines = @(
        "# RDD Start: $($data.role)",
        "",
        "- Command: ``$($data.command)``",
        "- Skill: ``$($data.skill)``",
        "- Archive: ``$($data.archive)``",
        "- Generated at: $($data.generatedAt)",
        "",
        "## Prompt",
        "",
        '```text',
        $data.prompt,
        '```',
        "",
        "## Handoff Summary",
        "",
        "- Task count: $($data.handoff.tasks.Count)",
        "- Ignored count: $($data.handoff.ignored.Count)",
        "- Warning count: $($data.handoff.warnings.Count)"
    )

    foreach ($task in $data.handoff.tasks) {
        $lines += "- $($task.title): ``$($task.workMode)``"
    }

    return ($lines -join [System.Environment]::NewLine)
}

function Convert-HandoffToMarkdown {
    param($Handoff)

    $data = $Handoff.data
    $lines = @(
        "# RDD Handoff: $($data.role)",
        "",
        "- Archive: ``$($data.archive)``",
        "- Task tracker: ``$($data.taskTracker)``",
        "- Generated at: $($data.generatedAt)",
        "",
        "## Instructions"
    )

    foreach ($instruction in $data.instructions) {
        $lines += "- $instruction"
    }

    $lines += ""
    $lines += "## Tasks"

    foreach ($task in $data.tasks) {
        $lines += ""
        $lines += "### $($task.title)"
        $lines += ""
        $lines += "- Work mode: ``$($task.workMode)``"
        $lines += "- Requirement: ``$($task.requirement.path)``"
        if ($task.design) {
            $lines += "- Design: ``$($task.design.path)``"
        }
        if ($task.design -and $task.design.mockups.Count -gt 0) {
            $lines += "- Mockups: " + (($task.design.mockups | ForEach-Object { "``$_``" }) -join ", ")
        }
        if ($task.requirement.acceptance) {
            $lines += "- Acceptance: $($task.requirement.acceptance)"
        }
        if ($task.involvedFiles.Count -gt 0) {
            $lines += "- Involved files: " + (($task.involvedFiles | ForEach-Object { "``$_``" }) -join ", ")
        }
    }

    if ($data.ignored.Count -gt 0) {
        $lines += ""
        $lines += "## Ignored"
        foreach ($item in $data.ignored) {
            $target = if ($item.requirement) { $item.requirement } else { "-" }
            $lines += "- ``$target``: $($item.reason)"
        }
    }

    if ($data.warnings.Count -gt 0) {
        $lines += ""
        $lines += "## Warnings"
        foreach ($warning in $data.warnings) {
            $lines += "- $warning"
        }
    }

    return ($lines -join [System.Environment]::NewLine)
}

# === Output ===

function Write-FlowOutput {
    param(
        [string]$Output,
        [string]$OutFilePath
    )

    if (-not [string]::IsNullOrWhiteSpace($OutFilePath)) {
        $target = $OutFilePath
        if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path $repoRoot $target
        }
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }
        Set-Content -LiteralPath $target -Value $Output -Encoding UTF8
    }

    $Output
}

# === task.json command handlers ===

function Parse-OwnersString {
    param([string]$OwnersStr)
    if ([string]::IsNullOrWhiteSpace($OwnersStr)) { return @() }
    return @(($OwnersStr -split "\+") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Get-NextTaskId {
    param($Tasks)
    $maxId = 0
    foreach ($t in $Tasks) { if ([int]$t.id -gt $maxId) { $maxId = [int]$t.id } }
    return $maxId + 1
}

function Find-TaskById {
    param($Tasks, [int]$Id)
    foreach ($t in $Tasks) { if ([int]$t.id -eq $Id) { return $t } }
    return $null
}

# Deep-copy PSCustomObject task data into clean hashtables for safe modification.
function Convert-TaskDataToHashtable {
    param($Data)
    $tasks = @()
    foreach ($t in $Data.tasks) {
        $designDocs = @()
        if ($t.designDocs) {
            foreach ($d in $t.designDocs) {
                $designDocs += @{ path = [string]$d.path; status = [string]$d.status }
            }
        }
        $tasks += @{
            id           = [int]$t.id
            title        = [string]$t.title
            requirement  = [string]$t.requirement
            currentOwners = @($t.currentOwners)
            designDocs   = $designDocs
            remark       = if ($t.remark) { [string]$t.remark } else { "" }
            lifecycle    = if ($t.lifecycle) { [string]$t.lifecycle } else { "active" }
        }
    }
    return @{
        version = if ($Data.version) { [int]$Data.version } else { 1 }
        archive = [string]$Data.archive
        tasks   = $tasks
    }
}

function Read-TaskJsonEditable {
    param([string]$ArchivePath)
    $data = Read-TaskJson -ArchivePath $ArchivePath
    if ($null -eq $data) { return $null }
    return (Convert-TaskDataToHashtable $data)
}

# --- show ---

function Invoke-Show {
    param(
        [string]$ArchivePath,
        [string]$FilterRole
    )
    $data = Read-TaskJson -ArchivePath $ArchivePath
    if ($null -eq $data) {
        Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found in archive: $ArchivePath. Use 'init' to create one." 1
    }

    $tasks = @($data.tasks)

    if (-not [string]::IsNullOrWhiteSpace($FilterRole)) {
        $tasks = @($tasks | Where-Object {
            $_.lifecycle -ne "completed" -and $_.lifecycle -ne "deprecated" -and
            @($_.currentOwners) -contains $FilterRole
        })
    }

    if ($TaskId -ge 1) {
        $tasks = @($tasks | Where-Object { [int]$_.id -eq $TaskId })
    }

    return @{
        success = $true
        data    = @{
            type      = "rdd-task-show"
            archive   = $data.archive
            taskCount = $tasks.Count
            tasks     = $tasks
        }
    }
}

# --- init ---

function Invoke-Init {
    param([string]$ArchivePath)

    if (Test-TaskJsonExists -ArchivePath $ArchivePath) {
        Write-ErrorResult "TASK_JSON_EXISTS" "task.json already exists. Use 'add-task' to append, or delete it first." 1
    }

    $tasksJson = $null
    if (-not [string]::IsNullOrWhiteSpace($TasksFile)) {
        $filePath = $TasksFile
        if (-not [System.IO.Path]::IsPathRooted($filePath)) { $filePath = Join-Path $repoRoot $filePath }
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            Write-ErrorResult "TASKS_FILE_NOT_FOUND" "Tasks file not found: $filePath" 1
        }
        $tasksJson = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)
    }
    else {
        $tasksJson = $Tasks
    }
    if ([string]::IsNullOrWhiteSpace($tasksJson)) {
        Write-ErrorResult "MISSING_TASKS" "-Tasks (inline JSON) or -TasksFile (file path) is required" 1
    }

    # NOTE: Do NOT wrap ConvertFrom-Json in @() — PS 5.1 merges array elements when piped through @().
    $inputTasks = ConvertFrom-Json $tasksJson
    if ($inputTasks -isnot [array]) { $inputTasks = @($inputTasks) }

    $cleanTasks = @()
    $nextId = 1
    foreach ($t in $inputTasks) {
        $designDocs = @()
        if ($t.designDocs) {
            foreach ($d in $t.designDocs) {
                $designDocs += @{ path = [string]$d.path; status = if ($d.status) { [string]$d.status } else { "pending" } }
            }
        }
        $owners = @()
        if ($t.currentOwners) { $owners = @($t.currentOwners) }
        $cleanTasks += @{
            id           = $nextId
            title        = [string]$t.title
            requirement  = [string]$t.requirement
            currentOwners = $owners
            designDocs   = $designDocs
            remark       = if ($t.remark) { [string]$t.remark } else { "" }
            lifecycle    = if ($t.lifecycle) { [string]$t.lifecycle } else { "active" }
        }
        $nextId++
    }

    $archiveName = Split-Path $ArchivePath -Leaf
    $data = @{ version = 1; archive = $archiveName; tasks = $cleanTasks }
    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{
        success = $true
        data    = @{
            initialized = $true
            archive     = $archiveName
            path        = (Get-RelativePath (Get-TaskJsonPath $ArchivePath))
            taskCount   = $cleanTasks.Count
        }
    }
}

# --- add-task ---

function Invoke-AddTask {
    param([string]$ArchivePath)

    $data = Read-TaskJsonEditable -ArchivePath $ArchivePath
    if ($null -eq $data) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found. Use 'init' first." 1 }

    if ([string]::IsNullOrWhiteSpace($Title))       { Write-ErrorResult "MISSING_TITLE" "-Title is required" 1 }
    if ([string]::IsNullOrWhiteSpace($Requirement)) { Write-ErrorResult "MISSING_REQUIREMENT" "-Requirement is required" 1 }
    if ([string]::IsNullOrWhiteSpace($CurrentOwners)) { Write-ErrorResult "MISSING_CURRENT_OWNERS" "-CurrentOwners is required (e.g. DEV or CTO+UX)" 1 }

    $owners = Parse-OwnersString $CurrentOwners
    if ($owners.Count -eq 0) { Write-ErrorResult "INVALID_CURRENT_OWNERS" "-CurrentOwners parsed to empty array" 1 }

    $newId = Get-NextTaskId -Tasks $data.tasks
    $data.tasks += @{
        id           = $newId
        title        = $Title
        requirement  = $Requirement
        currentOwners = $owners
        designDocs   = @()
        remark       = if ($Remark) { $Remark } else { "" }
        lifecycle    = "active"
    }

    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{
        success = $true
        data    = @{
            added   = $true
            taskId  = $newId
            title   = $Title
            owners  = $owners
        }
    }
}

# --- set-route ---

function Invoke-SetRoute {
    param([string]$ArchivePath)

    $data = Read-TaskJsonEditable -ArchivePath $ArchivePath
    if ($null -eq $data) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found." 1 }

    if ($TaskId -lt 1)                 { Write-ErrorResult "MISSING_TASK_ID" "-TaskId is required" 1 }
    if ([string]::IsNullOrWhiteSpace($To)) { Write-ErrorResult "MISSING_TO" "-To is required (e.g. DEV or CTO+UX)" 1 }

    $task = $null
    $taskIndex = -1
    for ($i = 0; $i -lt $data.tasks.Count; $i++) {
        if ([int]$data.tasks[$i].id -eq $TaskId) { $task = $data.tasks[$i]; $taskIndex = $i; break }
    }
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $TaskId not found" 1 }

    $owners = Parse-OwnersString $To
    if ($owners.Count -eq 0) { Write-ErrorResult "INVALID_TO" "-To parsed to empty array" 1 }

    $data.tasks[$taskIndex].currentOwners = $owners
    if ($task.lifecycle -eq "completed") { $data.tasks[$taskIndex].lifecycle = "active" }

    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{
        success = $true
        data    = @{
            taskId       = $TaskId
            currentOwners = $owners
            lifecycle    = $data.tasks[$taskIndex].lifecycle
        }
    }
}

# --- advance ---

function Invoke-Advance {
    param([string]$ArchivePath)

    $data = Read-TaskJsonEditable -ArchivePath $ArchivePath
    if ($null -eq $data) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found." 1 }

    if ($TaskId -lt 1)                   { Write-ErrorResult "MISSING_TASK_ID" "-TaskId is required" 1 }
    if ([string]::IsNullOrWhiteSpace($From)) { Write-ErrorResult "MISSING_FROM" "-From is required (the role advancing)" 1 }
    if ([string]::IsNullOrWhiteSpace($To))   { Write-ErrorResult "MISSING_TO" "-To is required (the target role)" 1 }

    $task = $null
    $taskIndex = -1
    for ($i = 0; $i -lt $data.tasks.Count; $i++) {
        if ([int]$data.tasks[$i].id -eq $TaskId) { $task = $data.tasks[$i]; $taskIndex = $i; break }
    }
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $TaskId not found" 1 }

    $owners = @($task.currentOwners)
    if ($owners -notcontains $From) {
        Write-ErrorResult "FROM_NOT_OWNER" "'$From' is not in currentOwners of TaskId $($TaskId): $($owners -join '+')" 1
    }

    $newOwners = @()
    foreach ($o in $owners) { if ($o -ne $From) { $newOwners += $o } }
    if ($newOwners -notcontains $To) { $newOwners += $To }

    $data.tasks[$taskIndex].currentOwners = $newOwners

    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{
        success = $true
        data    = @{
            taskId       = $TaskId
            currentOwners = $newOwners
            advancedFrom = $From
            advancedTo   = $To
        }
    }
}

# --- add-design ---

function Invoke-AddDesign {
    param([string]$ArchivePath)

    $data = Read-TaskJsonEditable -ArchivePath $ArchivePath
    if ($null -eq $data) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found." 1 }

    if ($TaskId -lt 1)                           { Write-ErrorResult "MISSING_TASK_ID" "-TaskId is required" 1 }
    if ([string]::IsNullOrWhiteSpace($DesignPath)) { Write-ErrorResult "MISSING_DESIGN_PATH" "-Path is required (design doc path)" 1 }

    $task = $null
    $taskIndex = -1
    for ($i = 0; $i -lt $data.tasks.Count; $i++) {
        if ([int]$data.tasks[$i].id -eq $TaskId) { $task = $data.tasks[$i]; $taskIndex = $i; break }
    }
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $TaskId not found" 1 }

    $designDocs = @($task.designDocs)
    $found = $false
    for ($i = 0; $i -lt $designDocs.Count; $i++) {
        if ($designDocs[$i].path -eq $DesignPath) {
            $designDocs[$i].status = "ready"
            $found = $true
            break
        }
    }
    if (-not $found) {
        $designDocs += @{ path = $DesignPath; status = "ready" }
    }

    $data.tasks[$taskIndex].designDocs = $designDocs

    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{
        success = $true
        data    = @{
            taskId    = $TaskId
            designDocs = $designDocs
            added     = $true
        }
    }
}

# --- reject ---

function Invoke-Reject {
    param([string]$ArchivePath)

    $data = Read-TaskJsonEditable -ArchivePath $ArchivePath
    if ($null -eq $data) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found." 1 }

    if ($TaskId -lt 1)                   { Write-ErrorResult "MISSING_TASK_ID" "-TaskId is required" 1 }
    if ([string]::IsNullOrWhiteSpace($From)) { Write-ErrorResult "MISSING_FROM" "-From is required (rejecting role)" 1 }
    if ([string]::IsNullOrWhiteSpace($To))   { Write-ErrorResult "MISSING_TO" "-To is required (rejected-to role)" 1 }
    if ([string]::IsNullOrWhiteSpace($Reason)) { Write-ErrorResult "MISSING_REASON" "-Reason is required" 1 }

    $task = $null
    $taskIndex = -1
    for ($i = 0; $i -lt $data.tasks.Count; $i++) {
        if ([int]$data.tasks[$i].id -eq $TaskId) { $task = $data.tasks[$i]; $taskIndex = $i; break }
    }
    if ($null -eq $task) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $TaskId not found" 1 }

    $data.tasks[$taskIndex].currentOwners = @($To)
    $rejectSummary = "$From 打回 $To：$Reason"
    if ([string]::IsNullOrWhiteSpace($task.remark) -or $task.remark -eq "-") {
        $data.tasks[$taskIndex].remark = $rejectSummary
    }
    else {
        $data.tasks[$taskIndex].remark = "$($task.remark) | $rejectSummary"
    }

    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{
        success = $true
        data    = @{
            taskId       = $TaskId
            currentOwners = @($To)
            rejectedBy   = $From
            rejectedTo   = $To
            remark       = $data.tasks[$taskIndex].remark
        }
    }
}

# --- complete / reopen / deprecate ---

function Invoke-Complete {
    param([string]$ArchivePath)

    $data = Read-TaskJsonEditable -ArchivePath $ArchivePath
    if ($null -eq $data) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found." 1 }
    if ($TaskId -lt 1)   { Write-ErrorResult "MISSING_TASK_ID" "-TaskId is required" 1 }

    $taskIndex = -1
    for ($i = 0; $i -lt $data.tasks.Count; $i++) {
        if ([int]$data.tasks[$i].id -eq $TaskId) { $taskIndex = $i; break }
    }
    if ($taskIndex -lt 0) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $TaskId not found" 1 }

    $data.tasks[$taskIndex].lifecycle = "completed"
    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{ success = $true; data = @{ taskId = $TaskId; lifecycle = "completed" } }
}

function Invoke-Reopen {
    param([string]$ArchivePath)

    $data = Read-TaskJsonEditable -ArchivePath $ArchivePath
    if ($null -eq $data) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found." 1 }
    if ($TaskId -lt 1)   { Write-ErrorResult "MISSING_TASK_ID" "-TaskId is required" 1 }
    if ([string]::IsNullOrWhiteSpace($To)) { Write-ErrorResult "MISSING_TO" "-To is required (role to reopen to)" 1 }

    $taskIndex = -1
    for ($i = 0; $i -lt $data.tasks.Count; $i++) {
        if ([int]$data.tasks[$i].id -eq $TaskId) { $taskIndex = $i; break }
    }
    if ($taskIndex -lt 0) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $TaskId not found" 1 }

    $data.tasks[$taskIndex].lifecycle = "active"
    $data.tasks[$taskIndex].currentOwners = Parse-OwnersString $To
    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{ success = $true; data = @{ taskId = $TaskId; lifecycle = "active"; currentOwners = $data.tasks[$taskIndex].currentOwners } }
}

function Invoke-Deprecate {
    param([string]$ArchivePath)

    $data = Read-TaskJsonEditable -ArchivePath $ArchivePath
    if ($null -eq $data) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found." 1 }
    if ($TaskId -lt 1)   { Write-ErrorResult "MISSING_TASK_ID" "-TaskId is required" 1 }

    $taskIndex = -1
    for ($i = 0; $i -lt $data.tasks.Count; $i++) {
        if ([int]$data.tasks[$i].id -eq $TaskId) { $taskIndex = $i; break }
    }
    if ($taskIndex -lt 0) { Write-ErrorResult "TASK_NOT_FOUND" "TaskId $TaskId not found" 1 }

    $data.tasks[$taskIndex].lifecycle = "deprecated"
    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{ success = $true; data = @{ taskId = $TaskId; lifecycle = "deprecated" } }
}

# --- check ---

function Invoke-Check {
    param([string]$ArchivePath)

    $data = Read-TaskJson -ArchivePath $ArchivePath
    if ($null -eq $data) { Write-ErrorResult "TASK_JSON_NOT_FOUND" "task.json not found. Use 'init' to create one." 1 }

    $issues = @()
    $validRoles = @("PM", "CTO", "UX", "DEV", "QA")
    $validLifecycle = @("active", "deprecated", "completed")
    $validStatus = @("pending", "ready")

    foreach ($t in $data.tasks) {
        $taskId = if ($t.id) { [int]$t.id } else { 0 }
        $taskLabel = "Task $taskId"

        if (-not $t.title) { $issues += "${taskLabel}: missing title" }
        if (-not $t.requirement) { $issues += "${taskLabel}: missing requirement path" }
        else {
            $reqAbs = Join-Path $ArchivePath $t.requirement
            if (-not (Test-Path -LiteralPath $reqAbs -PathType Leaf)) {
                $issues += "${taskLabel}: requirement file not found: $($t.requirement)"
            }
        }

        if (-not $t.currentOwners -and $t.lifecycle -ne "completed") {
            $issues += "${taskLabel}: currentOwners is empty but lifecycle is not 'completed'"
        }
        if ($t.currentOwners) {
            foreach ($o in $t.currentOwners) {
                if ($validRoles -notcontains $o) {
                    $issues += "${taskLabel}: invalid owner '$o' (expected one of: $($validRoles -join ', '))"
                }
            }
        }

        if ($t.lifecycle -and $validLifecycle -notcontains $t.lifecycle) {
            $issues += "${taskLabel}: invalid lifecycle '$($t.lifecycle)' (expected one of: $($validLifecycle -join ', '))"
        }

        if ($t.designDocs) {
            foreach ($d in $t.designDocs) {
                if ($validStatus -notcontains $d.status) {
                    $issues += "${taskLabel}: invalid designDoc status '$($d.status)' for $($d.path)"
                }
                if ($d.status -eq "ready") {
                    $docAbs = Join-Path $ArchivePath $d.path
                    if (-not (Test-Path -LiteralPath $docAbs -PathType Leaf)) {
                        $issues += "${taskLabel}: designDoc marked ready but file not found: $($d.path)"
                    }
                }
            }
        }
    }

    # Consistency check: requirement doc flow control vs currentOwners
    foreach ($t in $data.tasks) {
        if ($t.lifecycle -eq "completed" -or $t.lifecycle -eq "deprecated") { continue }
        if (-not $t.requirement) { continue }
        $reqAbs = Join-Path $ArchivePath $t.requirement
        if (-not (Test-Path -LiteralPath $reqAbs -PathType Leaf)) { continue }

        $content = Read-TextFile $reqAbs
        $flow = Get-FlowControl $content
        if ($flow.owner) {
            $taskOwners = @($t.currentOwners) -join "+"
            if ($flow.owner -ne $taskOwners) {
                $issues += "Task $($t.id): currentOwners='$taskOwners' but requirement doc 当前责任人='$($flow.owner)' (doc takes precedence)"
            }
        }
    }

    return @{
        success = $true
        data    = @{
            type        = "rdd-task-check"
            archive     = $data.archive
            taskCount   = @($data.tasks).Count
            issueCount  = $issues.Count
            issues      = $issues
        }
    }
}

# --- migrate ---

function Invoke-Migrate {
    param([string]$ArchivePath)

    if (Test-TaskJsonExists -ArchivePath $ArchivePath) {
        Write-ErrorResult "TASK_JSON_EXISTS" "task.json already exists. Delete it first if you want to re-migrate." 1
    }

    $taskMdPath = Get-TaskMdPath $ArchivePath
    if (-not (Test-Path -LiteralPath $taskMdPath -PathType Leaf)) {
        Write-ErrorResult "TASK_MD_NOT_FOUND" "task.md not found in archive: $ArchivePath" 1
    }

    $taskContent = Read-TextFile $taskMdPath
    $rows = Parse-MarkdownTable -Lines ($taskContent -split "\r?\n") -RequiredHeader "当前责任人"
    if ($rows.Count -eq 0) {
        Write-ErrorResult "ROUTE_TABLE_NOT_FOUND" "No route overview table with 当前责任人 was found in task.md" 2
    }

    $cleanTasks = @()
    $nextId = 1
    foreach ($row in $rows) {
        $ownerCell = Clean-Cell $row."当前责任人"
        $designCell = Clean-Cell $row."关联设计文档"

        $lifecycle = "active"
        $owners = @()
        if ($ownerCell -ieq "已完成") {
            $lifecycle = "completed"
        }
        else {
            $owners = Parse-OwnersString $ownerCell
        }

        $designDocs = @()
        if ($designCell -and $designCell -ne "-") {
            $parts = $designCell -split "\+"
            foreach ($part in $parts) {
                $trimmed = $part.Trim()
                $isPending = $false
                if ($trimmed -match '\(待产出\)') {
                    $isPending = $true
                    $trimmed = ($trimmed -replace '\s*\(待产出\)\s*', '').Trim()
                }
                if ($trimmed) {
                    $designDocs += @{ path = $trimmed; status = if ($isPending) { "pending" } else { "ready" } }
                }
            }
        }

        $remarkValue = Clean-Cell $row."备注"
        if ($remarkValue -eq "-") { $remarkValue = "" }

        $cleanTasks += @{
            id           = $nextId
            title        = Clean-Cell $row."需求"
            requirement  = Clean-Cell $row."需求文件"
            currentOwners = $owners
            designDocs   = $designDocs
            remark       = $remarkValue
            lifecycle    = $lifecycle
        }
        $nextId++
    }

    $archiveName = Split-Path $ArchivePath -Leaf
    $data = @{ version = 1; archive = $archiveName; tasks = $cleanTasks }
    Write-TaskJson -ArchivePath $ArchivePath -Data $data

    return @{
        success = $true
        data    = @{
            migrated = $true
            archive  = $archiveName
            path     = (Get-RelativePath (Get-TaskJsonPath $ArchivePath))
            taskCount = $cleanTasks.Count
        }
    }
}

# === Command dispatch ===

$archivePath = Resolve-ArchivePath $Archive

switch ($Command) {
    "handoff" {
        $result = Build-Handoff -ArchivePath $archivePath -TargetRole $Role
        $output = if ($Format -eq "markdown") { Convert-HandoffToMarkdown $result } else { ConvertTo-PortableJson $result -Depth 12 }
        Write-FlowOutput -Output $output -OutFilePath $OutFile
    }
    "validate" {
        $result = Build-Handoff -ArchivePath $archivePath -TargetRole $Role
        $output = ConvertTo-PortableJson @{
            success = $true
            data = @{
                archive = $result.data.archive
                role = $Role
                taskCount = $result.data.tasks.Count
                ignoredCount = $result.data.ignored.Count
                warningCount = $result.data.warnings.Count
                warnings = $result.data.warnings
            }
        } -Depth 8
        Write-FlowOutput -Output $output -OutFilePath $OutFile
    }
    "next" {
        $result = Build-NextFlow -ArchivePath $archivePath
        $output = if ($Format -eq "markdown") { Convert-NextToMarkdown $result } else { ConvertTo-PortableJson $result -Depth 12 }
        Write-FlowOutput -Output $output -OutFilePath $OutFile
    }
    "start" {
        $result = Build-StartGuide -ArchivePath $archivePath -TargetRole $Role
        $output = if ($Format -eq "markdown") { Convert-StartToMarkdown $result } else { ConvertTo-PortableJson $result -Depth 14 }
        Write-FlowOutput -Output $output -OutFilePath $OutFile
    }
    "show" {
        $filterRole = if ($PSBoundParameters.ContainsKey('Role')) { $Role } else { "" }
        $result = Invoke-Show -ArchivePath $archivePath -FilterRole $filterRole
        ConvertTo-PortableJson $result -Depth 8
    }
    "init" {
        $result = Invoke-Init -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
    "add-task" {
        $result = Invoke-AddTask -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
    "set-route" {
        $result = Invoke-SetRoute -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
    "advance" {
        $result = Invoke-Advance -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
    "add-design" {
        $result = Invoke-AddDesign -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
    "reject" {
        $result = Invoke-Reject -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
    "complete" {
        $result = Invoke-Complete -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
    "reopen" {
        $result = Invoke-Reopen -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
    "deprecate" {
        $result = Invoke-Deprecate -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
    "check" {
        $result = Invoke-Check -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 8
    }
    "migrate" {
        $result = Invoke-Migrate -ArchivePath $archivePath
        ConvertTo-PortableJson $result -Depth 6
    }
}
