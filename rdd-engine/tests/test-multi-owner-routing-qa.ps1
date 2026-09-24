# QA verification suite — multi-owner route fan-out (archive 2026-09-24-multi-owner-route-parsing)
# Cases: .rdd/tests/role-handoff/cases.json TC-123..TC-131 (feature role-handoff, QA 独立复验 + 缺口面)
#
# Complements rdd-engine/tests/test-multi-owner-routing.ps1 (DEV acceptance suite, 48 asserts):
#   - independent fixtures re-verify AC-1..AC-5 signatures (QA-owned expectations)
#   - gap coverage the DEV suite does not exercise:
#       TC-124 next markdown rendering face (two role blocks, one task listing each)
#       TC-129 legacy task.md hand-written CTO+UX cell -> split fan-out via `migrate`
#               (read side is fail-loud TASK_JSON_NOT_FOUND by design — 2026-09-24 ruling:
#                compat layer retired, `migrate` is the only legacy channel; the split
#                semantics required by the requirement boundary applies inside migrate)
#       TC-130 set-route serial narrowing (["CTO","UX"]->["UX"], ["CTO"]->["UX"]) and
#               whole-set switch (set-route -To ... -Phase) semantics unchanged on
#               multi-owner tasks
#       TC-131 unknown owner member warns individually, mints no block, valid member
#               still fans out
#
# Usage: powershell -File test-multi-owner-routing-qa.ps1   (exit 0 = all green)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir  = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$FlowPs1    = Join-Path $EngineDir 'rdd-flow.ps1'
$Work       = Join-Path $env:TEMP ('mo-routing-qa-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

# Child stdout/stderr are raw UTF-8 bytes (rdd-flow sets Console.OutputEncoding = UTF8);
# redirect to files and read back as UTF-8 so assertions survive any console codepage.
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

function Get-TaskIds { param($Tasks)
    return @($Tasks | ForEach-Object { [int]$_.id })
}

# --- setup throwaway repo ---
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Push-Location $Work
try {
    git init -q 2>$null | Out-Null

    # =====================================================================
    # fixtures
    # =====================================================================
    # fx-multi (read-only): ONE multi-owner task — long-task signal stays quiet
    # and the roles array is exactly [CTO, UX], so the block assertions are clean.
    $multiDir = Join-Path $Work '.rdd/changes/archive/mo-qa-multi'
    New-Item -ItemType Directory -Path (Join-Path $multiDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $multiDir 'requirements/req.md') @'
# QA 复验需求（多责任人并行）

- **描述**：TC-123~TC-125 夹具
- **优先级**：高
'@
    Write-Utf8NoBom (Join-Path $multiDir 'tasks-init.json') @'
[
  { "title": "并行主需求QA", "requirement": "requirements/req.md", "currentOwners": ["CTO", "UX"], "designDocs": [] }
]
'@
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-qa-multi', '-TasksFile', '.rdd/changes/archive/mo-qa-multi/tasks-init.json')
    Assert-True ($r.json.success -eq $true -and $r.json.data.taskCount -eq 1) 'setup fx-multi: init 1 multi-owner task' $r.raw

    # fx-anchor: single-owner active + completed + deprecated (regression anchor rows)
    $anchorDir = Join-Path $Work '.rdd/changes/archive/mo-qa-anchor'
    New-Item -ItemType Directory -Path (Join-Path $anchorDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $anchorDir 'requirements/req.md') @'
# QA 回归锚需求
'@
    Write-Utf8NoBom (Join-Path $anchorDir 'tasks-init.json') @'
[
  { "title": "单责任人需求", "requirement": "requirements/req.md", "currentOwners": ["DEV"], "designDocs": [] },
  { "title": "已闭环需求", "requirement": "requirements/req.md", "currentOwners": ["QA"], "designDocs": [], "lifecycle": "completed" },
  { "title": "废弃需求", "requirement": "requirements/req.md", "currentOwners": ["DEV"], "designDocs": [], "lifecycle": "deprecated" }
]
'@
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-qa-anchor', '-TasksFile', '.rdd/changes/archive/mo-qa-anchor/tasks-init.json')
    Assert-True ($r.json.success -eq $true -and $r.json.data.taskCount -eq 3) 'setup fx-anchor: init 3 anchor tasks' $r.raw

    # fx-route: multi-owner + single-owner tasks for set-route semantics
    $routeDir = Join-Path $Work '.rdd/changes/archive/mo-qa-route'
    New-Item -ItemType Directory -Path (Join-Path $routeDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $routeDir 'requirements/req.md') @'
# QA 路由切换需求
'@
    Write-Utf8NoBom (Join-Path $routeDir 'tasks-init.json') @'
[
  { "title": "整组切换对象", "requirement": "requirements/req.md", "currentOwners": ["CTO", "UX"], "designDocs": [] },
  { "title": "串行收窄对象", "requirement": "requirements/req.md", "currentOwners": ["CTO"], "designDocs": [] }
]
'@
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-qa-route', '-TasksFile', '.rdd/changes/archive/mo-qa-route/tasks-init.json')
    Assert-True ($r.json.success -eq $true -and $r.json.data.taskCount -eq 2) 'setup fx-route: init 2 routing tasks' $r.raw

    # =====================================================================
    # TC-123 (P0/positive/AC-1): next fans the multi-owner task out to BOTH
    # member blocks, same TaskId, zero Unknown warning
    # =====================================================================
    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-qa-multi')
    $d = $r.json.data
    $cto = Get-RoleBlock $d 'CTO'
    $ux = Get-RoleBlock $d 'UX'
    $warnText = @($d.warnings) -join ' | '
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true) 'TC-123 next exit 0 on multi-owner task' $r.err
    Assert-True ($null -ne $cto -and $null -ne $ux) 'TC-123 next roles carry BOTH CTO and UX blocks' ("roles=" + (@($d.roles | ForEach-Object { $_.role }) -join ','))
    Assert-True ((Test-HasTask $cto 1) -and (Test-HasTask $ux 1)) 'TC-123 both blocks contain the multi-owner task (same TaskId=1)'
    Assert-True (@($cto.tasks).Count -eq 1 -and @($ux.tasks).Count -eq 1) 'TC-123 task counted once per member block' ("cto=$(@($cto.tasks).Count) ux=$(@($ux.tasks).Count)")
    Assert-True ($warnText -notmatch 'Unknown') 'TC-123 zero Unknown 当前责任人 warning for valid owners ["CTO","UX"]' $warnText

    # =====================================================================
    # TC-124 (P1/boundary/AC-1): markdown face — one task listed under each of
    # the two role blocks (JSON face alone is not the full output contract)
    # =====================================================================
    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-qa-multi', '-Format', 'markdown')
    $md = $r.raw
    Assert-True ($r.exit -eq 0 -and $md -match '### CTO' -and $md -match '### UX') 'TC-124 markdown renders both ### CTO and ### UX sections' $md
    Assert-True (([regex]::Matches($md, '并行主需求QA')).Count -eq 2) 'TC-124 task title listed exactly once per block (2 total)' ("count=" + ([regex]::Matches($md, '并行主需求QA')).Count)
    Assert-True ($md -notmatch 'Unknown') 'TC-124 markdown face carries no Unknown warning' $md

    # =====================================================================
    # TC-125 (P0/positive/AC-2): handoff/start/validate resolve the task for
    # BOTH members; a non-member is ignored with the owners-set reason
    # =====================================================================
    foreach ($roleName in @('CTO', 'UX')) {
        $r = Invoke-Flow @('-Command', 'handoff', '-Archive', '.rdd/changes/archive/mo-qa-multi', '-Role', $roleName)
        $ids = Get-TaskIds @($r.json.data.tasks)
        Assert-True ($r.exit -eq 0 -and $ids -contains 1) "TC-123/125 handoff -$roleName resolves task 1" ("ids=$($ids -join ',')")
        Assert-True (@($r.json.data.tasks)[0].id -eq 1) "TC-125 handoff -$roleName entry assembled (id 1)" ''

        $r = Invoke-Flow @('-Command', 'start', '-Archive', '.rdd/changes/archive/mo-qa-multi', '-Role', $roleName)
        $startIds = Get-TaskIds @($r.json.data.handoff.tasks)
        Assert-True ($r.exit -eq 0 -and $startIds -contains 1) "TC-125 start -$roleName packet contains task 1" ("ids=$($startIds -join ',')")

        $r = Invoke-Flow @('-Command', 'validate', '-Archive', '.rdd/changes/archive/mo-qa-multi', '-Role', $roleName)
        Assert-True ($r.exit -eq 0 -and $r.json.data.taskCount -eq 1) "TC-125 validate -$roleName counts the task" ("taskCount=$($r.json.data.taskCount)")
    }

    $r = Invoke-Flow @('-Command', 'handoff', '-Archive', '.rdd/changes/archive/mo-qa-multi', '-Role', 'DEV')
    $ignoredText = (@($r.json.data.ignored | ForEach-Object { "$($_.requirement) $($_.reason)" })) -join ' | '
    Assert-True (@($r.json.data.tasks).Count -eq 0) 'TC-125 non-member DEV gets an empty task list' $ignoredText
    Assert-True ($ignoredText -match 'currentOwner=CTO\+UX') 'TC-125 non-member reason keeps the owners-set string (old signature stays visible only here)' $ignoredText

    # =====================================================================
    # TC-126 (P0/boundary/AC-3): single-owner / completed / deprecated rows
    # behave exactly as before (regression anchor, independent fixture)
    # =====================================================================
    $r = Invoke-Flow @('-Command', 'handoff', '-Archive', '.rdd/changes/archive/mo-qa-anchor', '-Role', 'DEV')
    $devIds = Get-TaskIds @($r.json.data.tasks)
    $doneIgnored = @($r.json.data.ignored | Where-Object { $_.reason -eq 'currentOwner=已完成' })
    Assert-True ($devIds -contains 1) 'TC-126 single-owner row resolves for its owner DEV (unchanged)' ("ids=$($devIds -join ',')")
    Assert-True ($devIds -contains 3) 'TC-126 deprecated row keeps entering role output (unchanged)' ("ids=$($devIds -join ',')")
    Assert-True ($doneIgnored.Count -eq 1) 'TC-126 completed row ignored with historical currentOwner=已完成 reason' ("ignored=" + ((@($r.json.data.ignored) | ForEach-Object { $_.reason }) -join ' | '))

    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-qa-anchor')
    $d = $r.json.data
    $allIds = Get-TaskIds (@($d.roles) | ForEach-Object { $_.tasks })
    Assert-True ($d.completedCount -eq 1) 'TC-126 completedCount stays 1 (lifecycle decides)' ("completedCount=$($d.completedCount)")
    Assert-True ($allIds -notcontains 2) 'TC-126 completed task never enters a role block' ("ids=$($allIds -join ',')")

    # =====================================================================
    # TC-127 (P1/negative/AC-4): init shape errors fail loud, zero persistence
    # =====================================================================
    $badDir = Join-Path $Work '.rdd/changes/archive/mo-qa-initbad'
    New-Item -ItemType Directory -Path $badDir -Force | Out-Null
    $badJson = Join-Path $badDir 'tasks-bad.json'
    Write-Utf8NoBom $badJson '{ "tasks": [ { "title": "包装对象", "requirement": "requirements/req.md", "currentOwners": ["DEV"] } ] }'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-qa-initbad', '-TasksFile', '.rdd/changes/archive/mo-qa-initbad/tasks-bad.json')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASKS_SHAPE_INVALID') 'TC-127 wrapper object {"tasks":[...]} -> TASKS_SHAPE_INVALID' $r.raw
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $badDir 'task.json'))) 'TC-127 wrapper object: nothing persisted'

    Write-Utf8NoBom $badJson '[ { "title": "缺责任人", "requirement": "requirements/req.md" } ]'
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-qa-initbad', '-TasksFile', '.rdd/changes/archive/mo-qa-initbad/tasks-bad.json')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_MISSING_FIELD' -and $r.json.error.message -match 'tasks\[0\]' -and $r.json.error.message -match 'currentOwners') 'TC-127 missing currentOwners -> TASK_MISSING_FIELD names entry + field' $r.raw
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $badDir 'task.json'))) 'TC-127 field error: nothing persisted'

    # =====================================================================
    # TC-128 (P1/positive/AC-5): add-task -Remark lands in task.json
    # =====================================================================
    $addDir = Join-Path $Work '.rdd/changes/archive/mo-qa-addtask'
    New-Item -ItemType Directory -Path (Join-Path $addDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $addDir 'requirements/req.md') @'
