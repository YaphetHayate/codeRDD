# tree-run-verify.ps1 — 树形长程任务循环引擎能力 验收验证器（QA 独立实现，零依赖）
#
# 被测对象:rdd-engine/scripts/tree-run.cmd(管理面) + tree-leaf.cmd(消费面)
#   黑盒集成测试:仅通过 CLI 接口与运行目录状态文件(.rdd/tree-runs/<run-id>/)驱动与断言,
#   不触碰引擎内部函数;断言锚定需求验收标准 AC-1~AC-6 与引擎公开协议 tree-run-guide.md。
# 用例规约:.rdd/tests/tree-run/cases.json(TC-001 ~ TC-052,映射 AC-1 ~ AC-6)
#
# 用法:
#   pwsh -File .rdd/tests/tree-run/tree-run-verify.ps1 [-Suite all|basic|consume|callback|recovery|ending|e2e] [-KeepRuns] [-Json]
#   (Windows PowerShell 5.1 亦可运行;建议 pwsh 7+)
#
# 套件说明:
#   basic    启动建档/入参拒绝/task.json 正交/重复 start/gitignore —— TC-001~005
#   consume  graft 建树/节点生命周期/协议误用/并发冲突 —— TC-011~014
#   callback 有效回写/结构违规降级/截断与拒采/轮快照/verdict 降级 —— TC-021~025
#   recovery 悬挂轮 resume/不重复消费/tree.json 自愈/账本坏行隔离/跨会话续跑 —— TC-031~035
#   ending   三终局与前置校验/预算强制/结案产物 —— TC-041~046
#   e2e      根因调查式全流程 + 中断恢复 —— TC-051~052
#   all      全部
#
# 严重度语义:P0 失败=阻塞(退出码 1);P1 失败=严重不阻塞;P2 失败=备忘警告(WARN)。
# 退出码:0=无 P0 失败;1=存在 P0 失败;2=验证器自身错误。
#
# 环境说明:本验证器为 PowerShell 原生实现(不依赖 Node 子进程管道捕获,兼容受限沙箱)。
# 测试产生的运行目录(.rdd/tree-runs/qa-verify-*)默认结束后清理,-KeepRuns 保留供排查。

param(
    [ValidateSet("all", "basic", "consume", "callback", "recovery", "ending", "e2e")]
    [string]$Suite = "all",
    [switch]$KeepRuns,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---------- 全局定位 ----------

$RepoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $RepoRoot) { Write-Error "not inside a git repo"; exit 2 }
$RepoRoot = $RepoRoot -replace '/', '\'
$TreeRunCmd  = Join-Path $RepoRoot "rdd-engine\scripts\tree-run.cmd"
$TreeLeafCmd = Join-Path $RepoRoot "rdd-engine\scripts\tree-leaf.cmd"
if (-not (Test-Path $TreeRunCmd))  { Write-Host "FATAL: tree-run.cmd not found: $TreeRunCmd";  exit 2 }
if (-not (Test-Path $TreeLeafCmd)) { Write-Host "FATAL: tree-leaf.cmd not found: $TreeLeafCmd"; exit 2 }

$script:RunStamp   = "qa-verify-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID
$script:WorkDir    = Join-Path $RepoRoot (".rdd\tmp\tree-run-verify\{0}" -f $script:RunStamp)
$script:CreatedRuns = New-Object System.Collections.Generic.List[string]
New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$PlaneRepoRel = ".rdd/tests/tree-run/fixtures/mock-001/plane"   # E2E 引用范围(测试自持 mock-001 观测面)

# ---------- CLI 调用与状态读取 ----------

function Invoke-EngineCli {
    param([string]$Script, [string[]]$ArgList)
    $output = & $Script @ArgList 2>$null
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    $json = $null
    if ($text) { try { $json = $text | ConvertFrom-Json } catch { $json = $null } }
    return @{ exit = $exitCode; text = $text; json = $json }
}
function TRun  { param([string[]]$A) Invoke-EngineCli $TreeRunCmd $A }
function TLeaf { param([string[]]$A) Invoke-EngineCli $TreeLeafCmd $A }

