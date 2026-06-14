[CmdletBinding()]
param(
    [ValidateSet("handoff", "validate", "next", "start")]
    [string]$Command = "handoff",

    [ValidateSet("PM", "CTO", "UX", "DEV", "QA")]
    [string]$Role = "DEV",

    [string]$Archive,

    [int]$TaskIndex = -1,

    [ValidateSet("json", "markdown")]
    [string]$Format = "json",

    [string]$OutFile
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Write-ErrorResult {
    param(
        [string]$Code,
        [string]$Message,
        [int]$ExitCode = 1
    )

    @{
        success = $false
        error = @{
            code = $Code
            message = $Message
        }
    } | ConvertTo-Json -Depth 6 -Compress
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
    $root = $repoRoot.Path.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
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
        title = $title
        workMode = $workMode
        routeOwner = $routeOwner
        remark = $remark
        requirement = $requirementSummary
        design = $designSummary
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

    if ($TaskIndex -ge 0) {
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
    return "/RDD-$TargetRole"
}

function Get-RouteRows {
    param([string]$ArchivePath)

    $taskPath = Join-Path $ArchivePath "task.md"
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        Write-ErrorResult "TASK_NOT_FOUND" "task.md not found in archive: $ArchivePath" 2
    }

    $taskContent = Read-TextFile $taskPath
    $rows = Parse-MarkdownTable -Lines ($taskContent -split "\r?\n") -RequiredHeader "当前责任人"
    if ($rows.Count -eq 0) {
        Write-ErrorResult "ROUTE_TABLE_NOT_FOUND" "No route overview table with 当前责任人 was found in task.md" 2
    }

    return @{
        taskPath = $taskPath
        rows = $rows
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
            usage = "Choose a role from roles, then run: rdd-engine/rdd-flow.ps1 -Command start -Role <ROLE> -Archive `"$((Get-RelativePath $ArchivePath))`""
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
        "加载 $roleCommand / $skillPath。",
        "",
        $scopeLine,
        "不要默认扫描整个归档目录；ignored 项不属于本次处理范围。",
        "",
        "归档路径：$relativeArchive",
        "目标角色：$TargetRole",
        "",
        "执行要求：",
        "1. 先确认 handoff 中的 tasks 和 warnings。",
        "2. 按 task 的 workMode 进入对应工作模式。",
        "3. 如 handoff 为空或 warning 阻塞执行，先向用户说明并请求裁决。",
        "4. 流转状态更新必须同时同步 task.md 和文档自身的流转控制。"
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

# === Command dispatch ===

$archivePath = Resolve-ArchivePath $Archive

switch ($Command) {
    "handoff" {
        $result = Build-Handoff -ArchivePath $archivePath -TargetRole $Role
        $output = if ($Format -eq "markdown") { Convert-HandoffToMarkdown $result } else { $result | ConvertTo-Json -Depth 12 }
        Write-FlowOutput -Output $output -OutFilePath $OutFile
    }
    "validate" {
        $result = Build-Handoff -ArchivePath $archivePath -TargetRole $Role
        @{
            success = $true
            data = @{
                archive = $result.data.archive
                role = $Role
                taskCount = $result.data.tasks.Count
                ignoredCount = $result.data.ignored.Count
                warningCount = $result.data.warnings.Count
                warnings = $result.data.warnings
            }
        } | ConvertTo-Json -Depth 8
    }
    "next" {
        $result = Build-NextFlow -ArchivePath $archivePath
        $output = if ($Format -eq "markdown") { Convert-NextToMarkdown $result } else { $result | ConvertTo-Json -Depth 12 }
        Write-FlowOutput -Output $output -OutFilePath $OutFile
    }
    "start" {
        $result = Build-StartGuide -ArchivePath $archivePath -TargetRole $Role
        $output = if ($Format -eq "markdown") { Convert-StartToMarkdown $result } else { $result | ConvertTo-Json -Depth 14 }
        Write-FlowOutput -Output $output -OutFilePath $OutFile
    }
}
