# multi-owner route fan-out acceptance tests — archive 2026-09-24-multi-owner-route-parsing
# Runs rdd-flow.ps1 under the production interpreter (Windows PowerShell 5.1) against a
# throwaway git repo. Exit code 0 = all green.
#
# Coverage (requirement acceptance 1-6):
#   A1 next       : currentOwners=["CTO","UX"] fans out into BOTH role blocks, no Unknown warning
#   A2 start/handoff/validate : both member roles resolve the task, never ignored as currentOwner=CTO+UX
#   A3 anchors    : single-owner / completed (lifecycle=completed) / deprecated output unchanged
#   A4 init       : shape errors fail loud (TASKS_SHAPE_INVALID / TASK_MISSING_FIELD), nothing persisted
#   A5 add-task   : -Remark is a real parameter and lands in task.json
#   A6 edges      : unknown member still warns per member; task.md-only archive fails loud
#                   (TASK_JSON_NOT_FOUND) and `migrate` is the one-shot legacy bridge
#
# Usage: powershell -File test-multi-owner-routing.ps1   (or via pwsh tool)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir  = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$FlowPs1    = Join-Path $EngineDir 'rdd-flow.ps1'
$Work       = Join-Path $env:TEMP ('mo-routing-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$ArchiveRel = '.rdd/changes/archive/mo-fixture'

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

# Child stdout/stderr are raw UTF-8 bytes (rdd-flow sets Console.OutputEncoding = UTF8).
# Redirect them straight to files and read them back as UTF-8 so the assertions survive
# any parent console codepage (and any stdio-pipe-restricted sandbox).
function Invoke-Flow { param([string[]]$ArgList)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $outFile = Join-Path $Work "flow-out-$tag.txt"
    $errFile = Join-Path $Work "flow-err-$tag.txt"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FlowPs1) + $ArgList
        & powershell @all 1> $outFile 2> $errFile
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    $out = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)
    $err = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8)
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    $json = $null
    try { $json = ($out | ConvertFrom-Json) } catch { }
    return @{ json = $json; exit = $code; raw = $out; err = $err }
}

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Tasks { param([string]$TaskJsonPath)
    (Get-Content -LiteralPath $TaskJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json).tasks
}

function Find-Task { param($Tasks, [int]$Id)
    foreach ($t in $Tasks) { if ([int]$t.id -eq $Id) { return $t } }
    return $null
}

function Get-RoleBlock { param($Data, [string]$RoleName)
    foreach ($r in @($Data.roles)) { if ($r.role -eq $RoleName) { return $r } }
    return $null
}

function Test-HasTask { param($Block, [int]$Id)
    if ($null -eq $Block) { return $false }
    foreach ($t in @($Block.tasks)) { if ([int]$t.id -eq $Id) { return $true } }
    return $false
}

