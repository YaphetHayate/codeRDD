# task claim (running status) acceptance tests — archive 2026-09-14-task-claim-running-status
# Runs rdd-flow.ps1 under the production interpreter (Windows PowerShell 5.1) against a
# throwaway git repo. Exit code 0 = all green.
#
# Usage: powershell -File test-task-claim.ps1   (or via pwsh tool)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$EngineDir   = Split-Path -Parent $PSScriptRoot | Join-Path -ChildPath 'scripts'
$FlowPs1     = Join-Path $EngineDir 'rdd-flow.ps1'
$Work        = Join-Path $env:TEMP ('task-claim-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$ArchiveRel  = '.rdd/changes/archive/claim-fixture'
$TaskJson    = Join-Path $Work ($ArchiveRel + '/task.json')

$Results = @()
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail = '')
    $script:Results += @{ name = $Name; ok = $Cond; detail = $Detail }
    if ($Cond) { Write-Output ("PASS  {0}" -f $Name) } else { Write-Output ("FAIL  {0}   {1}" -f $Name, $Detail) }
}

function Invoke-Flow { param([string[]]$ArgList)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FlowPs1) + $ArgList
    $out = & powershell @all 2>&1 | Out-String
    $code = $LASTEXITCODE
    try { $json = ($out | ConvertFrom-Json) } catch { $json = $null }
    return @{ json = $json; exit = $code; raw = $out }
}

function Read-Tasks {
    (Get-Content -LiteralPath $TaskJson -Raw -Encoding UTF8 | ConvertFrom-Json).tasks
}

function Find-Task { param($Tasks, [int]$Id)
    foreach ($t in $Tasks) { if ([int]$t.id -eq $Id) { return $t } }
    return $null
}