# QA 备注需求
'@
    Write-Utf8NoBom (Join-Path $addDir 'tasks-init.json') @'
[
  { "title": "基础任务", "requirement": "requirements/req.md", "currentOwners": ["DEV"], "designDocs": [] }
]
'@
    $r = Invoke-Flow @('-Command', 'init', '-Archive', '.rdd/changes/archive/mo-qa-addtask', '-TasksFile', '.rdd/changes/archive/mo-qa-addtask/tasks-init.json')
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', '.rdd/changes/archive/mo-qa-addtask', '-Title', '追加并行任务QA', '-Requirement', 'requirements/req.md', '-CurrentOwners', 'CTO+UX', '-Remark', 'QA 复验备注落库')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true) 'TC-128 add-task accepts -Remark (parameter exists)' $r.raw
    $t2 = Find-Task (Read-Tasks (Join-Path $addDir 'task.json')) 2
    Assert-True ($null -ne $t2 -and [string]$t2.remark -eq 'QA 复验备注落库') 'TC-128 -Remark persisted into task.json remark' ("remark=$($t2.remark)")
    Assert-True (@($t2.currentOwners) -contains 'CTO' -and @($t2.currentOwners) -contains 'UX') 'TC-128 add-task keeps the multi-owner split (CTO+UX -> array)' ("owners=$(@($t2.currentOwners) -join '+')")

    # =====================================================================
    # TC-129 (P1/boundary/legacy): task.md hand-written CTO+UX cell gets the
    # SAME multi-owner split semantics — delivered through `migrate` (2026-09-24
    # ruling: read side is fail-loud TASK_JSON_NOT_FOUND, migrate is the only
    # legacy channel; requirement boundary "适用同样的多责任人拆分语义" holds
    # inside that channel)
    # =====================================================================
    $legDir = Join-Path $Work '.rdd/changes/archive/mo-qa-legacy'
    New-Item -ItemType Directory -Path (Join-Path $legDir 'requirements') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $legDir 'requirements/legacy.md') @'