# --- setup throwaway repo + fixture archive ---
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Push-Location $Work
try {
    git init -q 2>$null | Out-Null
    $archDir = Join-Path $Work $ArchiveRel
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null

    Write-Utf8NoBom (Join-Path $archDir 'requirements/a.md') @'
# 测试需求 A

- **描述**：多责任人并行路由夹具
- **优先级**：高
'@
    Write-Utf8NoBom (Join-Path $archDir 'requirements/b.md') @'
# 测试需求 B

- **描述**：单责任人回归锚夹具
'@

    Write-Utf8NoBom (Join-Path $archDir 'tasks-init.json') @'
[
  { "title": "并行主需求", "requirement": "requirements/a.md", "currentOwners": ["CTO", "UX"], "designDocs": [], "remark": "复合需求，CTO+UX 并行" },
  { "title": "单责任人需求", "requirement": "requirements/b.md", "currentOwners": ["DEV"], "designDocs": [] },
  { "title": "已闭环需求", "requirement": "requirements/a.md", "currentOwners": ["QA"], "designDocs": [], "lifecycle": "completed" },
  { "title": "废弃需求", "requirement": "requirements/b.md", "currentOwners": ["DEV"], "designDocs": [], "lifecycle": "deprecated" }
]
'@

    $r = Invoke-Flow @('-Command', 'init', '-Archive', $ArchiveRel, '-TasksFile', ($ArchiveRel + '/tasks-init.json'))
    Assert-True ($r.json.success -eq $true -and $r.json.data.taskCount -eq 4) 'setup: init creates 4 tasks' $r.raw

    # ================= A1: next fans the multi-owner task out to BOTH roles =================
    $r = Invoke-Flow @('-Command', 'next', '-Archive', $ArchiveRel)
    $d = $r.json.data
    $cto = Get-RoleBlock $d 'CTO'
    $ux = Get-RoleBlock $d 'UX'
    $dev = Get-RoleBlock $d 'DEV'
    $warnText = @($d.warnings) -join ' | '
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true) 'A1 next exit 0' $r.err
    Assert-True ($null -ne $cto -and (Test-HasTask $cto 1)) 'A1 CTO block contains the multi-owner task'
    Assert-True ($null -ne $ux -and (Test-HasTask $ux 1)) 'A1 UX block contains the multi-owner task'
    Assert-True ($cto.taskCount -eq 1 -and $ux.taskCount -eq 1) 'A1 each member block counts the task once' ("cto=$($cto.taskCount) ux=$($ux.taskCount)")
    Assert-True ($cto.command -eq '/rdd-cto' -and $cto.skill -eq 'rdd-cto/SKILL.md') 'A1 CTO block command/skill stay single-role' ("command=$($cto.command) skill=$($cto.skill)")
    Assert-True ($ux.command -eq '/rdd-ux' -and $ux.skill -eq 'rdd-ux/SKILL.md') 'A1 UX block command/skill stay single-role' ("command=$($ux.command) skill=$($ux.skill)")
    Assert-True ($warnText -notmatch 'Unknown') 'A1 no Unknown 当前责任人 warning for a valid multi-owner row' $warnText
    Assert-True ($warnText -notmatch 'CTO\+UX') 'A1 no warning treats the owner SET as one role name' $warnText

    # ============ A2: start/handoff/validate resolve the task for BOTH member roles ============
    foreach ($roleName in @('CTO', 'UX')) {
        $r = Invoke-Flow @('-Command', 'handoff', '-Archive', $ArchiveRel, '-Role', $roleName)
        $taskIds = @($r.json.data.tasks | ForEach-Object { [int]$_.id })
        $ignoredText = (@($r.json.data.ignored | ForEach-Object { "$($_.requirement) $($_.reason)" })) -join ' | '
        Assert-True ($r.exit -eq 0 -and $taskIds -contains 1) "A2 handoff -$roleName resolves task 1" ("ids=$($taskIds -join ',')")
        Assert-True ($ignoredText -notmatch 'currentOwner=CTO\+UX') "A2 handoff -$roleName never ignores as currentOwner=CTO+UX" $ignoredText
        Assert-True ($null -ne (Find-Task @($r.json.data.tasks) 1)) "A2 handoff -$roleName task entry assembled" ''

        $r = Invoke-Flow @('-Command', 'start', '-Archive', $ArchiveRel, '-Role', $roleName)
        $startIds = @($r.json.data.handoff.tasks | ForEach-Object { [int]$_.id })
        Assert-True ($r.exit -eq 0 -and $startIds -contains 1) "A2 start -$roleName packet contains task 1" ("ids=$($startIds -join ',')")

        $r = Invoke-Flow @('-Command', 'validate', '-Archive', $ArchiveRel, '-Role', $roleName)
        Assert-True ($r.exit -eq 0 -and $r.json.data.taskCount -eq 1) "A2 validate -$roleName counts the task" ("taskCount=$($r.json.data.taskCount)")
    }

    # ==================== A3: regression anchors (output unchanged) ====================
    $r = Invoke-Flow @('-Command', 'handoff', '-Archive', $ArchiveRel, '-Role', 'DEV')
    $devIds = @($r.json.data.tasks | ForEach-Object { [int]$_.id })
    $ignored = @($r.json.data.ignored)
    $doneIgnored = @($ignored | Where-Object { $_.reason -eq 'currentOwner=已完成' })
    $multiIgnored = @($ignored | Where-Object { $_.reason -eq 'currentOwner=CTO+UX' })
    Assert-True ($devIds -contains 2) 'A3 single-owner row resolves for its owner (unchanged)' ("ids=$($devIds -join ',')")
    Assert-True ($devIds -contains 4) 'A3 deprecated row keeps entering role output (unchanged)' ("ids=$($devIds -join ',')")
    Assert-True ($devIds -notcontains 1) 'A3 multi-owner task stays ignored for non-member role' ("ids=$($devIds -join ',')")
    Assert-True ($doneIgnored.Count -eq 1 -and $doneIgnored[0].requirement -eq 'requirements/a.md') 'A3 completed row -> ignored "currentOwner=已完成" (lifecycle decides)' ("ignored=" + (($ignored | ForEach-Object { $_.reason }) -join ' | '))
    Assert-True ($multiIgnored.Count -eq 1) 'A3 non-member sees reason currentOwner=CTO+UX (owners set string)' ("ignored=" + (($ignored | ForEach-Object { $_.reason }) -join ' | '))

    $r = Invoke-Flow @('-Command', 'next', '-Archive', $ArchiveRel)
    $d = $r.json.data
    Assert-True ($d.completedCount -eq 1) 'A3 completedCount unchanged (lifecycle=completed)' ("completedCount=$($d.completedCount)")
    Assert-True ($d.type -eq 'rdd-flow-next' -and $d.usage -and $null -ne $d.warnings) 'A3 next top-level fields unchanged (contract)' $d.type
    $allTaskIds = @($d.roles | ForEach-Object { $_.tasks } | ForEach-Object { [int]$_.id })
    Assert-True ($allTaskIds -notcontains 3) 'A3 completed task never enters a role block' ("ids=$($allTaskIds -join ',')")
    Assert-True ($d.longTask.PSObject.Properties['triggered'] -ne $null) 'A3 longTask signal block unchanged (contract)' ''

    # ==================== A4: init input shape fails loud ====================
    $badDir = Join-Path $Work '.rdd/changes/archive/mo-initbad'
    New-Item -ItemType Directory -Path $badDir -Force | Out-Null
    $badJson = Join-Path $badDir 'tasks-bad.json'

    # top-level wrapper object ({"tasks": [...]}) — used to silently produce one empty task
    Write-Utf8NoBom $badJson '{ "tasks": [ { "title": "包装对象", "requirement": "requirements/a.md", "currentOwners": ["DEV"] } ] }'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-initbad', '-TasksFile', '.rdd/changes/archive/mo-initbad/tasks-bad.json')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASKS_SHAPE_INVALID') 'A4 wrapper object -> TASKS_SHAPE_INVALID (exit 1)' $r.raw
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $badDir 'task.json'))) 'A4 wrapper object: nothing persisted'

    # element missing title / requirement / currentOwners
    Write-Utf8NoBom $badJson '[ { "requirement": "requirements/a.md", "currentOwners": ["DEV"] } ]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-initbad', '-TasksFile', '.rdd/changes/archive/mo-initbad/tasks-bad.json')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_MISSING_FIELD' -and $r.json.error.message -match 'tasks\[0\]' -and $r.json.error.message -match 'title') 'A4 missing title -> TASK_MISSING_FIELD names entry + field' $r.raw

    Write-Utf8NoBom $badJson '[ { "title": "缺需求路径", "currentOwners": ["DEV"] } ]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-initbad', '-TasksFile', '.rdd/changes/archive/mo-initbad/tasks-bad.json')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_MISSING_FIELD' -and $r.json.error.message -match 'requirement') 'A4 missing requirement -> TASK_MISSING_FIELD' $r.raw

    Write-Utf8NoBom $badJson '[ { "title": "缺责任人", "requirement": "requirements/a.md" } ]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-initbad', '-TasksFile', '.rdd/changes/archive/mo-initbad/tasks-bad.json')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_MISSING_FIELD' -and $r.json.error.message -match 'currentOwners') 'A4 missing currentOwners -> TASK_MISSING_FIELD' $r.raw

    Write-Utf8NoBom $badJson '[ { "title": "空责任人", "requirement": "requirements/a.md", "currentOwners": [] } ]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-initbad', '-TasksFile', '.rdd/changes/archive/mo-initbad/tasks-bad.json')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_MISSING_FIELD') 'A4 empty currentOwners array -> TASK_MISSING_FIELD (no empty-owner row)' $r.raw

    # second entry bad -> the WHOLE input is rejected (nothing persisted)
    Write-Utf8NoBom $badJson '[ { "title": "好任务", "requirement": "requirements/a.md", "currentOwners": ["DEV"] }, { "title": " ", "requirement": "requirements/a.md", "currentOwners": ["DEV"] } ]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-initbad', '-TasksFile', '.rdd/changes/archive/mo-initbad/tasks-bad.json')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_MISSING_FIELD' -and $r.json.error.message -match 'tasks\[1\]') 'A4 later bad entry rejects the whole input (entry named)' $r.raw
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $badDir 'task.json'))) 'A4 nothing persisted on shape errors'

    # control: the same archive accepts a well-formed array afterwards
    Write-Utf8NoBom $badJson '[ { "title": "好任务", "requirement": "requirements/a.md", "currentOwners": ["DEV"] } ]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-initbad', '-TasksFile', '.rdd/changes/archive/mo-initbad/tasks-bad.json')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.taskCount -eq 1) 'A4 well-formed array still inits (control)' $r.raw

    # ==================== A5: add-task -Remark actually lands ====================
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $ArchiveRel, '-Title', '追加并行任务', '-Requirement', 'requirements/a.md', '-CurrentOwners', 'CTO+UX', '-Remark', '复合需求，CTO+UX 并行')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true) 'A5 add-task accepts -Remark (parameter exists)' $r.raw
    $t5 = Find-Task (Read-Tasks (Join-Path $Work ($ArchiveRel + '/task.json'))) 5
    Assert-True ($null -ne $t5 -and [string]$t5.remark -eq '复合需求，CTO+UX 并行') 'A5 remark persisted into task.json' ("remark=$($t5.remark)")
    Assert-True (@($t5.currentOwners) -contains 'CTO' -and @($t5.currentOwners) -contains 'UX') 'A5 add-task multi-owner split unchanged' ("owners=$(@($t5.currentOwners) -join '+')")

    # ==================== A6: unknown members + legacy task.md retirement ====================
    # handcrafted task.json with a bogus member: the valid member still fans out, the bogus
    # one warns individually (per-member granularity).
    $unkDir = Join-Path $Work '.rdd/changes/archive/mo-unknown'
    New-Item -ItemType Directory -Path $unkDir -Force | Out-Null
    Write-Utf8NoBom (Join-Path $unkDir 'task.json') @'
{ "version": 1, "archive": "mo-unknown", "tasks": [
  { "id": 1, "title": "含未知成员", "requirement": "requirements/a.md", "currentOwners": ["CTO", "XX"], "phase": "DESIGN", "designDocs": [], "currentWorker": [], "remark": "", "lifecycle": "active" }
] }
'@
    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-unknown')
    $d = $r.json.data
    $warnText = @($d.warnings) -join ' | '
    Assert-True ((Test-HasTask (Get-RoleBlock $d 'CTO') 1)) 'A6 valid member still fans out next to an unknown member'
    Assert-True ($warnText -match "Unknown" -and $warnText -match 'XX') 'A6 unknown member still warns (single role name)' $warnText
    Assert-True ($null -eq (Get-RoleBlock $d 'XX')) 'A6 no block is minted for the unknown member' ''

    # task.md-only legacy archive: read side fails loud (fallback retired), migrate bridges it
    $legDir = Join-Path $Work '.rdd/changes/archive/mo-legacy'
    New-Item -ItemType Directory -Path $legDir -Force | Out-Null
    Write-Utf8NoBom (Join-Path $legDir 'task.md') @'