function Write-Utf8NoBom { param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# --- setup throwaway repo + fixture archive ---
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Push-Location $Work
try {
    git init -q 2>$null | Out-Null
    $archDir = Join-Path $Work $ArchiveRel
    New-Item -ItemType Directory -Path (Join-Path $archDir 'requirements') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $archDir 'design') -Force | Out-Null

    Write-Utf8NoBom (Join-Path $archDir 'requirements/a.md') @'
# 测试需求 A

- **描述**：认领接口验收夹具
- **优先级**：高
'@
    Write-Utf8NoBom (Join-Path $archDir 'requirements/b.md') @'
# 测试需求 B

- **描述**：含待裁决标记的需求文档
'@
    Write-Utf8NoBom (Join-Path $archDir 'requirements/c.md') @'
# 测试需求 C

- **描述**：旧格式兼容夹具
'@
    Write-Utf8NoBom (Join-Path $archDir 'design/a.md') @'
# 设计 A

## 技术方案

- 仅测试夹具

## 涉及文件

- `src/a.ts`
'@
    Write-Utf8NoBom (Join-Path $archDir 'design/b.md') @'
# 设计 B 决策

## 风险提示

- R1: 夹具风险（仅存在于次级设计文档）

## 涉及文件

- `src/b.ts`
'@
    Write-Utf8NoBom (Join-Path $archDir 'tasks-init.json') @'
[
  { "title": "认领主链路", "requirement": "requirements/a.md", "currentOwners": ["DEV"], "designDocs": [ { "path": "design/a.md", "status": "ready" } ] },
  { "title": "并行责任人互斥", "requirement": "requirements/a.md", "currentOwners": ["CTO", "UX"], "designDocs": [] },
  { "title": "驳回联动", "requirement": "requirements/a.md", "currentOwners": ["QA"], "designDocs": [] },
  { "title": "终态任务", "requirement": "requirements/a.md", "currentOwners": ["DEV"], "designDocs": [], "lifecycle": "completed" },
  { "title": "待裁决需求", "requirement": "requirements/b.md", "currentOwners": ["DEV"], "designDocs": [] },
  { "title": "旧格式兼容", "requirement": "requirements/c.md", "currentOwners": ["DEV"], "designDocs": [] }
]
'@

    # ===== init =====
    $r = Invoke-Flow @('-Command', 'init', '-Archive', $ArchiveRel, '-TasksFile', ($ArchiveRel + '/tasks-init.json'))
    Assert-True ($r.json.success -eq $true -and $r.json.data.taskCount -eq 6) 'init creates 6 tasks'

    $t1 = Find-Task (Read-Tasks) 1
    Assert-True (@($t1.currentWorker).Count -eq 0) 'init writes empty currentWorker (idle)'

    # ===== add-task carries schema =====
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $ArchiveRel, '-Title', '追加任务', '-Requirement', 'requirements/a.md', '-CurrentOwners', 'DEV')
    Assert-True ($r.json.success -eq $true) 'add-task succeeds'
    $t7 = Find-Task (Read-Tasks) 7
    Assert-True ($null -ne $t7 -and @($t7.currentWorker).Count -eq 0) 'add-task writes empty currentWorker'

    # ===== A1: idle claim writes record + full task info (acceptance 1) =====
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '1')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.claimed -eq $true) 'A1 idle claim succeeds (exit 0)'
    Assert-True (@($r.json.data.currentWorker).Count -eq 1 -and $r.json.data.currentWorker[0].DEV) 'A1 response carries DEV claim entry'
    Assert-True ($r.json.data.running -eq $true -and $r.json.data.task.running -eq $true) 'A1 running passthrough (top + task)'
    Assert-True ($r.json.data.task.workMode -eq 'design-guided') 'A1 task info workMode = design-guided'
    Assert-True ($r.json.data.task.requirement.title -like '*A') 'A1 task info carries requirement summary'
    Assert-True (@($r.json.data.task.involvedFiles) -contains 'src/a.ts') 'A1 task info carries involvedFiles'
    $firstClaimedAt = [string]$r.json.data.currentWorker[0].DEV
    $t1 = Find-Task (Read-Tasks) 1
    Assert-True (@($t1.currentWorker).Count -eq 1 -and [string]$t1.currentWorker[0].DEV -eq $firstClaimedAt) 'A1 task.json persisted with claim record'

    # ===== A2: same-role conflict — no write, info still returned (acceptance 2) =====
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '1')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.claimed -eq $false) 'A2 conflict is a success branch (exit 0, claimed:false)'
    Assert-True ($r.json.data.conflict.role -eq 'DEV' -and [string]$r.json.data.conflict.claimedAt -eq $firstClaimedAt) 'A2 conflict carries role + claimedAt'
    Assert-True ($null -ne $r.json.data.task.title) 'A2 task info still returned for task switch'
    $t1 = Find-Task (Read-Tasks) 1
    Assert-True ([string]$t1.currentWorker[0].DEV -eq $firstClaimedAt) 'A2 no write on conflict (timestamp unchanged)'

    # ===== A3 (revised): -Force overwrites, no history (user minimal ruling) =====
    Start-Sleep -Seconds 1
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '1', '-Force')
    Assert-True ($r.json.success -eq $true -and $r.json.data.claimed -eq $true -and $r.json.data.forced -eq $true) 'A3 force claim succeeds'
    $devEntries = @($r.json.data.currentWorker | Where-Object { $_.PSObject.Properties.Name -contains 'DEV' })
    Assert-True ($devEntries.Count -eq 1) 'A3 exactly one DEV entry after force'
    Assert-True ([string]$devEntries[0].DEV -gt $firstClaimedAt) 'A3 timestamp overwritten with newer value'
    $t1 = Find-Task (Read-Tasks) 1
    Assert-True (@($t1.PSObject.Properties | Where-Object { $_.Name -like '*claim*' -and $_.Name -ne 'currentWorker' }).Count -eq 0) 'A3 no claim history fields kept'

    # ===== A4: parallel owners do not block each other (acceptance 4) =====
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'CTO', '-TaskId', '2')
    Assert-True ($r.json.success -eq $true -and $r.json.data.claimed -eq $true) 'A4 CTO claims parallel task'
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'UX', '-TaskId', '2')
    Assert-True ($r.json.success -eq $true -and $r.json.data.claimed -eq $true) 'A4 UX claims same task without conflict'
    $t2 = Find-Task (Read-Tasks) 2
    Assert-True (@($t2.currentWorker).Count -eq 2) 'A4 both claims persisted'

    # ===== A5a: deprecate linkage =====
    $r = Invoke-Flow @('-Command', 'deprecate', '-Archive', $ArchiveRel, '-TaskId', '2')
    $t2 = Find-Task (Read-Tasks) 2
    Assert-True ($r.json.success -eq $true -and @($t2.currentWorker).Count -eq 0) 'A5 deprecate clears all claims (lifecycle)'

    # ===== A5b: advance linkage (acceptance 5) =====
    $r = Invoke-Flow @('-Command', 'advance', '-Archive', $ArchiveRel, '-TaskId', '1', '-From', 'DEV', '-To', 'QA')
    $t1 = Find-Task (Read-Tasks) 1
    Assert-True ($r.json.success -eq $true -and @($t1.currentWorker).Count -eq 0) 'A5 advance -From DEV clears DEV claim'
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'QA', '-TaskId', '1')
    Assert-True ($r.json.success -eq $true -and $r.json.data.claimed -eq $true) 'A5 QA can claim after advance'
    Assert-True ($r.json.data.task.workMode -eq 'requirement-guided') 'A5 QA claim info skips design (independence)'

    # ===== A5c: set-route linkage =====
    $r = Invoke-Flow @('-Command', 'set-route', '-Archive', $ArchiveRel, '-TaskId', '1', '-To', 'PM')
    $t1 = Find-Task (Read-Tasks) 1
    Assert-True ($r.json.success -eq $true -and @($t1.currentWorker).Count -eq 0) 'A5 set-route clears claims of removed owners'

    # ===== guards =====
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'QA', '-TaskId', '1')
    Assert-True ($r.exit -eq 1 -and $r.json.success -eq $false -and $r.json.error.code -eq 'ROLE_NOT_OWNER') 'guard ROLE_NOT_OWNER exit 1'
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '4')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_NOT_CLAIMABLE') 'guard lifecycle terminal -> TASK_NOT_CLAIMABLE'
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '5')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_NOT_CLAIMABLE') 'guard doc pending rejection -> TASK_NOT_CLAIMABLE'
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '99')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_NOT_FOUND') 'guard TASK_NOT_FOUND exit 1'

    # ===== A5d: reject linkage =====
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'QA', '-TaskId', '3')
    Assert-True ($r.json.success -eq $true -and $r.json.data.claimed -eq $true) 'QA claims task 3'
    $r = Invoke-Flow @('-Command', 'reject', '-Archive', $ArchiveRel, '-TaskId', '3', '-From', 'QA', '-To', 'PM', '-Reason', '夹具驳回')
    $t3 = Find-Task (Read-Tasks) 3
    Assert-True ($r.json.success -eq $true -and @($t3.currentWorker).Count -eq 0) 'A5 reject clears claims (route replaced)'

    # ===== A6: legacy task.json without currentWorker (acceptance 6) =====
    # NOTE: -InputObject (not pipeline) — PS 5.1 merges array elements when piped.
    # Keep the full document shape {version, archive, tasks}; only strip the field.
    $doc = Get-Content -LiteralPath $TaskJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($t in @($doc.tasks)) {
        if ([int]$t.id -eq 6) { $t.PSObject.Properties.Remove('currentWorker') }
    }
    Write-Utf8NoBom $TaskJson (ConvertTo-Json -InputObject $doc -Depth 8)
    $t6 = Find-Task (Read-Tasks) 6
    Assert-True ($null -eq $t6.currentWorker) 'A6 fixture: currentWorker field removed'
    $r = Invoke-Flow @('-Command', 'show', '-Archive', $ArchiveRel, '-TaskId', '6')
    Assert-True ($r.json.success -eq $true -and $r.json.data.tasks[0].running -eq $false) 'A6 show treats missing field as idle (running:false)'
    $r = Invoke-Flow @('-Command', 'check', '-Archive', $ArchiveRel)
    Assert-True ($r.json.success -eq $true -and $r.json.data.issueCount -eq 0) 'A6 check passes on legacy format' ("issues: " + (($r.json.data.issues | ForEach-Object { $_ }) -join ' | '))
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '6')
    Assert-True ($r.json.success -eq $true -and $r.json.data.claimed -eq $true) 'A6 claim writes on legacy format without error'
    $t6 = Find-Task (Read-Tasks) 6
    Assert-True (@($t6.currentWorker).Count -eq 1) 'A6 claim record persisted after rewrite'

    # ===== A5e: complete + reopen linkage =====
    $r = Invoke-Flow @('-Command', 'complete', '-Archive', $ArchiveRel, '-TaskId', '6')
    $t6 = Find-Task (Read-Tasks) 6
    Assert-True ($r.json.success -eq $true -and @($t6.currentWorker).Count -eq 0) 'A5 complete clears claims'
    $r = Invoke-Flow @('-Command', 'reopen', '-Archive', $ArchiveRel, '-TaskId', '6', '-To', 'DEV')
    $t6 = Find-Task (Read-Tasks) 6
    Assert-True ($r.json.success -eq $true -and $t6.lifecycle -eq 'active' -and @($t6.currentWorker).Count -eq 0) 'A5 reopen keeps claims empty (fresh owners)'
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '6')
    Assert-True ($r.json.success -eq $true -and $r.json.data.claimed -eq $true) 'DEV re-claims after reopen'

    # ===== claim survives unrelated writes (passthrough risk P1) =====
    $r = Invoke-Flow @('-Command', 'advance', '-Archive', $ArchiveRel, '-TaskId', '3', '-From', 'PM', '-To', 'DEV')
    Assert-True ($r.json.success -eq $true) 'unrelated advance succeeds'
    $r = Invoke-Flow @('-Command', 'add-design', '-Archive', $ArchiveRel, '-TaskId', '1', '-Path', 'design/a.md')
    Assert-True ($r.json.success -eq $true) 'unrelated add-design succeeds'
    $t6 = Find-Task (Read-Tasks) 6
    Assert-True (@($t6.currentWorker).Count -eq 1 -and $t6.currentWorker[0].DEV) 'claim survives unrelated write commands'

    # ===== A8: multi-design task — " + " joined cell resolves EVERY doc =====
    $r = Invoke-Flow @('-Command', 'add-design', '-Archive', $ArchiveRel, '-TaskId', '7', '-Path', 'design/a.md')
    Assert-True ($r.json.success -eq $true) 'A8 first design doc attached'
    $r = Invoke-Flow @('-Command', 'add-design', '-Archive', $ArchiveRel, '-TaskId', '7', '-Path', 'design/b.md')
    Assert-True ($r.json.success -eq $true) 'A8 second design doc attached'
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '7')
    Assert-True ($r.exit -eq 0 -and $r.json.success -eq $true -and $r.json.data.claimed -eq $true) 'A8 multi-design claim succeeds (exit 0)'
    Assert-True ($r.json.data.task.workMode -eq 'design-guided') 'A8 workMode = design-guided'
    $a8path = [string]$r.json.data.task.design.path
    Assert-True ($a8path -like '*design/a.md + *design/b.md*') 'A8 design.path lists both docs'
    Assert-True (@($r.json.data.task.involvedFiles) -contains 'src/a.ts' -and @($r.json.data.task.involvedFiles) -contains 'src/b.ts') 'A8 involvedFiles union across docs'
    Assert-True ([string]$r.json.data.task.design.risks -like '*R1*') 'A8 risks surfaced from secondary doc'
    Assert-True ([string]$r.json.data.task.design.technicalPlan -like '*仅测试夹具*') 'A8 technicalPlan from primary doc'

    # ===== A8 guard: any missing listed design doc blocks the DEV claim =====
    $r = Invoke-Flow @('-Command', 'add-task', '-Archive', $ArchiveRel, '-Title', '缺失设计任务', '-Requirement', 'requirements/a.md', '-CurrentOwners', 'DEV')
    Assert-True ($r.json.success -eq $true) 'A8 guard fixture task added'
    $r = Invoke-Flow @('-Command', 'add-design', '-Archive', $ArchiveRel, '-TaskId', '8', '-Path', 'design/missing.md')
    Assert-True ($r.json.success -eq $true) 'A8 guard missing design listed'
    $r = Invoke-Flow @('-Command', 'claim', '-Archive', $ArchiveRel, '-Role', 'DEV', '-TaskId', '8')
    Assert-True ($r.exit -eq 1 -and $r.json.error.code -eq 'TASK_NOT_CLAIMABLE') 'A8 guard missing design -> TASK_NOT_CLAIMABLE'
    Assert-True ([string]$r.json.error.message -like '*Design file not found*design/missing.md*') 'A8 guard message names the missing doc'

    # ===== A7: handoff passthrough carries currentWorker + running =====
    $r = Invoke-Flow @('-Command', 'handoff', '-Archive', $ArchiveRel, '-Role', 'DEV')
    $entry = $null
    foreach ($tk in @($r.json.data.tasks)) { if ([int]$tk.id -eq 6) { $entry = $tk } }
    Assert-True ($null -ne $entry) 'A7 handoff lists claimed DEV task'
    Assert-True (@($entry.currentWorker).Count -eq 1 -and $entry.running -eq $true) 'A7 handoff entry carries currentWorker + running'

    # ===== check: currentWorker field validation =====
    $doc = Get-Content -LiteralPath $TaskJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($t in @($doc.tasks)) {
        if ([int]$t.id -eq 7) {
            $t.PSObject.Properties.Remove('currentWorker')
            $t | Add-Member -NotePropertyName currentWorker -NotePropertyValue @(
                (ConvertFrom-Json '{"XX": "2026-09-14T10:00:00"}'),
                (ConvertFrom-Json '{"DEV": "2026-09-14T10:00:00"}'),
                (ConvertFrom-Json '{"DEV": ""}'),
                (ConvertFrom-Json '{"DEV": "2026-09-14T11:00:00", "QA": "2026-09-14T11:00:00"}')
            )
        }
    }
    Write-Utf8NoBom $TaskJson (ConvertTo-Json -InputObject $doc -Depth 8)
    $r = Invoke-Flow @('-Command', 'check', '-Archive', $ArchiveRel)
    $issueText = @($r.json.data.issues) -join ' | '
    Assert-True ($r.json.success -eq $true) 'check succeeds with issues reported'
    Assert-True ($issueText -like "*invalid currentWorker role 'XX'*") 'check flags role outside five-role enum'
    Assert-True ($issueText -like "*duplicate currentWorker entry for role 'DEV'*") 'check flags duplicate role key'
    Assert-True ($issueText -like '*single {role: time} object*') 'check flags multi-key entry'
    Assert-True ($issueText -like '*empty claim time*') 'check flags empty claim time'

    # ===== summary =====
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