# 遗留并行需求
'@
    Write-Utf8NoBom (Join-Path $legDir 'task.md') @'
# 任务路由总览

| TaskId | 需求 | 需求文件 | 当前责任人 | 关联设计文档 | 备注 |
|--------|------|----------|-----------|--------------|------|
| 1 | 遗留并行需求 | requirements/legacy.md | CTO+UX | - | 手写多责任人单元格 |
'@
    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-qa-legacy')
    Assert-True ($r.exit -ne 0 -and $r.json.error.code -eq 'TASK_JSON_NOT_FOUND') 'TC-129 task.md-only archive: read side fail-loud (compat layer retired by ruling)' $r.raw

    $r = Invoke-Flow @('-Command', 'migrate', '-Archive', '.rdd/changes/archive/mo-qa-legacy')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.taskCount -eq 1) 'TC-129 migrate bridges the legacy archive (one-shot)' $r.raw
    $legTask = Find-Task (Read-Tasks (Join-Path $legDir 'task.json')) 1
    Assert-True (@($legTask.currentOwners) -contains 'CTO' -and @($legTask.currentOwners) -contains 'UX') 'TC-129 hand-written CTO+UX cell split into ["CTO","UX"] (same split semantics)' ("owners=$(@($legTask.currentOwners) -join '+')")

    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-qa-legacy')
    $d = $r.json.data
    Assert-True ((Test-HasTask (Get-RoleBlock $d 'CTO') 1) -and (Test-HasTask (Get-RoleBlock $d 'UX') 1)) 'TC-129 post-migrate legacy row fans out to BOTH CTO and UX blocks'
    $r = Invoke-Flow @('-Command', 'handoff', '-Archive', '.rdd/changes/archive/mo-qa-legacy', '-Role', 'UX')
    Assert-True ($r.exit -eq 0 -and (Get-TaskIds @($r.json.data.tasks)) -contains 1) 'TC-129 post-migrate legacy row visible in handoff -UX' $r.raw

    # =====================================================================
    # TC-130 (P1/boundary): set-route semantics unchanged on multi-owner tasks —
    # serial narrowing (whole-set replace without -Phase) and whole-set switch
    # (set-route -To ... -Phase, atomic)
    # =====================================================================
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/mo-qa-route', '-TaskId', '1', '-To', 'UX')
    Assert-True ($r.exit -eq 0 -and (@($r.json.data.currentOwners) -join '+') -eq 'UX') 'TC-130 narrowing ["CTO","UX"] -> ["UX"] accepted in-phase' $r.raw
    $t1 = Find-Task (Read-Tasks (Join-Path $routeDir 'task.json')) 1
    Assert-True ((@($t1.currentOwners) -join '+') -eq 'UX') 'TC-130 narrowed owners persisted' ("owners=$(@($t1.currentOwners) -join '+')")
    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-qa-route')
    $d = $r.json.data
    Assert-True ((Test-HasTask (Get-RoleBlock $d 'UX') 1) -and -not (Test-HasTask (Get-RoleBlock $d 'CTO') 1)) 'TC-130 narrowed routing reflected in next (UX only)'

    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/mo-qa-route', '-TaskId', '1', '-To', 'CTO+UX', '-Phase', 'DESIGN')
    Assert-True ($r.exit -eq 0 -and (@($r.json.data.currentOwners) -join '+') -eq 'CTO+UX' -and $r.json.data.phase -eq 'DESIGN') 'TC-130 whole-set switch -To CTO+UX -Phase DESIGN atomic' $r.raw
    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-qa-route')
    $d = $r.json.data
    Assert-True ((Test-HasTask (Get-RoleBlock $d 'CTO') 1) -and (Test-HasTask (Get-RoleBlock $d 'UX') 1)) 'TC-130 whole-set switch reflected in next (both blocks again)'

    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', '.rdd/changes/archive/mo-qa-route', '-TaskId', '2', '-To', 'UX')
    Assert-True ($r.exit -eq 0 -and (@($r.json.data.currentOwners) -join '+') -eq 'UX') 'TC-130 literal serial narrowing ["CTO"] -> ["UX"] unchanged' $r.raw

    # =====================================================================
    # TC-131 (P1/negative): a genuinely unknown member still warns (per member),
    # mints no block; the valid member still fans out
    # =====================================================================
    $unkDir = Join-Path $Work '.rdd/changes/archive/mo-qa-unknown'
    New-Item -ItemType Directory -Path $unkDir -Force | Out-Null
    Write-Utf8NoBom (Join-Path $unkDir 'task.json') @'
{ "version": 1, "archive": "mo-qa-unknown", "tasks": [
  { "id": 1, "title": "含未知成员", "requirement": "requirements/req.md", "currentOwners": ["CTO", "XX"], "phase": "DESIGN", "designDocs": [], "currentWorker": [], "remark": "", "lifecycle": "active" }
] }
'@
    $r = Invoke-Flow @('-Command', 'next', '-Archive', '.rdd/changes/archive/mo-qa-unknown')
    $d = $r.json.data
    $warnText = @($d.warnings) -join ' | '
    Assert-True ((Test-HasTask (Get-RoleBlock $d 'CTO') 1)) 'TC-131 valid member CTO still fans out beside an unknown member'
    Assert-True ($warnText -match 'Unknown' -and $warnText -match 'XX') 'TC-131 unknown member XX still warns (single role name semantics kept)' $warnText
    Assert-True ($warnText -notmatch "'CTO\+UX'") 'TC-131 no warning ever treats a valid owner set as one role name' $warnText
    Assert-True ($null -eq (Get-RoleBlock $d 'XX')) 'TC-131 no role block minted for the unknown member'

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