# 任务路由总览

| TaskId | 需求 | 需求文件 | 当前责任人 | 关联设计文档 | 备注 |
|--------|------|----------|-----------|--------------|------|
| 1 | 遗留需求甲 | requirements/legacy-a.md | 已完成 | - | - |
| 2 | 遗留需求乙 | requirements/legacy-b.md | CTO | - | - |
| 3 | 遗留需求丙 | requirements/legacy-c.md | DEV | - | - |
'@
    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-legacy')
    Assert-True ($r.exit -ne 0 -and $r.json.error.code -eq 'TASK_JSON_NOT_FOUND') 'A6 task.md-only archive: next fails loud (no row fallback)' $r.raw
    $r = Invoke-Flow @('-Command', 'handoff', '-Archive', '.rdd/changes/archive/mo-legacy', '-Role', 'CTO')
    Assert-True ($r.exit -ne 0 -and $r.json.error.code -eq 'TASK_JSON_NOT_FOUND') 'A6 task.md-only archive: handoff fails loud (no row fallback)' $r.raw

    $r = Invoke-Flow @('-Command', 'migrate', '-Archive', '.rdd/changes/archive/mo-legacy')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.taskCount -eq 3) 'A6 migrate is the one-shot legacy bridge' $r.raw
    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-legacy')
    $lt = $r.json.data.longTask
    Assert-True ($r.exit -eq 0 -and $lt.totalTaskCount -eq 3 -and $lt.activeTaskCount -eq 2) 'A6 post-migrate rows read with lifecycle semantics' ("total=$($lt.totalTaskCount) active=$($lt.activeTaskCount)")
    Assert-True ($r.json.data.completedCount -eq 1) 'A6 migrated 已完成 row counts as completed' ("completedCount=$($r.json.data.completedCount)")

    # ==================== summary ====================
    $failed = @($Results | Where-Object { -not $_.ok })
    Write-Output ''
    Write-Output ("total: {0}  failed: {1}" -f $Results.Count, $failed.Count)
    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}