function New-RunId { param([string]$Tag)
    $id = "{0}-{1}" -f $script:RunStamp, $Tag
    $script:CreatedRuns.Add($id)
    return $id
}
function Get-RunDirPath { param([string]$Id) Join-Path $RepoRoot (".rdd\tree-runs\{0}" -f $Id) }
function Read-RunFileText { param([string]$Id, [string]$Rel)
    [System.IO.File]::ReadAllText((Join-Path (Get-RunDirPath $Id) ($Rel -replace '/', '\')), [System.Text.Encoding]::UTF8)
}
function Read-RunManifest { param([string]$Id) (Read-RunFileText $Id "manifest.json") | ConvertFrom-Json }
function Read-RunTree      { param([string]$Id) (Read-RunFileText $Id "state/tree.json") | ConvertFrom-Json }
function Get-LedgerLines { param([string]$Id)
    $p = Join-Path (Get-RunDirPath $Id) "state\ledger.jsonl"
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return ,@() }
    $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    # 注意:逗号包裹阻止 PowerShell 函数返回时单元素数组被展开为标量(否则 $lines[0] 会取到字符串首字符)
    return ,@($t -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
}
function Get-LedgerEntryCount { param([string]$Id) (Get-LedgerLines $Id).Count }
function Test-RunFile { param([string]$Id, [string]$Rel)
    Test-Path -LiteralPath (Join-Path (Get-RunDirPath $Id) ($Rel -replace '/', '\')) -PathType Leaf
}

# ---------- JSON 构造(手工拼接保证单元素数组不被解包) ----------

function JStr { param([string]$S) ConvertTo-Json ([string]$S) -Compress }
function Join-JsonArray { param($Items)
    if ($null -eq $Items) { return "[]" }
    $arr = @($Items)
    if ($arr.Count -eq 0) { return "[]" }
    return "[" + (($arr | ForEach-Object { ConvertTo-Json $_ -Depth 8 -Compress }) -join ",") + "]"
}
function New-ValidCb {
    # 引擎强制回调 schema 的完整合法形态
    param([string]$NodeId, [string]$Verdict, [double]$Confidence, [string]$Summary, [object[]]$Citations, [string]$Next, [hashtable]$Extras)
    # 注意:数组元素必须加括号 —— PowerShell 中逗号优先级高于 +,否则成员间会丢逗号
    $parts = @(
        ('"node_id":' + (JStr $NodeId)),
        ('"verdict":' + (JStr $Verdict)),
        ('"confidence":' + $Confidence),
        ('"summary":' + (JStr $Summary)),
        ('"citations":' + (Join-JsonArray $Citations))
    )
    $parts += ('"next_suggestion":' + (JStr $Next))
    if ($Extras) { $parts += ('"extras":' + (ConvertTo-Json $Extras -Depth 6 -Compress)) }
    return "{" + ($parts -join ",") + "}"
}
function Write-TempFile { param([string]$Name, [string]$Content)
    $p = Join-Path $script:WorkDir $Name
    [System.IO.File]::WriteAllText($p, $Content, $Utf8NoBom)
    return $p
}
function Write-TasksFile { param([object[]]$Tasks)
    Write-TempFile ("tasks-{0}.json" -f ([guid]::NewGuid().ToString("N").Substring(0, 8))) (Join-JsonArray $Tasks)
}
function Submit-Report { param([string]$RunId, [string]$Worker, [string]$CbJson)
    $cbPath = Write-TempFile ("cb-{0}.json" -f ([guid]::NewGuid().ToString("N").Substring(0, 8))) $CbJson
    TLeaf @("-Command", "report", "-RunId", $RunId, "-Worker", $Worker, "-CallbackFile", $cbPath)
}
function Submit-ReportRaw { param([string]$RunId, [string]$Worker, [string]$RawJson)
    # 原样提交(用于结构违规用例:缺字段/非法类型)
    Submit-Report $RunId $Worker $RawJson
}

# ---------- 用例执行框架 ----------

$script:Results = New-Object System.Collections.Generic.List[object]
function Assert { param($Ctx, [bool]$Cond, [string]$Msg)
    if (-not $Cond) { $Ctx.fails.Add($Msg) | Out-Null }
}
function Run-Tc {
    param([string]$Id, [string]$Title, [string]$Priority, [string]$Acceptance, [scriptblock]$Body)
    $ctx = @{ id = $Id; fails = (New-Object System.Collections.Generic.List[string]) }
    try { & $Body $ctx } catch { $ctx.fails.Add("EXCEPTION: $($_.Exception.Message)") | Out-Null }
    $status = if ($ctx.fails.Count -eq 0) { "PASS" } elseif ($Priority -eq "P2") { "WARN" } else { "FAIL" }
    $script:Results.Add([pscustomobject]@{
        id = $Id; title = $Title; priority = $Priority; acceptance = $Acceptance
        status = $status; fails = @($ctx.fails)
    })
    Write-Host ("  [{0,-4}] {1} ({2}) {3}" -f $status, $Id, $Priority, $Title)
    foreach ($f in $ctx.fails) { Write-Host ("        - $f") }
}

# ---------- 正交性快照(TC-003) ----------

function Get-ChangesSnapshot {
    $root = Join-Path $RepoRoot ".rdd\changes"
    if (-not (Test-Path $root)) { return "<missing .rdd/changes>" }
    $files = @(Get-ChildItem $root -Recurse -File | Sort-Object FullName)
    $parts = foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length)
        "{0}:{1}" -f ($rel -replace '\\', '/'), (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    }
    return ($parts -join "`n")
}
$ChangesBefore = Get-ChangesSnapshot

# ============================================================
# 套件:basic — TC-001 ~ TC-005
# ============================================================

function Suite-Basic {
    Write-Host "`n== suite: basic (AC-1 启动与独立持久化) =="

    Run-Tc "TC-001" "start 建运行:manifest+tree+根节点落档,预算与引用范围持久化" "P0" "AC-1" {
        param($c)
        $rid = New-RunId "basic-start"
        $r = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "acceptance test: verify start persistence",
                    "-RefRoots", ".rdd/tests/tree-run/fixtures/mock-001", "-CreatedBy", "QA", "-Notes", "TC-001",
                    "-MaxRounds", "3", "-NodeWidth", "3", "-MaxNodes", "20")
        Assert $c ($r.exit -eq 0) "start 退出码 $($r.exit),期望 0;输出: $($r.text)"
        Assert $c ($null -ne $r.json -and $r.json.success -eq $true) "start 未返回 success=true"
        Assert $c ($r.json.data.root_node -eq "n1") "root_node=$($r.json.data.root_node),期望 n1"
        Assert $c ($r.json.data.state -eq "running") "state=$($r.json.data.state),期望 running"
        foreach ($f in @("manifest.json", "state/tree.json", "state/ledger.jsonl", "state/round-log.jsonl", "report/rounds")) {
            $exists = (Test-RunFile $rid $f) -or (Test-Path -LiteralPath (Join-Path (Get-RunDirPath $rid) ($f -replace '/', '\')))
            Assert $c $exists "缺少运行产物: $f"
        }
        $m = Read-RunManifest $rid
        Assert $c ($m.goal -eq "acceptance test: verify start persistence") "manifest.goal 未持久化: $($m.goal)"
        Assert $c ([int]$m.budget.max_rounds -eq 3 -and [int]$m.budget.node_width -eq 3 -and [int]$m.budget.max_nodes -eq 20) "manifest.budget 与入参不符: $($m.budget | ConvertTo-Json -Compress)"
        Assert $c (@($m.ref_roots) -contains ".rdd/tests/tree-run/fixtures/mock-001") "manifest.ref_roots 未含声明的根: $($m.ref_roots -join ',')"
        $t = Read-RunTree $rid
        Assert $c (@($t.nodes).Count -eq 1) "初始树节点数 $(@($t.nodes).Count),期望 1"
        Assert $c ($t.nodes[0].id -eq "n1" -and $t.nodes[0].status -eq "pending") "根节点 n1 状态异常: $($t.nodes[0].status)"
    }

    Run-Tc "TC-002" "start 非法入参拒绝(INVALID_RUN_ID/MISSING_GOAL/MISSING_REF_ROOTS/REF_ROOT_NOT_FOUND)且不留目录" "P1" "AC-1" {
        param($c)
        # 注:缺失类用例用「省略参数」表达 —— 空串参数经 cmd 转发会被吞,属宿主边界而非引擎行为
        $cases = @(
            @{ rid = "qa-verify-1bad!id"; args = @("-Goal", "g", "-RefRoots", ".rdd/tests"); code = "INVALID_RUN_ID" },
            @{ rid = "qa-verify-ok-id-a";  args = @("-RefRoots", ".rdd/tests");          code = "MISSING_GOAL" },
            @{ rid = "qa-verify-ok-id-b";  args = @("-Goal", "g");                       code = "MISSING_REF_ROOTS" },
            @{ rid = "qa-verify-ok-id-c";  args = @("-Goal", "g", "-RefRoots", "no/such/dir"); code = "REF_ROOT_NOT_FOUND" }
        )
        foreach ($x in $cases) {
            $all = @("-Command", "start", "-RunId", $x.rid) + $x.args
            $r = TRun $all
            Assert $c ($r.exit -eq 1) "[$($x.code)] 退出码 $($r.exit),期望 1"
            Assert $c ($null -ne $r.json -and $r.json.success -eq $false) "[$($x.code)] 未返回 success=false;输出: $($r.text)"
            Assert $c ($r.json.error.code -eq $x.code) "[$($x.code)] 实际错误码 $($r.json.error.code)"
            Assert $c (-not (Test-Path (Get-RunDirPath $x.rid))) "[$($x.code)] 非法 start 留下了运行目录"
        }
    }

    Run-Tc "TC-004" "重复 start 同 RunId 被拒(RUN_EXISTS),已有运行状态不被覆盖" "P2" "AC-1" {
        param($c)
        $rid = New-RunId "basic-dup"
        $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "original goal", "-RefRoots", ".rdd/tests/tree-run/fixtures/mock-001")
        $before = (Read-RunFileText $rid "manifest.json")
        $r = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "overwriting goal", "-RefRoots", ".rdd/tests")
        Assert $c ($r.exit -eq 1) "重复 start 退出码 $($r.exit),期望 1"
        Assert $c ($null -ne $r.json -and $r.json.error.code -eq "RUN_EXISTS") "错误码 $($r.json.error.code),期望 RUN_EXISTS"
        $after = (Read-RunFileText $rid "manifest.json")
        Assert $c ($before -eq $after) "重复 start 改写了已有 manifest"
    }

    Run-Tc "TC-005" ".rdd/tree-runs/ 被 gitignore 覆盖(运行数据不入版本库)" "P2" "AC-1" {
        param($c)
        & git check-ignore ".rdd/tree-runs/any-run/manifest.json" 2>$null | Out-Null
        Assert $c ($LASTEXITCODE -eq 0) "git check-ignore 退出码 $LASTEXITCODE(非 0 = 未被忽略)"
    }
}

# ============================================================
# 套件:consume — TC-011 ~ TC-014(共享一个运行)
# ============================================================

function Suite-Consume {
    Write-Host "`n== suite: consume (AC-2 建树/消费/状态流转) =="
    $rid = New-RunId "consume"
    $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "consume suite: lifecycle verification",
                   "-RefRoots", $PlaneRepoRel, "-CreatedBy", "QA", "-MaxRounds", "3", "-NodeWidth", "4", "-MaxNodes", "12")
    $null = TRun @("-Command", "round-start", "-RunId", $rid)

    Run-Tc "TC-011" "graft 颁布子任务节点:树结构正确更新(parent/children 一致、status=pending)" "P0" "AC-2" {
        param($c)
        $tf = Write-TasksFile @(
            @{ title = "h-db";    task = "verify db layer hypothesis" },
            @{ title = "h-web";   task = "verify web tier hypothesis" },
            @{ title = "h-traf";  task = "verify traffic hypothesis" },
            @{ title = "h-conf";  task = "verify config change hypothesis" }
        )
        $r = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf)
        Assert $c ($r.exit -eq 0 -and $r.json.success) "graft 失败: $($r.text)"
        Assert $c ([int]$r.json.data.count -eq 4) "graft 数量 $($r.json.data.count),期望 4"
        $ids = @($r.json.data.grafted | ForEach-Object { $_.id })
        Assert $c (($ids -join ',') -eq "n2,n3,n4,n5") "graft 返回 id 序列 $($ids -join ','),期望 n2..n5"
        $t = Read-RunTree $rid
        Assert $c (@($t.nodes).Count -eq 5) "树节点数 $(@($t.nodes).Count),期望 5"
        $n1 = @($t.nodes) | Where-Object { $_.id -eq "n1" }
        Assert $c ((@($n1.children) -join ',') -eq "n2,n3,n4,n5") "n1.children=$(@($n1.children) -join ','),期望 n2..n5"
        foreach ($id in $ids) {
            $n = @($t.nodes) | Where-Object { $_.id -eq $id }
            Assert $c ($n.parent -eq "n1") "$id.parent=$($n.parent),期望 n1"
            Assert $c ($n.status -eq "pending") "$id.status=$($n.status),期望 pending"
            Assert $c ([int]$n.created_round -eq 1) "$id.created_round=$($n.created_round),期望 1"
        }
    }

    Run-Tc "TC-012" "next→claim→report→settle 全生命周期:pending→claimed→reported→done" "P0" "AC-2" {
        param($c)
        $nx = TLeaf @("-Command", "next", "-RunId", $rid)
        Assert $c ($nx.exit -eq 0 -and $nx.json.success) "next 失败: $($nx.text)"
        $pendIds = @($nx.json.data.pending | ForEach-Object { $_.id })
        Assert $c (($pendIds -contains "n2") -and ($pendIds -contains "n5")) "next 未列出待消费节点: $($pendIds -join ',')"
        $cl = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w1")
        Assert $c ($cl.exit -eq 0 -and $cl.json.success) "claim n2 失败: $($cl.text)"
        Assert $c ($cl.json.data.node.status -eq "claimed") "claim 后状态 $($cl.json.data.node.status),期望 claimed"
        Assert $c ($cl.json.data.node.claimed_by -eq "w1") "claimed_by=$($cl.json.data.node.claimed_by),期望 w1"
        $nx2 = TLeaf @("-Command", "next", "-RunId", $rid)
        $pend2 = @($nx2.json.data.pending | ForEach-Object { $_.id })
        Assert $c ($pend2 -notcontains "n2") "claim 后 next 仍列出 n2"
        $cb = New-ValidCb -NodeId "n2" -Verdict "done" -Confidence 0.85 `
              -Summary "db layer hypothesis confirmed by slow query log" `
              -Citations @(@{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L10-L40" }) `
              -Next "dive into pool exhaustion path" -Extras @{ layer = "db" }
        $rp = Submit-Report $rid "w1" $cb
        Assert $c ($rp.exit -eq 0 -and $rp.json.success) "report 失败: $($rp.text)"
        Assert $c ($rp.json.data.accepted -eq $true) "report 未被接受"
        Assert $c ($rp.json.data.validation.status -eq "valid") "validation.status=$($rp.json.data.validation.status),期望 valid"
        Assert $c ($rp.json.data.node.status -eq "reported") "report 后状态 $($rp.json.data.node.status),期望 reported"
        $st = TLeaf @("-Command", "status", "-RunId", $rid, "-NodeId", "n2")
        Assert $c ($st.json.data.node.status -eq "reported") "leaf status n2=$($st.json.data.node.status),期望 reported"
        Assert $c ($st.json.data.node.last_verdict -eq "done") "last_verdict=$($st.json.data.node.last_verdict),期望 done"
        $se = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n2", "-Note", "settled by TC-012")
        Assert $c ($se.exit -eq 0 -and $se.json.success) "settle 失败: $($se.text)"
        $ms = TRun @("-Command", "status", "-RunId", $rid)
        Assert $c (@($ms.json.data.nodes.done) -contains "n2") "管理面 status done 列表未含 n2: $(@($ms.json.data.nodes.done) -join ',')"
    }

    Run-Tc "TC-013" "协议误用拒绝且不记账(重复claim/非持有者report/非claimed report/无开放轮)" "P0" "AC-2" {
        param($c)
        $ledgerBefore = Get-LedgerEntryCount $rid
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n3", "-Worker", "w2")
        $dup = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n3", "-Worker", "w3")
        Assert $c ($dup.exit -eq 1 -and $dup.json.error.code -eq "NODE_NOT_CLAIMABLE") "重复 claim: $($dup.text)"
        $cbOther = New-ValidCb -NodeId "n3" -Verdict "failed" -Confidence 0.5 -Summary "not holder" `
                   -Citations @(@{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L1" }) -Next ""
        $notHolder = Submit-Report $rid "w3" $cbOther
        Assert $c ($notHolder.exit -eq 1 -and $notHolder.json.error.code -eq "CLAIM_OWNER_MISMATCH") "非持有者 report: $($notHolder.text)"
        $cbPending = New-ValidCb -NodeId "n4" -Verdict "failed" -Confidence 0.5 -Summary "not claimed yet" `
                     -Citations @(@{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L1" }) -Next ""
        $notClaimed = Submit-Report $rid "w9" $cbPending
        Assert $c ($notClaimed.exit -eq 1 -and $notClaimed.json.error.code -eq "NODE_NOT_CLAIMED") "对非 claimed 节点 report: $($notClaimed.text)"
        Assert $c ((Get-LedgerEntryCount $rid) -eq $ledgerBefore) "协议误用产生了账本条目( $($ledgerBefore) → $(Get-LedgerEntryCount $rid) )"
        $re = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "r1 done", "-Decision", "continue")
        Assert $c ($re.exit -eq 0) "round-end 失败: $($re.text)"
        $noRound = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n4", "-Worker", "w2")
        Assert $c ($noRound.exit -eq 1 -and $noRound.json.error.code -eq "NO_OPEN_ROUND") "无开放轮 claim: $($noRound.text)"
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
    }

    Run-Tc "TC-014" "并发冲突:同节点二次 claim 被拒,worker 改领其他节点成功(原子领取)" "P1" "AC-2" {
        param($c)
        $c1 = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n4", "-Worker", "w2")
        Assert $c ($c1.exit -eq 0) "首个 claim n4 失败: $($c1.text)"
        $c2 = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n4", "-Worker", "w3")
        Assert $c ($c2.exit -eq 1 -and $c2.json.error.code -eq "NODE_NOT_CLAIMABLE") "冲突 claim: $($c2.text)"
        $c3 = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n5", "-Worker", "w3")
        Assert $c ($c3.exit -eq 0 -and $c3.json.data.node.claimed_by -eq "w3") "改领 n5 失败: $($c3.text)"
        $ms = TRun @("-Command", "status", "-RunId", $rid)
        $claimedIds = @($ms.json.data.nodes.claimed | ForEach-Object { $_.id })
        Assert $c (($claimedIds -contains "n4") -and ($claimedIds -contains "n5")) "status claimed 清单异常: $($claimedIds -join ',')"
    }
}

# ============================================================
# 套件:callback — TC-021 ~ TC-025(共享一个运行)
# ============================================================

function Suite-Callback {
    Write-Host "`n== suite: callback (AC-3 回写校验/降级/审计) =="
    $rid = New-RunId "callback"
    $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "callback suite: write-back validation",
                   "-RefRoots", $PlaneRepoRel, "-CreatedBy", "QA", "-MaxRounds", "3", "-NodeWidth", "5", "-MaxNodes", "15")
    $null = TRun @("-Command", "round-start", "-RunId", $rid)
    $tf = Write-TasksFile @(
        @{ title = "c-valid";  task = "valid callback path" },
        @{ title = "c-invalid"; task = "invalid callback path" },
        @{ title = "c-degrade"; task = "degraded callback path" },
        @{ title = "c-r2";     task = "round2 node" }
    )
    $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf)

    Run-Tc "TC-021" "有效回调 valid 入账:schema 完整、引用归一采纳、extras 透传" "P0" "AC-3" {
        param($c)
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w1")
        $cb = New-ValidCb -NodeId "n2" -Verdict "done" -Confidence 0.85 `
              -Summary "slow query confirmed via two independent sources" `
              -Citations @(
                  @{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L10-L40" },
                  @{ ref = "metrics/db-cpu.csv"; locator = "col:db_cpu_pct" }
              ) `
              -Next "check pool config" -Extras @{ layer = "db"; ticket = "RCA-1" }
        $rp = Submit-Report $rid "w1" $cb
        Assert $c ($rp.exit -eq 0 -and $rp.json.data.accepted -eq $true) "有效回调未被接受: $($rp.text)"
        Assert $c ($rp.json.data.validation.status -eq "valid") "validation.status=$($rp.json.data.validation.status)"
        Assert $c ($rp.json.data.validation.confidence_clamped -eq $false) "有效回调不应截断 confidence"
        Assert $c (@($rp.json.data.validation.range_check_failures).Count -eq 0) "有效回调不应有拒采记录"
        $lines = Get-LedgerLines $rid
        Assert $c ($lines.Count -eq 1) "账本条目数 $($lines.Count),期望 1"
        $e = $lines[0] | ConvertFrom-Json
        Assert $c ($e.entry_id -eq "L1" -and $e.node_id -eq "n2" -and $e.worker -eq "w1") "账本条目元数据异常: $($e.entry_id)/$($e.node_id)/$($e.worker)"
        Assert $c ($e.callback.verdict -eq "done" -and [double]$e.callback.confidence -eq 0.85) "账本回调字段异常"
        $cits = @($e.callback.citations)
        Assert $c ($cits.Count -eq 2) "账本 citations 数 $($cits.Count),期望 2(两条合法引用均采纳)"
        foreach ($ct in $cits) { Assert $c ($ct.ref -notmatch '\.\.') "归一后引用含穿越: $($ct.ref)" }
        Assert $c ($e.callback.extras.layer -eq "db") "extras 未透传: $($e.callback.extras | ConvertTo-Json -Compress)"
    }

    Run-Tc "TC-022" "结构违规回调→invalid 记账、节点不流转、运行不破坏(可修正重报)" "P0" "AC-3" {
        param($c)
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n3", "-Worker", "w2")
        # 缺 summary
        $missSummary = '{"node_id":"n3","verdict":"done","confidence":0.5,"citations":[{"ref":"logs/db-slow-query.log","locator":"L1"}],"next_suggestion":""}'
        $r1 = Submit-ReportRaw $rid "w2" $missSummary
        Assert $c ($r1.exit -eq 0) "结构违规回调应以退出码 0 降级记账,实际 $($r1.exit)(协议:不破坏运行)"
        Assert $c ($r1.json.data.accepted -eq $false) "缺 summary 应 accepted=false"
        Assert $c ($r1.json.data.validation.status -eq "invalid") "缺 summary 应 invalid,实际 $($r1.json.data.validation.status)"
        # verdict 非法
        $badVerdict = '{"node_id":"n3","verdict":"bogus","confidence":0.5,"summary":"s","citations":[{"ref":"logs/db-slow-query.log","locator":"L1"}],"next_suggestion":""}'
        $r2 = Submit-ReportRaw $rid "w2" $badVerdict
        Assert $c ($r2.json.data.accepted -eq $false -and $r2.json.data.validation.status -eq "invalid") "verdict 非法应 invalid"
        # citations 非数组
        $badCits = '{"node_id":"n3","verdict":"done","confidence":0.5,"summary":"s","citations":"not-an-array","next_suggestion":""}'
        $r3 = Submit-ReportRaw $rid "w2" $badCits
        Assert $c ($r3.json.data.accepted -eq $false -and $r3.json.data.validation.status -eq "invalid") "citations 非数组应 invalid"
        # node_id 不存在
        $badNode = '{"node_id":"n999","verdict":"done","confidence":0.5,"summary":"s","citations":[],"next_suggestion":""}'
        $r4 = Submit-ReportRaw $rid "w2" $badNode
        Assert $c ($r4.json.data.accepted -eq $false -and $r4.json.data.validation.status -eq "invalid") "node_id 不存在应 invalid"
        $st = TLeaf @("-Command", "status", "-RunId", $rid, "-NodeId", "n3")
        Assert $c ($st.json.data.node.status -eq "claimed") "invalid 回调后节点应保持 claimed,实际 $($st.json.data.node.status)"
        Assert $c ((Get-LedgerEntryCount $rid) -eq 5) "账本应 5 条(1 valid + 4 invalid),实际 $(Get-LedgerEntryCount $rid)"
        # 修正后重报成功 —— 运行未被破坏
        $fix = New-ValidCb -NodeId "n3" -Verdict "inconclusive" -Confidence 0.4 -Summary "fixed callback" `
               -Citations @(@{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L1" }) -Next ""
        $r5 = Submit-Report $rid "w2" $fix
        Assert $c ($r5.exit -eq 0 -and $r5.json.data.accepted -eq $true -and $r5.json.data.validation.status -eq "valid") "修正重报失败: $($r5.text)"
    }

    Run-Tc "TC-023" "confidence 越界截断 + 越界引用拒采记录(range_check_failures 不静默丢弃)" "P1" "AC-3" {
        param($c)
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n4", "-Worker", "w3")
        $cb = New-ValidCb -NodeId "n4" -Verdict "done" -Confidence 1.7 `
              -Summary "mixed citations: two in range, two out of range" `
              -Citations @(
                  @{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L1" },
                  @{ ref = "$PlaneRepoRel/metrics/db-pool.csv"; locator = "row:12" },
                  @{ ref = "package.json"; locator = "root" },
                  @{ ref = "../../outside-repo.log"; locator = "L1" }
              ) -Next ""
        $rp = Submit-Report $rid "w3" $cb
        Assert $c ($rp.exit -eq 0 -and $rp.json.data.accepted -eq $true) "含越界引用回调应被接受(降级不拒整个运行): $($rp.text)"
        $v = $rp.json.data.validation
        Assert $c ($v.status -eq "downgraded") "validation.status=$($v.status),期望 downgraded"
        Assert $c ($v.confidence_clamped -eq $true) "confidence=1.7 应触发截断标记"
        Assert $c ([double]$rp.json.data.node.last_confidence -eq 1.0) "截断后应 1.0,实际 $($rp.json.data.node.last_confidence)"
        $rf = @($v.range_check_failures)
        Assert $c ($rf.Count -eq 2) "拒采记录数 $($rf.Count),期望 2"
        $rfRefs = @($rf | ForEach-Object { $_.ref })
        Assert $c ($rfRefs -contains "package.json") "范围外引用未被记录(package.json)"
        Assert $c ($rfRefs -contains "../../outside-repo.log") "穿越引用未被记录(../../outside-repo.log)"
        $survivors = @($rp.json.data.node.ledger_refs) # 节点引用账本
        Assert $c ($survivors.Count -ge 1) "节点未挂账本引用"
        $e = (Get-LedgerLines $rid)[-1] | ConvertFrom-Json
        Assert $c (@($e.callback.citations).Count -eq 2) "账本仅应保留 2 条合法引用,实际 $(@($e.callback.citations).Count)"
        Assert $c ([double]$e.callback.confidence -eq 1.0) "账本 confidence 应为截断后 1.0"
    }

    Run-Tc "TC-024" "round-end 落人类可读轮快照 round-NN.md" "P0" "AC-3" {
        param($c)
        $r = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "r1 integrated: valid+invalid+downgraded all recorded", "-Decision", "continue")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "round-end 失败: $($r.text)"
        $snap = $r.json.data.snapshot
        Assert $c ($snap -match "round-01\.md$") "snapshot 路径异常: $snap"
        Assert $c (Test-RunFile $rid "report/rounds/round-01.md") "report/rounds/round-01.md 不存在"
        $txt = Read-RunFileText $rid "report/rounds/round-01.md"
        Assert $c ($txt.Trim().Length -gt 50) "轮快照内容过短($($txt.Trim().Length) 字符),应人类可读"
        Assert $c ($txt -match [regex]::Escape($rid)) "轮快照未包含 run_id,审计可读性不足"
    }

    Run-Tc "TC-025" "verdict=done 但全部引用被拒采→降级 inconclusive(verdict_downgraded)" "P2" "AC-3" {
        param($c)
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n5", "-Worker", "w4")
        $cb = New-ValidCb -NodeId "n5" -Verdict "done" -Confidence 0.6 `
              -Summary "claims done but cites nothing in range" `
              -Citations @(
                  @{ ref = "package.json"; locator = "root" },
                  @{ ref = "../escape.log"; locator = "L1" }
              ) -Next ""
        $rp = Submit-Report $rid "w4" $cb
        Assert $c ($rp.exit -eq 0 -and $rp.json.data.accepted -eq $true) "全拒采回调仍应入账: $($rp.text)"
        $v = $rp.json.data.validation
        Assert $c ($v.status -eq "downgraded") "status=$($v.status),期望 downgraded"
        Assert $c ($v.verdict_downgraded -eq $true) "verdict_downgraded 未标记"
        Assert $c ($rp.json.data.node.last_verdict -eq "inconclusive") "last_verdict=$($rp.json.data.node.last_verdict),期望 inconclusive"
    }
}

# ============================================================
# 套件:recovery — TC-031 ~ TC-035(共享一个运行)
# ============================================================

function Suite-Recovery {
    Write-Host "`n== suite: recovery (AC-4 状态文件权威/恢复/不重复消费) =="
    $rid = New-RunId "recovery"
    $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "recovery suite: interruption and resume",
                   "-RefRoots", $PlaneRepoRel, "-CreatedBy", "QA", "-MaxRounds", "3", "-NodeWidth", "4", "-MaxNodes", "12")
    $null = TRun @("-Command", "round-start", "-RunId", $rid)
    $tf = Write-TasksFile @(
        @{ title = "r-a"; task = "reported then settled" },
        @{ title = "r-b"; task = "in-flight claim" }
    )
    $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf)
    $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w1")
    $cb = New-ValidCb -NodeId "n2" -Verdict "done" -Confidence 0.8 -Summary "done in r1" `
          -Citations @(@{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L1" }) -Next ""
    $null = Submit-Report $rid "w1" $cb
    $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n3", "-Worker", "w2" )

    Run-Tc "TC-031" "悬挂轮后 resume 定位断点:hanging_round/claimed/reported/pending 清单" "P0" "AC-4" {
        param($c)
        $r = TRun @("-Command", "resume", "-RunId", $rid)
        Assert $c ($r.exit -eq 0 -and $r.json.success) "resume 失败: $($r.text)"
        $bp = $r.json.data.breakpoint
        Assert $c ([int]$bp.hanging_round -eq 1) "hanging_round=$($bp.hanging_round),期望 1(轮未收)"
        $pend = @($r.json.data.pending | ForEach-Object { $_.id })
        Assert $c ($pend -contains "n1" -and $pend -notcontains "n2") "resume.pending 异常: $($pend -join ',')"
        $claimed = @($r.json.data.claimed | ForEach-Object { $_.id })
        Assert $c ($claimed -contains "n3") "resume.claimed 未列出在飞 n3: $($claimed -join ',')"
        $rep = @($r.json.data.reported_unsettle | ForEach-Object { $_.id })
        Assert $c ($rep -contains "n2") "resume.reported_unsettle 未列出待整合 n2: $($rep -join ',')"
        Assert $c (@($r.json.data.recovery_steps).Count -gt 0) "resume 应给出恢复步骤指引"
        # 收轮后再 resume:无悬挂轮,给出下一轮编号
        $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n2")
        $null = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "r1 closed", "-Decision", "continue")
        $r2 = TRun @("-Command", "resume", "-RunId", $rid)
        $bp2 = $r2.json.data.breakpoint
        Assert $c ($null -eq $bp2.hanging_round) "收轮后 hanging_round 应为 null,实际 $($bp2.hanging_round)"
        Assert $c ([int]$bp2.next_round -eq 2) "next_round=$($bp2.next_round),期望 2"
        Assert $c ($bp2.rounds_exhausted -eq $false) "rounds_exhausted 应为 false"
    }

    Run-Tc "TC-032" "reported/done 永不可再消费:claim 拒绝,-Steal 亦不可回收" "P0" "AC-4" {
        param($c)
        $null = TRun @("-Command", "round-start", "-RunId", $rid)   # claim 前置:开放轮
        $clDone = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w5")
        Assert $c ($clDone.exit -eq 1 -and $clDone.json.error.code -eq "NODE_NOT_CLAIMABLE") "claim done 节点: $($clDone.text)"
        $stDone = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w5", "-Steal")
        Assert $c ($stDone.exit -eq 1 -and $stDone.json.error.code -eq "STEAL_REQUIRES_CLAIMED") "steal done 节点: $($stDone.text)"
        # reported(未 settle)同样不可消费
        $tf2 = Write-TasksFile @( @{ title = "r-c"; task = "reported only" } )
        $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf2)
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n4", "-Worker", "w3")
        $cb4 = New-ValidCb -NodeId "n4" -Verdict "failed" -Confidence 0.3 -Summary "reported not settled" `
               -Citations @(@{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L1" }) -Next ""
        $null = Submit-Report $rid "w3" $cb4
        $clRep = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n4", "-Worker", "w5")
        Assert $c ($clRep.exit -eq 1 -and $clRep.json.error.code -eq "NODE_NOT_CLAIMABLE") "claim reported 节点: $($clRep.text)"
        $stRep = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n4", "-Worker", "w5", "-Steal")
        Assert $c ($stRep.exit -eq 1 -and $stRep.json.error.code -eq "STEAL_REQUIRES_CLAIMED") "steal reported 节点: $($stRep.text)"
        # -Steal 正路径:仅回收 claimed 死锁
        $tf3 = Write-TasksFile @( @{ title = "r-d"; task = "stolen node" } )
        $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf3)
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n5", "-Worker", "w3")
        $steal = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n5", "-Worker", "w4", "-Steal")
        Assert $c ($steal.exit -eq 0 -and $steal.json.data.stolen -eq $true) "steal claimed 节点失败: $($steal.text)"
        Assert $c ([int]$steal.json.data.node.steal_count -eq 1) "steal_count=$($steal.json.data.node.steal_count),期望 1"
        $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n4")
    }

    Run-Tc "TC-033" "tree.json 损坏自动从 .bak 回退:status 报警,后续写原语自愈" "P0" "AC-4" {
        param($c)
        $treePath = Join-Path (Get-RunDirPath $rid) "state\tree.json"
        $bakPath  = "$treePath.bak"
        Assert $c (Test-Path $bakPath) "预置条件失败:tree.json.bak 不存在(应有写前备份)"
        [System.IO.File]::WriteAllText($treePath, '{"broken": ', $Utf8NoBom)
        $st = TRun @("-Command", "status", "-RunId", $rid)
        Assert $c ($st.exit -eq 0 -and $st.json.success) "损坏后 status 失败: $($st.text)"
        Assert $c ($st.json.data.integrity.tree_read_from_backup -eq $true) "integrity 未标记从 .bak 回退"
        Assert $c ([int]$st.json.data.nodes.total -ge 5) "回退后节点数 $($st.json.data.nodes.total),应 ≥5"
        # 后续写原语触发自愈:tree.json 恢复为合法 JSON
        $null = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "heal check", "-Decision", "continue")
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        $tf = Write-TasksFile @( @{ title = "r-heal"; task = "grafted after corruption" } )
        $g = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n3", "-TasksFile", $tf)
        Assert $c ($g.exit -eq 0 -and $g.json.success) "自愈后 graft 失败: $($g.text)"
        $healed = $null; try { $healed = Read-RunTree $rid } catch { $healed = $null }
        Assert $c ($null -ne $healed) "自愈后 tree.json 仍不可解析"
        Assert $c (@($healed.nodes).Count -eq 6) "自愈后节点数 $(@($healed.nodes).Count),期望 6"
        $nx = TLeaf @("-Command", "next", "-RunId", $rid)
        $pend = @($nx.json.data.pending | ForEach-Object { $_.id })
        Assert $c ($pend -contains "n6") "自愈后 next 未列出新增 n6: $($pend -join ',')"
    }

    Run-Tc "TC-034" "ledger 坏行隔离 .corrupt:原行保留、好行不丢、账本恢复纯 JSONL" "P1" "AC-4" {
        param($c)
        $ledgerPath = Join-Path (Get-RunDirPath $rid) "state\ledger.jsonl"
        $goodCount = Get-LedgerEntryCount $rid
        Assert $c ($goodCount -ge 2) "预置条件:账本应有 ≥2 条既有记录,实际 $goodCount"
        [System.IO.File]::AppendAllText($ledgerPath, "not-json-garbage {{{`n", $Utf8NoBom)
        $st = TRun @("-Command", "status", "-RunId", $rid)
        Assert $c ($st.exit -eq 0 -and $st.json.success) "坏行后 status 失败: $($st.text)"
        Assert $c ([int]$st.json.data.ledger.quarantined_now -ge 1) "quarantined_now=$($st.json.data.ledger.quarantined_now),期望 ≥1"
        $lines = Get-LedgerLines $rid
        Assert $c ($lines.Count -eq $goodCount) "隔离后账本行数 $($lines.Count),期望保留全部好行 $goodCount"
        $parseFail = 0
        foreach ($l in $lines) { try { $null = $l | ConvertFrom-Json } catch { $parseFail++ } }
        Assert $c ($parseFail -eq 0) "隔离后账本仍有 $parseFail 行不可解析"
        $corruptPath = "$ledgerPath.corrupt"
        Assert $c (Test-Path $corruptPath) ".corrupt 隔离区不存在"
        $corruptText = [System.IO.File]::ReadAllText($corruptPath, [System.Text.Encoding]::UTF8)
        Assert $c ($corruptText -match "not-json-garbage") ".corrupt 未保留原始坏行文本"
    }

    Run-Tc "TC-035" "跨会话凭状态文件续跑:新进程继续消费-整合-收轮全链路" "P2" "AC-4" {
        param($c)
        # 每个 CLI 调用本就是独立进程;此处验证仅凭磁盘状态即可续跑
        $cl = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n6", "-Worker", "w5")
        Assert $c ($cl.exit -eq 0) "续跑 claim 失败: $($cl.text)"
        $cb = New-ValidCb -NodeId "n6" -Verdict "done" -Confidence 0.9 -Summary "resumed session work" `
              -Citations @(@{ ref = "$PlaneRepoRel/metrics/api-latency.csv"; locator = "row:5" }) -Next ""
        $rp = Submit-Report $rid "w5" $cb
        Assert $c ($rp.exit -eq 0 -and $rp.json.data.accepted) "续跑 report 失败: $($rp.text)"
        $se = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n6")
        Assert $c ($se.exit -eq 0) "续跑 settle 失败: $($se.text)"
        $re = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "resumed round closed", "-Decision", "continue")
        Assert $c ($re.exit -eq 0) "续跑 round-end 失败: $($re.text)"
        $ms = TRun @("-Command", "status", "-RunId", $rid)
        Assert $c (@($ms.json.data.nodes.done) -contains "n6") "续跑后 n6 未达 done"
    }
}

# ============================================================
# 套件:ending — TC-041 ~ TC-046
# ============================================================

function Suite-Ending {
    Write-Host "`n== suite: ending (AC-5 三终局/预算强制/结案产物) =="
    $script:AchRun = $null; $script:BudgetRun = $null; $script:SpaceRun = $null

    Run-Tc "TC-041" "achieved:anchor done 后终结成功,产出 final-report,结案后运行冻结" "P0" "AC-5" {
        param($c)
        $rid = New-RunId "end-achieved"
        $script:AchRun = $rid
        $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "ending suite: achieved path",
                       "-RefRoots", $PlaneRepoRel, "-CreatedBy", "QA", "-MaxRounds", "3")
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        $tf = Write-TasksFile @( @{ title = "goal-node"; task = "achieve the goal" } )
        $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf)
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w1")
        $cb = New-ValidCb -NodeId "n2" -Verdict "done" -Confidence 0.95 -Summary "goal achieved with evidence" `
              -Citations @(@{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L10-L40" }) -Next ""
        $null = Submit-Report $rid "w1" $cb
        $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n2")
        $null = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "anchor settled", "-Decision", "conclude")
        $r = TRun @("-Command", "conclude", "-RunId", $rid, "-Outcome", "achieved", "-AnchorNodeId", "n2",
                    "-Summary", "ACHIEVED-FINAL-SUMMARY-041")
        Assert $c ($r.exit -eq 0 -and $r.json.success) "conclude achieved 失败: $($r.text)"
        Assert $c ($r.json.data.outcome -eq "achieved" -and $r.json.data.anchor_node -eq "n2") "conclude 返回异常: $($r.text)"
        Assert $c (Test-RunFile $rid "report/final-report.md") "final-report.md 未产出"
        $m = Read-RunManifest $rid
        Assert $c ($m.state -eq "concluded" -and $m.concluded.outcome -eq "achieved") "manifest 终局状态异常: $($m.state)"
        # 结案后冻结:管理面与消费面均不可再变更
        $tf2 = Write-TasksFile @( @{ title = "x"; task = "x" } )
        $g = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf2)
        Assert $c ($g.exit -eq 1 -and $g.json.error.code -eq "RUN_CONCLUDED") "结案后 graft 未被拒: $($g.text)"
        $cl = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n1", "-Worker", "w9")
        Assert $c ($cl.exit -eq 1 -and $cl.json.error.code -eq "RUN_CONCLUDED") "结案后 claim 未被拒: $($cl.text)"
    }

    Run-Tc "TC-042" "achieved 前置:anchor 非 done 被拒(ANCHOR_NOT_DONE/MISSING_ANCHOR),settle 后可终结" "P0" "AC-5" {
        param($c)
        $rid = New-RunId "end-anchor"
        $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "ending suite: anchor precondition",
                       "-RefRoots", $PlaneRepoRel, "-CreatedBy", "QA", "-MaxRounds", "3")
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        $tf = Write-TasksFile @( @{ title = "a"; task = "a" } )
        $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf)
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w1")
        $cb = New-ValidCb -NodeId "n2" -Verdict "done" -Confidence 0.9 -Summary "reported but not settled" `
              -Citations @(@{ ref = "$PlaneRepoRel/logs/api-access.log"; locator = "L1" }) -Next ""
        $null = Submit-Report $rid "w1" $cb
        $null = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "r1", "-Decision", "continue")
        $bad = TRun @("-Command", "conclude", "-RunId", $rid, "-Outcome", "achieved", "-AnchorNodeId", "n2", "-Summary", "s")
        Assert $c ($bad.exit -eq 1 -and $bad.json.error.code -eq "ANCHOR_NOT_DONE") "anchor=reported 时 conclude: $($bad.text)"
        $miss = TRun @("-Command", "conclude", "-RunId", $rid, "-Outcome", "achieved", "-Summary", "s")
        Assert $c ($miss.exit -eq 1 -and $miss.json.error.code -eq "MISSING_ANCHOR") "缺 anchor conclude: $($miss.text)"
        $m = Read-RunManifest $rid
        Assert $c ($m.state -eq "running") "被拒后 manifest 不应终结,实际 $($m.state)"
        # 补 settle 后终结成功 —— 拒绝可恢复
        $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n2")
        $ok = TRun @("-Command", "conclude", "-RunId", $rid, "-Outcome", "achieved", "-AnchorNodeId", "n2", "-Summary", "fixed")
        Assert $c ($ok.exit -eq 0 -and $ok.json.success) "settle 后 conclude 仍失败: $($ok.text)"
    }

    Run-Tc "TC-043" "预算诚实性:未耗尽 budget_exhausted 被拒;真耗尽(ROUNDS_EXCEEDED)后成功+结案报告" "P0" "AC-5" {
        param($c)
        $rid = New-RunId "end-budget"
        $script:BudgetRun = $rid
        $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "ending suite: budget honesty",
                       "-RefRoots", $PlaneRepoRel, "-CreatedBy", "QA", "-MaxRounds", "2")
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        $null = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "r1", "-Decision", "continue")
        $lie = TRun @("-Command", "conclude", "-RunId", $rid, "-Outcome", "budget_exhausted", "-Summary", "not really exhausted")
        Assert $c ($lie.exit -eq 1 -and $lie.json.error.code -eq "BUDGET_NOT_EXHAUSTED") "预算未耗尽时终结: $($lie.text)"
        $m = Read-RunManifest $rid
        Assert $c ($m.state -eq "running") "被拒后运行不应终结"
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        $null = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "r2", "-Decision", "continue")
        $exceed = TRun @("-Command", "round-start", "-RunId", $rid)
        Assert $c ($exceed.exit -eq 1 -and $exceed.json.error.code -eq "ROUNDS_EXCEEDED") "超轮 round-start: $($exceed.text)"
        $ok = TRun @("-Command", "conclude", "-RunId", $rid, "-Outcome", "budget_exhausted",
                     "-Summary", "BUDGET-FINAL-SUMMARY-043")
        Assert $c ($ok.exit -eq 0 -and $ok.json.success) "真耗尽后 budget_exhausted 失败: $($ok.text)"
        Assert $c (Test-RunFile $rid "report/final-report.md") "budget_exhausted 未产出 final-report.md"
        $m2 = Read-RunManifest $rid
        Assert $c ($m2.concluded.outcome -eq "budget_exhausted") "manifest.outcome=$($m2.concluded.outcome)"
    }

    Run-Tc "TC-044" "space_exhausted:无 pending+claimed 时成功;剪枝级联子树参与空间收敛" "P0" "AC-5" {
        param($c)
        $rid = New-RunId "end-space"
        $script:SpaceRun = $rid
        $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "ending suite: space exhaustion",
                       "-RefRoots", $PlaneRepoRel, "-CreatedBy", "QA", "-MaxRounds", "3")
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        $tf = Write-TasksFile @(
            @{ title = "s-a"; task = "to be pruned with child" },
            @{ title = "s-b"; task = "to be done" }
        )
        $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf)
        $early = TRun @("-Command", "conclude", "-RunId", $rid, "-Outcome", "space_exhausted", "-Summary", "s")
        Assert $c ($early.exit -eq 1 -and $early.json.error.code -eq "SPACE_NOT_EXHAUSTED") "尚有 pending 时 space_exhausted: $($early.text)"
        # 剪枝 n2 并级联其子节点 n4
        $tf2 = Write-TasksFile @( @{ title = "s-a1"; task = "child of pruned node" } )
        $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n2", "-TasksFile", $tf2)
        $pr = TRun @("-Command", "prune", "-RunId", $rid, "-NodeId", "n2", "-Reason", "refuted by evidence TC-044")
        Assert $c ($pr.exit -eq 0) "prune 失败: $($pr.text)"
        $prunedIds = @($pr.json.data.pruned)
        Assert $c (($prunedIds -contains "n2") -and ($prunedIds -contains "n4")) "剪枝未级联子树: $($prunedIds -join ',')"
        Assert $c ([int]$pr.json.data.cascade_count -eq 1) "cascade_count=$($pr.json.data.cascade_count),期望 1"
        # 根节点与 n3 走完生命周期,清空 pending/claimed
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n1", "-Worker", "w-mgr")
        $cb1 = New-ValidCb -NodeId "n1" -Verdict "done" -Confidence 0.9 -Summary "root goal wrapped" `
               -Citations @(@{ ref = "$PlaneRepoRel/logs/deploy.log"; locator = "L1" }) -Next ""
        $null = Submit-Report $rid "w-mgr" $cb1
        $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n1")
        $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n3", "-Worker", "w2")
        $cb3 = New-ValidCb -NodeId "n3" -Verdict "done" -Confidence 0.9 -Summary "s-b done" `
               -Citations @(@{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L1" }) -Next ""
        $null = Submit-Report $rid "w2" $cb3
        $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n3")
        $ok = TRun @("-Command", "conclude", "-RunId", $rid, "-Outcome", "space_exhausted", "-Summary", "SPACE-FINAL-SUMMARY-044")
        Assert $c ($ok.exit -eq 0 -and $ok.json.success) "空间收敛后 space_exhausted 失败: $($ok.text)"
        Assert $c (Test-RunFile $rid "report/final-report.md") "space_exhausted 未产出 final-report.md"
    }

    Run-Tc "TC-045" "预算强制:graft 超 NodeWidth/MaxNodes 被拒且树不破坏;任务结构非法被拒" "P1" "AC-5" {
        param($c)
        $rid = New-RunId "end-budget-graft"
        $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "ending suite: graft budgets",
                       "-RefRoots", $PlaneRepoRel, "-CreatedBy", "QA", "-MaxRounds", "2", "-NodeWidth", "2", "-MaxNodes", "4")
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        $tf2 = Write-TasksFile @(
            @{ title = "b-1"; task = "t1" },
            @{ title = "b-2"; task = "t2" }
        )
        $g1 = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf2)
        Assert $c ($g1.exit -eq 0) "width=2 内 graft 失败: $($g1.text)"
        $tf1 = Write-TasksFile @( @{ title = "b-3"; task = "t3" } )
        $w = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf1)
        Assert $c ($w.exit -eq 1 -and $w.json.error.code -eq "WIDTH_EXCEEDED") "超宽 graft: $($w.text)"
        $g2 = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n2", "-TasksFile", $tf1)
        Assert $c ($g2.exit -eq 0) "深度方向 graft(第 4 节点)失败: $($g2.text)"
        $n = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n3", "-TasksFile", $tf1)
        Assert $c ($n.exit -eq 1 -and $n.json.error.code -eq "NODES_EXCEEDED") "超节点数 graft: $($n.text)"
        $t = Read-RunTree $rid
        Assert $c (@($t.nodes).Count -eq 4) "被拒后树节点数 $(@($t.nodes).Count),应保持 4(不破坏)"
        $badTask = '{"title":"no-task-body"}'
        $tp = Write-TempFile "tasks-bad.json" "[$badTask]"
        $it = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tp)
        Assert $c ($it.exit -eq 1 -and $it.json.error.code -eq "INVALID_TASK") "缺 task body: $($it.text)"
        $nf = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", ".rdd/tmp/no-such-tasks.json")
        Assert $c ($nf.exit -eq 1 -and $nf.json.error.code -eq "TASKS_FILE_NOT_FOUND") "TasksFile 不存在: $($nf.text)"
    }

    Run-Tc "TC-046" "三终局 final-report 均含终局语义与诚实结案摘要" "P2" "AC-5" {
        param($c)
        $checks = @(
            @{ run = $script:AchRun;   token = "achieved";         summary = "ACHIEVED-FINAL-SUMMARY-041" },
            @{ run = $script:BudgetRun; token = "budget_exhausted"; summary = "BUDGET-FINAL-SUMMARY-043" },
            @{ run = $script:SpaceRun;  token = "space_exhausted";  summary = "SPACE-FINAL-SUMMARY-044" }
        )
        foreach ($x in $checks) {
            if (-not $x.run) { Assert $c $false "预置运行缺失($($x.token)),无法校验结案报告"; continue }
            $p = Join-Path (Get-RunDirPath $x.run) "report\final-report.md"
            Assert $c (Test-Path $p) "[$($x.token)] final-report.md 不存在"
            if (Test-Path $p) {
                $txt = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
                Assert $c ($txt -match [regex]::Escape($x.token)) "[$($x.token)] 报告未含终局语义"
                Assert $c ($txt -match [regex]::Escape($x.summary)) "[$($x.token)] 报告未含结案摘要文本"
                Assert $c ($txt.Trim().Length -gt 100) "[$($x.token)] 报告内容过短"
            }
        }
    }
}

# ============================================================
# 套件:e2e — TC-051 / TC-052(根因调查式)
# ============================================================

function Suite-E2E {
    Write-Host "`n== suite: e2e (AC-6 端到端真实场景) =="
    $rid = New-RunId "e2e"

    # --- 运行编排:R1(含降级/拒采/无效重报真实插曲) ---
    $null = TRun @("-Command", "start", "-RunId", $rid, "-Goal", "root cause investigation for mock-001 alerts",
                   "-RefRoots", $PlaneRepoRel, "-CreatedBy", "QA", "-Notes", "e2e acceptance run",
                   "-MaxRounds", "3", "-NodeWidth", "4", "-MaxNodes", "15")
    $null = TRun @("-Command", "round-start", "-RunId", $rid)
    $tf = Write-TasksFile @(
        @{ title = "db-slow-query"; task = "假设:数据库慢查询导致连接池耗尽"; note = "evidence in logs/db-slow-query.log" },
        @{ title = "web-tier";      task = "hypothesis: web tier latency amplification" },
        @{ title = "traffic-spike"; task = "hypothesis: traffic surge overwhelmed api" }
    )
    $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n1", "-TasksFile", $tf)
    # w1:n2 有效回写(全路径 + 根相对两种引用形态)
    $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w1-db")
    $cb1 = New-ValidCb -NodeId "n2" -Verdict "done" -Confidence 0.85 `
           -Summary "slow queries confirmed, pool exhaustion chain visible" `
           -Citations @(
               @{ ref = "$PlaneRepoRel/logs/db-slow-query.log"; locator = "L10-L40" },
               @{ ref = "metrics/db-pool.csv"; locator = "row:12" }
           ) -Next "dive into why slow queries appeared" -Extras @{ layer = "db" }
    $rp1 = Submit-Report $rid "w1-db" $cb1
    # w2:n3 降级回写(confidence 越界 + 2 条越界引用)
    $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n3", "-Worker", "w2-web")
    $cb2 = New-ValidCb -NodeId "n3" -Verdict "done" -Confidence 1.6 `
           -Summary "web tier suspected, citations partially out of scope" `
           -Citations @(
               @{ ref = "$PlaneRepoRel/logs/api-access.log"; locator = "L5" },
               @{ ref = "package.json"; locator = "root" },
               @{ ref = "../outside.log"; locator = "L1" }
           ) -Next ""
    $rp2 = Submit-Report $rid "w2-web" $cb2
    # w3:n4 先无效后修正
    $null = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n4", "-Worker", "w3-traffic")
    $null = Submit-ReportRaw $rid "w3-traffic" '{"node_id":"n4","verdict":"done","confidence":0.7,"citations":[{"ref":"logs/api-access.log","locator":"L1"}],"next_suggestion":""}'
    $cb3 = New-ValidCb -NodeId "n4" -Verdict "failed" -Confidence 0.6 `
           -Summary "traffic surge ruled out by access log volume" `
           -Citations @(@{ ref = "$PlaneRepoRel/logs/api-access.log"; locator = "L1-L99" }) -Next ""
    $rp3 = Submit-Report $rid "w3-traffic" $cb3
    # Manager 整合:settle n2/n3,prune n4,下探 n5
    $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n2", "-Note", "causal chain confirmed")
    $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n3", "-Note", "degraded but recorded")
    $null = TRun @("-Command", "prune", "-RunId", $rid, "-NodeId", "n4", "-Reason", "traffic ruled out by access log")
    $tf2 = Write-TasksFile @( @{ title = "missing-index"; task = "dive: deployment-introduced missing index" } )
    $null = TRun @("-Command", "graft", "-RunId", $rid, "-Parent", "n2", "-TasksFile", $tf2)
    $re1 = TRun @("-Command", "round-end", "-RunId", $rid,
                  "-Summary", "R1: db confirmed, web degraded-suspect, traffic refuted, dove into index layer",
                  "-Decision", "continue")

    Run-Tc "TC-052" "E2E 中断恢复:轮边界中断后新会话 resume 定位,续跑至终局零重复消费" "P1" "AC-6" {
        param($c)
        # R1 收轮后不立即开 R2 —— 模拟会话在此中断,新会话凭状态文件恢复
        $rs = TRun @("-Command", "resume", "-RunId", $rid)
        Assert $c ($rs.exit -eq 0 -and $rs.json.success) "中断后 resume 失败: $($rs.text)"
        Assert $c ($null -eq $rs.json.data.breakpoint.hanging_round) "R1 已收轮,hanging_round 应为 null"
        Assert $c ([int]$rs.json.data.breakpoint.next_round -eq 2) "next_round=$($rs.json.data.breakpoint.next_round),期望 2"
        $pend = @($rs.json.data.pending | ForEach-Object { $_.id })
        Assert $c ($pend -contains "n5") "resume 未发现待消费下探节点 n5: $($pend -join ',')"
        Assert $c ((@($rs.json.data.claimed)).Count -eq 0) "resume 应无在飞 claim"
        # --- 新会话续跑:R2 完成下探并终局 ---
        # 注:先开轮再验证重复消费拒绝 —— 引擎协议中开放轮前置检查优先于节点状态检查
        $null = TRun @("-Command", "round-start", "-RunId", $rid)
        # 已回写节点不可重复消费
        $dup = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n2", "-Worker", "w-late")
        Assert $c ($dup.exit -eq 1 -and $dup.json.error.code -eq "NODE_NOT_CLAIMABLE") "已 done 节点被重复消费: $($dup.text)"
        $cl = TLeaf @("-Command", "claim", "-RunId", $rid, "-NodeId", "n5", "-Worker", "w4-idx")
        Assert $c ($cl.exit -eq 0) "续跑 claim n5 失败: $($cl.text)"
        $cb = New-ValidCb -NodeId "n5" -Verdict "done" -Confidence 0.9 `
              -Summary "deploy dropped index confirmed as root cause" `
              -Citations @(
                  @{ ref = "$PlaneRepoRel/logs/deploy.log"; locator = "L20-L35" },
                  @{ ref = "$PlaneRepoRel/metrics/db-cpu.csv"; locator = "col:cpu" }
              ) -Next ""
        $rp = Submit-Report $rid "w4-idx" $cb
        Assert $c ($rp.exit -eq 0 -and $rp.json.data.accepted -eq $true) "续跑 report 失败: $($rp.text)"
        $null = TRun @("-Command", "settle", "-RunId", $rid, "-NodeId", "n5")
        $null = TRun @("-Command", "round-end", "-RunId", $rid, "-Summary", "R2: root cause anchored at n5", "-Decision", "conclude")
        $fin = TRun @("-Command", "conclude", "-RunId", $rid, "-Outcome", "achieved", "-AnchorNodeId", "n5",
                      "-Summary", "E2E-FINAL-REPORT: missing index during deploy caused slow queries then pool exhaustion")
        Assert $c ($fin.exit -eq 0 -and $fin.json.success) "续跑 conclude 失败: $($fin.text)"
        # 零重复消费:每个消费节点恰好 1 条已接受账本条目(n4 另有 1 条 invalid 审计记录)
        $entries = @(Get-LedgerLines $rid | ForEach-Object { $_ | ConvertFrom-Json })
        foreach ($nid in @("n2", "n3", "n4", "n5")) {
            $acc = @($entries | Where-Object { $_.node_id -eq $nid -and $_.validation.status -ne "invalid" })
            Assert $c ($acc.Count -eq 1) "节点 $nid 已接受条目数 $($acc.Count),期望 1(零重复消费)"
        }
    }

    Run-Tc "TC-051" "E2E 全流程:根因调查式完整运行,账本/轮快照/结案报告齐备可审计" "P0" "AC-6" {
        param($c)
        # 编排前置已在本套件完成;此处做全量终态审计
        Assert $c ($rp1.json.data.accepted -eq $true -and $rp1.json.data.validation.status -eq "valid") "w1 有效回写未入账"
        Assert $c ($rp2.json.data.accepted -eq $true -and $rp2.json.data.validation.status -eq "downgraded") "w2 降级回写未按预期入账"
        Assert $c (@($rp2.json.data.validation.range_check_failures).Count -eq 2) "w2 越界引用拒采记录数异常"
        Assert $c ($rp3.json.data.accepted -eq $true -and $rp3.json.data.validation.status -eq "valid") "w3 修正重报未入账"
        Assert $c ($re1.exit -eq 0) "R1 round-end 失败"
        # 终态:manifest + 报告 + 轮快照
        $m = Read-RunManifest $rid
        Assert $c ($m.state -eq "concluded" -and $m.concluded.outcome -eq "achieved" -and $m.concluded.anchor_node -eq "n5") "终局状态异常"
        Assert $c (Test-RunFile $rid "report/final-report.md") "final-report.md 缺失"
        Assert $c (Test-RunFile $rid "report/rounds/round-01.md") "round-01.md 缺失"
        Assert $c (Test-RunFile $rid "report/rounds/round-02.md") "round-02.md 缺失"
        $fr = Read-RunFileText $rid "report/final-report.md"
        Assert $c ($fr -match "achieved" -and $fr -match "E2E-FINAL-REPORT") "结案报告未含终局语义与摘要"
        # 账本统计:5 条 = 3 valid + 1 downgraded + 1 invalid;拒采 ≥2
        $ms = TRun @("-Command", "status", "-RunId", $rid)
        $lg = $ms.json.data.ledger
        Assert $c ([int]$lg.entries -eq 5) "账本条目 $($lg.entries),期望 5"
        Assert $c ([int]$lg.valid -eq 3) "valid 条目 $($lg.valid),期望 3"
        Assert $c ([int]$lg.downgraded -eq 1) "downgraded 条目 $($lg.downgraded),期望 1"
        Assert $c ([int]$lg.invalid -eq 1) "invalid 条目 $($lg.invalid),期望 1"
        Assert $c ([int]$lg.range_failures -ge 2) "range_failures $($lg.range_failures),期望 ≥2(越界引用留痕)"
        # 树终态:done 集合与剪枝集合
        $doneIds = @($ms.json.data.nodes.done)
        Assert $c (($doneIds -contains "n2") -and ($doneIds -contains "n3") -and ($doneIds -contains "n5")) "done 集合异常: $($doneIds -join ',')"
        Assert $c (@($ms.json.data.nodes.pruned) -contains "n4") "pruned 集合未含 n4: $(@($ms.json.data.nodes.pruned) -join ',')"
        # 每轮快照非空可读
        foreach ($rn in @("round-01.md", "round-02.md")) {
            $txt = Read-RunFileText $rid "report/rounds/$rn"
            Assert $c ($txt.Trim().Length -gt 50) "$rn 内容过短"
        }
    }
}

# ============================================================
# 正交性终检(TC-003,任何套件执行后对比)
# ============================================================

function Invoke-OrthogonalityCheck {
    Run-Tc "TC-003" "与 task.json 归档流转正交:全部操作后 .rdd/changes/ 零改动" "P1" "AC-1" {
        param($c)
        $after = Get-ChangesSnapshot
        Assert $c ($after -eq $ChangesBefore) ".rdd/changes/ 在测试期间被改动(要求:tree-run 与 task.json 流转互不影响)"
    }
}

# ============================================================
# 主流程
# ============================================================

Write-Host "tree-run-verify — repo: $RepoRoot"
Write-Host "suite: $Suite  (runs under .rdd/tree-runs/, stamp: $script:RunStamp)"

$selected = if ($Suite -eq "all") { @("basic", "consume", "callback", "recovery", "ending", "e2e") } else { @($Suite) }
foreach ($s in $selected) {
    switch ($s) {
        "basic"    { Suite-Basic }
        "consume"  { Suite-Consume }
        "callback" { Suite-Callback }
        "recovery" { Suite-Recovery }
        "ending"   { Suite-Ending }
        "e2e"      { Suite-E2E }
    }
}
if ($Suite -in @("all", "basic")) { Invoke-OrthogonalityCheck }

# ---------- 结果汇总 ----------

$pass = @($script:Results | Where-Object { $_.status -eq "PASS" })
$fail = @($script:Results | Where-Object { $_.status -eq "FAIL" })
$warn = @($script:Results | Where-Object { $_.status -eq "WARN" })
$p0fail = @($fail | Where-Object { $_.priority -eq "P0" })
$p1fail = @($fail | Where-Object { $_.priority -eq "P1" })

$summary = [ordered]@{
    verifier   = "tree-run-verify.ps1"
    suite      = $Suite
    ranAt      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    total      = $script:Results.Count
    passed     = $pass.Count
    failed     = $fail.Count
    warned     = $warn.Count
    p0Failures = @($p0fail | ForEach-Object { $_.id })
    p1Failures = @($p1fail | ForEach-Object { $_.id })
    blocking   = ($p0fail.Count -gt 0)
    results    = $script:Results
}
$resultsPath = Join-Path $RepoRoot (".rdd\tests\tree-run\results.json")
try {
    $summary | ConvertTo-Json -Depth 6 | ForEach-Object { [System.IO.File]::WriteAllText($resultsPath, $_, $Utf8NoBom) }
} catch { Write-Host "WARN: results.json 写入失败: $($_.Exception.Message)" }

Write-Host ""
Write-Host ("==== 总览: 通过 {0}/{1}" -f $pass.Count, $script:Results.Count)
if ($p0fail.Count -gt 0) { Write-Host "  阻塞判断: 存在 P0 失败 $($p0fail.Count) 个 → 不可标记已完成" -ForegroundColor Red }
elseif ($p1fail.Count -gt 0) { Write-Host "  阻塞判断: 无 P0 失败;P1 失败 $($p1fail.Count) 个(严重不阻塞)" -ForegroundColor Yellow }
else { Write-Host "  阻塞判断: 无阻塞失败" -ForegroundColor Green }
if ($warn.Count -gt 0) { Write-Host "  P2 备忘: $($warn.Count) 个" }

if ($Json) { $summary | ConvertTo-Json -Depth 6 }

# ---------- 清理 ----------

if (-not $KeepRuns) {
    foreach ($id in $script:CreatedRuns) {
        Remove-Item (Get-RunDirPath $id) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

exit $(if ($p0fail.Count -gt 0) { 1 } else { 0 })
