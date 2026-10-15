[CmdletBinding()]
param(
    # 非 Mandatory（start-role-usage）：无 -Role 时打印用法面并以退出码 1 结束
    # （比 PS 绑定错误对 agent 友好）；-Usage / -Help 同样打印用法面但退出码 0。
    # ValidateSet 照旧拦截非法角色名。
    [ValidateSet("PM", "CTO", "UX", "DEV", "QA", "EVAL", "PSE", "PLANNER", "AUDITOR")]
    [string]$Role = "",

    [int]$TaskId = -1,
    [string]$TaskJson = "",
    [string]$Handoff = "",
    [string]$RunId = "",
    [string]$Project = "",
    [string]$EmployeeId = "",
    [string]$PlusUrl = "http://127.0.0.1:8000",
    [string]$DshUrl = "",

    # goal-tree bridge-run marker (planner-callback-handoff): optional; the
    # delivery bridge's dispatch/auto-push injects the run/node ids so the
    # worker session can recognize the callback-to-Planner mode from its very
    # first turn. Absent (empty) → every backend's message stays byte-for-byte
    # identical to the pre-marker output (regression anchor).
    [string]$GoalTreeRun = "",
    [string]$GoalTreeNode = "",

    # pointer-message task brief (dispatch-task-goal-anchoring): optional
    # goal-first statement of THE one task the target session must execute
    # (需求标题 + 阶段 + 开工认领命令), passed only by the delivery bridge's
    # dispatch/auto-push. Empty → zero injection; every backend's message stays
    # byte-for-byte identical to the pre-brief output (regression anchor).
    [string]$TaskBrief = "",

    # file-channel variant of -TaskBrief (dispatch-brief-file): goal-tree
    # dispatch passes an ASCII PATH to a UTF-8 brief file (the node's FULL
    # title+task) instead of the text itself — the goal-tree → start-role hop
    # crosses cmd.exe %* re-parsing, where unbounded rich text (%, &, |,
    # quotes, CJK) risks silent mangling; a short ASCII path is gauntlet-proof
    # (same content discipline as graft -TasksFile / report -CallbackFile /
    # start -GoalFile). Resolved once before any message builder; the content
    # REPLACES $TaskBrief verbatim. Absent (empty) → zero resolution,
    # byte-for-byte identical output (regression anchor, same contract as
    # -TaskBrief).
    [string]$TaskBriefFile = "",

    # goal-tree generic-run worker mode (planner-tree-dispatch): passed ONLY by
    # goal-tree.cmd -Command dispatch. The target session is a worker of a
    # NON-bridge tree run (module/ops subjects — no task.json archive exists),
    # so every backend's message becomes the self-sufficient worker pointer
    # (leaf claim → node task → leaf report) instead of the archive B2 form.
    # In this mode -TaskBrief carries the NODE TASK statement (goal-tree
    # dispatch composes it from the node's own title/task — single source).
    # Absent (unset) → every backend's message stays byte-for-byte identical
    # (regression anchor, same contract as -TaskBrief).
    [switch]$GoalTreeWorker,

    # Session title label override (planner-session-roster): optional label for
    # the off-tree direct-handoff shape (-Handoff / planner direct dispatch).
    # Empty → the label derives from the handoff file's basename. Affects ONLY
    # the structured title pinned onto the freshly created dsh session
    # (session.rename, user source); the pointer message is never touched.
    [string]$SessionLabel = "",

    # Task summary title (session-list-badges): optional one-line requirement
    # summary ("「<需求标题>」<阶段>") the delivery bridge derives from the
    # persisted node.task. Rides the TITLE channel (session.rename) so the
    # workspace row shows "role pill + chips + summary" instead of the legacy
    # text marker. Display-only, never a mission parameter; empty → the title
    # keeps the legacy marker shape (regression anchor).
    [string]$TaskSummary = "",

    # in-place session reuse (inplace-redo-session-reuse): optional target of a
    # RE-DELIVERY into an already-existing dsh session. With it set, the dsh
    # branch skips preset/workspace/session.create/badges/rename entirely and
    # session.prompt(queue)s the pointer straight into the existing session
    # (the original worker keeps its full context — the whole point of in-place
    # redo); non-dsh backends reject SESSION_REUSE_UNSUPPORTED up front (no
    # terminal window or Plus conversation can be re-entered by id). Absent
    # (empty) → every backend's behavior is byte-for-byte identical to the
    # pre-feature output (regression anchor).
    [string]$ExistingSessionId = "",

    # optional appendix segment appended to the pointer message tail (B2 尾段):
    # the redo pointer's failure list + re-report instructions ride here. The
    # goal-tree marker stays in place — A0/B2 prefix-semantic recognition
    # tolerates the trailing appendix. Absent (empty) → zero injection,
    # byte-for-byte identical output (regression anchor, same contract as
    # -TaskBrief/-TaskSummary).
    [string]$Appendix = "",

    # PLANNER uniqueness guard (planner-uniqueness-callback): explicit user
    # override that skips ONLY the startup gate below — the session gets
    # created, but the orchestration right and callback re-pointing still
    # require the command-level lease (LEASE_HELD / lease -Takeover). Absent →
    # an active delivery run rejects the startup with PLANNER_RUN_ACTIVE.
    [switch]$Force,

    # 用法面（start-role-usage）：打印参数签名与常用形态后退出 0。两个拼写等价
    # （-Usage / -Help——实录验证 agent 的第一本能是 -Help）。
    [switch]$Usage,
    [switch]$Help,

    # 新需求形态（planner-pm-raw-intent 显式形）：目标任务**尚无归档**（PM 立项通道）。
    # brief（-TaskBrief / -TaskBriefFile）成为唯一锚——彻底跳过归档解析，「最新归档」
    # 兜底永远不会把会话指向前一条不相关需求。要求 brief 非空；与 -TaskJson /
    # -TaskId / -GoalTreeWorker / -Role PLANNER 互斥。
    [switch]$NoArchive,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Step { param([string]$Message); Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message); Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Err  { param([string]$Message); Write-Host "[x] $Message" -ForegroundColor Red; exit 1 }

# --- 用法面（start-role-usage）--------------------------------------------------
# 免读千行源码即可拿到参数签名；完整语义以各参数上方注释为准。
function Show-Usage {
    Write-Host @"
用法: start-role.cmd -Role <PM|CTO|UX|DEV|QA|EVAL|PSE|PLANNER|AUDITOR> [选项]
      -Usage / -Help 打印本说明（退出码 0）；无 -Role 同样打印本说明但退出码 1。

常用形态:
  PM 立项（新需求，尚无归档）:
    start-role.cmd -Role PM -NoArchive -TaskBriefFile <brief文件> -DryRun     # 先验指针再实发
  交付链节点交接（由 delivery-bridge 自动调用，一般不手敲）:
    start-role.cmd -Role DEV -TaskId 3 -TaskJson <task.json> -GoalTreeRun <id> -GoalTreeNode n4
  通用树 worker（由 goal-tree dispatch 自动调用）:
    start-role.cmd -Role DEV -GoalTreeWorker -GoalTreeRun <id> -GoalTreeNode n4 -TaskBriefFile <file>
  树外直交:  start-role.cmd -Role EVAL -Handoff <brief文件> [-SessionLabel <标签>]
  PLANNER:   start-role.cmd -Role PLANNER -TaskJson <task.json>   或   -Role PLANNER -RunId <id>

参数速览:
  -Role            目标角色（必填）
  -TaskId          归档任务号（>=1，配合归档锚定）
  -TaskJson        显式归档路径（缺省=最新归档兜底；新需求请改用 -NoArchive 显式绕开）
  -NoArchive       新需求形态：brief 为唯一锚，跳过归档解析（需 -TaskBrief/-TaskBriefFile）
  -TaskBrief       任务简报（仅 ASCII 短语；CJK 富文本必走 -TaskBriefFile 文件通道）
  -TaskBriefFile   简报文件（UTF-8，内容逐字替换 -TaskBrief——防 cmd 重解析静默损坏）
  -Handoff         树外直交 brief 文件
  -GoalTreeRun / -GoalTreeNode / -GoalTreeWorker   goal-tree 派发三件套（引擎代传）
  -SessionLabel / -TaskSummary    dsh 会话标题 / 任务摘要（仅显示层）
  -ExistingSessionId / -Appendix  既有会话复用 / 重做附录（引擎代传）
  -EmployeeId      Plus 后端员工 UUID（必填）
  -DshUrl / -PlusUrl   后端地址覆盖（缺省自动判后端：RDD_RUNTIME=app→Plus；DSH_WEB_URL→dsh；否则 CLI）
  -Project         项目根覆盖（缺省=项目根定位链）
  -RunId           PLANNER 续跑 run
  -Force           PLANNER 绕过启动门（命令级租约门仍在）
  -DryRun          只打印指针不实发（三种后端均支持）
"@ 
}

if ($Usage -or $Help) { Show-Usage; exit 0 }
if ([string]::IsNullOrWhiteSpace($Role)) { Show-Usage; Write-Err "缺少 -Role（必填）。" }

# Resolve-RepoRoot - project-root location chain (git-optional; protocol source:
# rdd-engine/references/engine-location.md, "Project-root location chain"). Fixed order:
#   1. $env:RDD_PROJECT_ROOT          explicit override; invalid path -> fail-loud
#   2. git rev-parse --show-toplevel  most accurate: worktree / submodule / GIT_DIR
#   3. nearest .git ancestor          filesystem twin of (2) when git is missing or
#                                     refuses the repo (dubious ownership)
#   4. nearest .rdd/install.json ancestor  anchors non-git projects back onto their
#                                     coderdd-init root when run from a subdirectory
#   5. cwd                            final fallback - same rule as the dsh plugin's
#                                     findRepoRoot (one mental model across the ecosystem)
# (2)+(3) keep every existing git project byte-identical (regression anchor);
# (4)+(5) only rescue trees where git says "not a repository".
function Resolve-RepoRoot {
    $envRoot = [string]$env:RDD_PROJECT_ROOT
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        if (Test-Path -LiteralPath $envRoot -PathType Container) { return $envRoot }
        throw "RDD_PROJECT_ROOT does not exist: $envRoot"
    }
    $t = $null
    # 2>$null must stay inside try/catch: under PS5.1, redirected native stderr
    # plus $ErrorActionPreference=Stop raises NativeCommandError.
    try { $t = git rev-parse --show-toplevel 2>$null } catch { }
    if ($t) { return $t.Trim() }
    $start = (Get-Location).ProviderPath
    $dir = $start
    for (;;) {
        if (Test-Path -LiteralPath (Join-Path $dir ".git")) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $dir = $start
    for (;;) {
        if (Test-Path -LiteralPath (Join-Path $dir ".rdd/install.json")) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $start
}

function Resolve-ProjectRoot {
    if ($Project) {
        if (-not (Test-Path -LiteralPath $Project -PathType Container)) { Write-Err "项目根不存在: $Project" }
        return (Resolve-Path -LiteralPath $Project).Path
    }
    return (Resolve-RepoRoot)
}

function Find-OpencodeExecutable {
    # 优先返回可直接执行的封装：.cmd / .exe / .bat
    # 跳过 .ps1 —— Windows 无法将 .ps1 作为 exe 直接启动（错误 0x800700c1）
    foreach ($name in @("opencode.cmd", "opencode.exe", "opencode.bat")) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found) { return $found.Name }
    }
    $oc = Get-Command opencode -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne ".ps1" } | Select-Object -First 1
    if ($oc) { return $oc.Name }
    return $null
}

function Resolve-AbsolutePath {
    param([string]$Path, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if (-not ([System.IO.Path]::IsPathRooted($Path))) {
        $Path = Join-Path $Root $Path
    }
    return (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
}

function Find-LatestTaskJson {
    param([string]$Root)
    $archiveRoot = Join-Path $Root ".rdd\changes\archive"
    if (-not (Test-Path -LiteralPath $archiveRoot -PathType Container)) { return "" }
    $candidates = Get-ChildItem -LiteralPath $archiveRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "task.json" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    if (-not $candidates -or $candidates.Count -eq 0) { return "" }
    # 归档名以 YYYY-MM-DD 开头，按名降序取最新
    # Select-Object -First 1 避免 Sort-Object 单元素返回字符串后被 [0] 索引成字符
    return $candidates | Sort-Object -Descending | Select-Object -First 1
}

function Test-ActiveDeliveryRun {
    # PLANNER uniqueness guard (planner-uniqueness-callback): probe whether the
    # archive named by $TaskJsonAbs already has an ACTIVE delivery run. Probe
    # path = the public goal-tree status CLI as a child process (black-box
    # style, no internal state-file coupling); RunId is the bridge's frozen
    # convention deliver-<archive-name>. Returns:
    #   $null                     probe itself failed      → caller fails OPEN
    #   @{ active = $false; ... } run answered "not found" → proceed normally
    #   @{ active = $true;  ... } active run facts         → caller rejects
    # (fail-open rationale: this gate is an auxiliary front line; the
    # command-level RUN_EXISTS / LEASE_HELD guards remain the hard backstop,
    # and failing closed would block legitimate PM-driven takeovers.)
    param([string]$TaskJsonAbs)

    $archiveName = Split-Path -Leaf (Split-Path -Parent $TaskJsonAbs)
    $runId = "deliver-$archiveName"
    $goalTreeCmd = Join-Path $PSScriptRoot "goal-tree.cmd"
    if (-not (Test-Path -LiteralPath $goalTreeCmd -PathType Leaf)) { return $null }

    $output = ""
    try {
        # stdout only: the CLI emits its JSON (success AND error objects) on
        # stdout and signals via exit code; stderr stays on the console.
        $output = (& $goalTreeCmd -Command status -RunId $runId) -join "`n"
    } catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($output)) { return $null }

    try {
        $parsed = $output | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $parsed) { return $null }

    if (-not [bool]$parsed.success) {
        # RUN_NOT_FOUND is a definite "no active run" answer; any other error
        # code is a probe self-failure → fail open at the caller.
        if ([string]$parsed.error.code -eq "RUN_NOT_FOUND") {
            return @{ active = $false; runId = $runId }
        }
        return $null
    }

    $data = $parsed.data
    $nodes = $data.nodes
    return @{
        active   = ([string]$data.state -ne "concluded")
        runId    = $runId
        state    = [string]$data.state
        goal     = [string]$data.goal
        total    = [int]$nodes.total
        pending  = @($nodes.pending).Count
        claimed  = @($nodes.claimed).Count
        reported = @($nodes.reported).Count
        done     = @($nodes.done).Count
        pruned   = @($nodes.pruned).Count
    }
}

function Get-PlannerLeaseHolder {
    # Advisory-only read of the bridge-written lease sidecar for the resume
    # hint (planner-lease.json is a delivery-bridge artifact, not goal-tree
    # internal state — reading it here keeps the status-CLI probe as the only
    # goal-tree coupling). Returns "" whenever anything is off; the hint
    # degrades silently and never blocks the resume path.
    param([string]$Root, [string]$RunId)

    try {
        $leasePath = Join-Path $Root ".rdd\goal-trees\$RunId\planner-lease.json"
        if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) { return "" }
        $lease = Get-Content -LiteralPath $leasePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $holder = [string]$lease.holder
        if ([string]::IsNullOrWhiteSpace($holder)) { return "" }
        return $holder
    } catch {
        return ""
    }
}

function Get-GoalTreeMarker {
    # goal-tree bridge-run marker segment (planner-callback-handoff): appended to
    # the message tail in ALL three backends (CLI prefill / Plus request body /
    # dsh prompt) whenever the caller passed -GoalTreeRun. The worker role's A0
    # pointer recognition tolerates the extra suffix; the skills' dual-channel
    # mode check (marker OR bridge-claim context) then routes completion to the
    # report-back-to-Planner branch instead of the 4-step direct handoff. Empty
    # input returns "" so unmarked invocations stay byte-for-byte unchanged.
    if ([string]::IsNullOrWhiteSpace($GoalTreeRun)) { return "" }
    $nodePart = ""
    if (-not [string]::IsNullOrWhiteSpace($GoalTreeNode)) { $nodePart = " node=$GoalTreeNode" }
    return " goal-tree-run=$GoalTreeRun$nodePart"
}

function Get-TaskBriefSegment {
    # Pointer-message task-brief segment (dispatch-task-goal-anchoring): the
    # goal-first statement ("本次唯一任务：…。需求文档：…。开工先领取节点：…。")
    # injected between the message base and the goal-tree marker — the marker
    # stays LAST (A0/B2 prefix-semantic recognition depends on the tail order,
    # and the marker must remain the message's trailing anchor). Same shape
    # contract as Get-GoalTreeMarker above: empty input returns "" so unbriefed
    # invocations stay byte-for-byte unchanged.
    if ([string]::IsNullOrWhiteSpace($TaskBrief)) { return "" }
    return " $TaskBrief"
}

function Get-AppendixSegment {
    # Pointer-message appendix segment (inplace-redo-session-reuse): the redo
    # instruction block appended AFTER the goal-tree marker — the reuse carrier's
    # re-anchoring payload (failure list + re-report command). It rides only
    # re-deliveries into existing sessions; empty input returns "" so every
    # unappended invocation stays byte-for-byte unchanged (regression anchor,
    # same contract as Get-TaskBriefSegment).
    if ([string]::IsNullOrWhiteSpace($Appendix)) { return "" }
    return " $Appendix"
}

function Get-IntakeCallbackSegment {
    # Intake-callback segment (planner-pm-raw-intent 回投半): rides ONLY the
    # dsh NoArchive pointer when the harness injected DSH_SESSION_ID — the
    # PM 立项 intake was pulled by THAT planner session, so completion must be
    # delivered back into it (start-role -Role PLANNER -ExistingSessionId …
    # session.prompts the takeover pointer in-place) for the planner to run its
    # routing disposition (planner-guide.md §一 路由拒绝 / PM 锚定前提).
    # Triage context is preserved by returning to the same session across all
    # dispositions (self-takeover / 结构化档 / 路由拒绝 / 显式代开). Absent
    # (non-dsh / no env) → "" keeps every other message byte-for-byte unchanged
    # (regression anchor, same contract as the segments above). Stays AHEAD of
    # the marker (marker remains the trailing anchor).
    if ($mode -ne "dsh") { return "" }
    if ([string]::IsNullOrWhiteSpace($env:DSH_SESSION_ID)) { return "" }
    $sid = $env:DSH_SESSION_ID
    return " 【立项回调协议】本次立项由规划者会话 $sid 发起：归档完成后**把接管指针投回本会话由其做路由裁定**——裁定为自接管则执行 start-role.cmd -Role PLANNER -ExistingSessionId $sid -TaskJson <新归档task.json>（可先 -DryRun 验指针）接续 promulgate；裁定为结构化档（模块/运维）则按 planner-guide.md §一 PM 锚定前提以归档为锚 goal-tree start -GoalRoot -GoalFile <归档>/requirements/overview.md（桥接链不启动）；裁定为异关注点则按 §一 路由拒绝块处置；裁定为平级规划者代开则在显式许可下执行 -Role PLANNER -TaskJson <新归档> -NoLineage（**-NoLineage 开关属延后项**，本期未落地时仍建议在侧栏手动新建 rdd-planner 会话以避免侧栏嵌套）。"
}

function Build-GoalTreeWorkerMessage {
    # goal-tree generic-run worker pointer (planner-tree-dispatch): the whole
    # message is self-sufficient — run/node identity, THE one task (-TaskBrief
    # carries the node task statement composed by goal-tree dispatch from the
    # node's own title/task), and the hard-ordered tree protocol (leaf claim →
    # task → leaf report). No archive resolution happens in this mode: the
    # subjects behind generic runs (module work, ops tasks) have no task.json.
    # The goal-tree marker still rides the tail (same trailing-anchor contract
    # as the archive forms — role-side A0 recognition tolerates the mode).
    if ($Role -eq "PLANNER") {
        Write-Err "-GoalTreeWorker 不适用于 PLANNER（规划者是树维护者，不是 worker）。"
    }
    if ([string]::IsNullOrWhiteSpace($GoalTreeRun) -or [string]::IsNullOrWhiteSpace($GoalTreeNode)) {
        Write-Err "-GoalTreeWorker 需要 -GoalTreeRun 与 -GoalTreeNode 同时非空（由 goal-tree dispatch 传入）。"
    }
    $roleLower = $Role.ToLower()
    $taskPart = ""
    if (-not [string]::IsNullOrWhiteSpace($TaskBrief)) {
        # the brief may already end in a full stop (file-channel task text);
        # trim sentence enders so the 「本次唯一任务：…。」 wrapper never doubles them
        $taskPart = "本次唯一任务：$($TaskBrief.TrimEnd('。', '．', '.', '！', '!', '？', '?'))。"
    }
    # Layered layout (identity / work order / protocol): same content contract
    # as the legacy single-line pointer — every load-bearing substring (identity
    # sentence, 本次唯一任务 lead, hard-ordered steps with the exact CLI
    # commands, guide pointer, tail marker) is preserved verbatim; only the
    # carriage returns change. The work-order layer carries a precedence note
    # because the full-text brief (file channel) coexists with the claim
    # response's node view: claim stays the canonical read (deps/dep_note
    # freshness), and a rejected claim voids the pre-injected copy (race →
    # re-pick via next, whose response carries each candidate's full task).
    return ("你是 goal-tree「$GoalTreeRun」的 worker（角色 $Role），负责节点 $GoalTreeNode（worker label: $roleLower）。`n" +
        "`n" +
        "## 工单（预注入副本）`n" +
        "> 认领成功后以 claim 响应的 node 视图为准（含最新 deps 与 dep_note）；本副本仅供开工前建立上下文，claim 被拒时即作废。`n" +
        "`n" +
        "$taskPart`n" +
        "`n" +
        "## 执行协议（硬顺序）`n" +
        "1) 领取节点（会话第一动作）：goal-tree-leaf.cmd -Command claim -RunId $GoalTreeRun -NodeId $GoalTreeNode -Worker $roleLower" +
        "（被拒按输出提示处理：NODE_NOT_CLAIMABLE=他人已领可改领 next 清单其他节点，NODE_BLOCKED_BY_DEPS=依赖未满足）；`n" +
        "2) 按任务与你的角色方法执行，证据引用范围以该 run 的 ref_roots 为准（越界引用会被引擎拒采）；`n" +
        "3) 回写回调（先写文件后提交）：`n" +
        "   a. 完整过程写 .rdd/goal-trees/$GoalTreeRun/report/workers/$GoalTreeNode.md（回调的 full_report 指向它）；`n" +
        "   b. 回调 JSON 按 rdd-engine/references/goal-tree-guide.md 回调契约构造（verdict/confidence/summary≤600字符/citations/next_suggestion）；`n" +
        "   c. goal-tree-leaf.cmd -Command report -RunId $GoalTreeRun -Worker $roleLower -CallbackFile <cb.json>；`n" +
        "4) 回读 report 输出的 validation 字段（invalid→按 reasons 修正后重新 report；downgraded→正常入账）；claim/report 之外的树变更都由规划者负责。`n" +
        (Get-GoalTreeMarker).TrimStart())
}

# === targeted tips (tips-startup-injection, v2 collision-driven) ================
# Zero config (same policy as the tips CLI): the seat caps and the segment
# copy are embedded constants — no switch, no env var, no new start-role param.
# Injection is EARNED, never granted at record time (tips v2): the eligible
# pool is collision-proven / pinned entries (status active|pinned) capped at
# $TipsEvergreenCap, plus $TipsTrialCap newest latent entries on trial — the
# trial seats give fresh lessons a chance to be recognized as duplicates
# (a collide earns them a permanent seat).
$TipsEvergreenCap = 8
$TipsTrialCap = 2

function Write-TipsDegradedWarning {
    # tips are a prompt-layer gain, never a mission parameter: ANY fetch
    # failure degrades to this console warning + zero injection and never
    # blocks the handoff (same display-layer-degradation family as the
    # title/badge pins; task params stay fail-loud on purpose).
    param([string]$Reason)
    Write-Host "[!] 定向 tips 注入降级：$Reason——本次指针消息不携带 tips 段，交接不受影响" -ForegroundColor Yellow
}

function Get-RoleTips {
    # Black-box fetch of the entries targeted at $TargetRole through the
    # public CLI — same child-process probe style as Test-ActiveDeliveryRun
    # (goal-tree probe). Both sides pin UTF-8 (tips.cmd chcp 65001 + tips.ps1
    # console encoding; this script's own UTF-8 console decodes the child
    # stdout), so CJK titles survive the capture intact. Returns the entries
    # array; ANY failure (missing CLI, empty output, non-JSON, success=false —
    # incl. CORRUPT_ENTRY exit 3, whose message names the broken file)
    # degrades to a warning + empty array.
    param([string]$TargetRole)
    $tipsCmd = Join-Path $PSScriptRoot "tips.cmd"
    if (-not (Test-Path -LiteralPath $tipsCmd -PathType Leaf)) {
        Write-TipsDegradedWarning ("tips CLI 缺失（{0}，引擎安装不完整）" -f $tipsCmd)
        return @()
    }
    $output = ""
    # Pin the child's store root to THIS handoff's $root. The CLI's own
    # cwd/env chain would otherwise resolve whichever repo the caller sits
    # in: with -Project <A> launched from a checkout of B, B's tips and
    # B-relative pointers leaked into A's pointer message (cross-module
    # root seam, found by the n9 integration pass). RDD_PROJECT_ROOT is
    # the CLI's documented override link (engine-location.md chain link 1);
    # the previous value is restored so the caller's env stays untouched.
    $prevRoot = $env:RDD_PROJECT_ROOT
    $env:RDD_PROJECT_ROOT = $root
    try {
        # stdout only: the CLI emits its JSON envelope (success AND error
        # shapes alike) on stdout and signals via exit code.
        $output = (& $tipsCmd -Command list -Role $TargetRole) -join "`n"
    }
    catch {
        Write-TipsDegradedWarning ("tips 查询子进程失败（{0}）" -f $_.Exception.Message)
        return @()
    }
    finally {
        if ([string]::IsNullOrEmpty($prevRoot)) { Remove-Item Env:\RDD_PROJECT_ROOT -ErrorAction SilentlyContinue }
        else { $env:RDD_PROJECT_ROOT = $prevRoot }
    }
    if ([string]::IsNullOrWhiteSpace($output)) {
        Write-TipsDegradedWarning "tips 查询无 stdout 输出"
        return @()
    }
    $parsed = $null
    try { $parsed = $output | ConvertFrom-Json } catch { }
    if (-not $parsed) {
        Write-TipsDegradedWarning "tips 查询输出不是 JSON 信封"
        return @()
    }
    if (-not [bool]$parsed.success) {
        Write-TipsDegradedWarning ("tips 查询失败（{0}: {1}）" -f [string]$parsed.error.code, [string]$parsed.error.message)
        return @()
    }
    if ($null -eq $parsed.data -or $null -eq $parsed.data.entries) { return @() }
    return @($parsed.data.entries)
}

function Get-TipsSegment {
    # Pointer-message targeted-tips segment (tips-startup-injection v2):
    # injected after the base sentence + handoff pointer and BEFORE the task
    # brief; the goal-tree marker keeps its trailing-anchor position. Shape
    # (seat contract, tips v2): a lead line naming the two pools — collision-
    # proven / pinned evergreen lessons (status active|pinned, capped at
    # $TipsEvergreenCap) + newest latent lessons on trial (capped at
    # $TipsTrialCap, each trial line prefixed "[新] ") — ONE numbered title
    # line per entry ("N. <title>"); the ordinal is the LLM-facing reference
    # key, the long entry id never enters the reading flow — + a single
    # quarantined pointer line freezing the number->file mapping inside the
    # message itself (a mid-session tip add cannot silently renumber what
    # this session already saw; it also freezes WHICH tips this session saw,
    # so a later collide can stamp sawTip truthfully), + an overflow hint
    # only when more exist. The entries arrive in list order (count DESC ->
    # recordedAt DESC -> id DESC): evergreen seats fill by collision
    # evidence, trial seats by recency. Entries lacking a status field (an
    # older tips CLI) count as evergreen — an upgrade seam never zeroes the
    # injection. Empty input returns "" so tip-less projects keep the
    # message byte-for-byte identical (regression anchor, same contract as
    # Get-TaskBriefSegment).
    param([array]$Entries, [string]$TargetRole)
    if (-not $Entries -or @($Entries).Count -eq 0) { return "" }
    $evergreenPool = @($Entries | Where-Object { $null -eq $_.status -or $_.status -eq "active" -or $_.status -eq "pinned" })
    $latentPool = @($Entries | Where-Object { $_.status -eq "latent" })
    $ev = @($evergreenPool | Select-Object -First $TipsEvergreenCap)
    $tr = @($latentPool | Select-Object -First $TipsTrialCap)
    $shown = @($ev) + @($tr)
    if ($shown.Count -eq 0) { return "" }
    $lines = @(("【定向 tips（{0}）——开工前先通读：以下 {1} 条为踩坑教训（{2} 条碰撞验证/置顶的常青教训 + {3} 条待碰撞验证的最新教训），详情按序号查末行指针】" -f $TargetRole, $shown.Count, $ev.Count, $tr.Count))
    for ($i = 0; $i -lt $shown.Count; $i++) {
        $marker = ""
        if ($i -ge $ev.Count) { $marker = "[新] " }
        $lines += ("{0}. {1}{2}" -f ($i + 1), $marker, ([string]$shown[$i].title))
    }
    $pointers = for ($j = 0; $j -lt $shown.Count; $j++) { "{0}={1}" -f ($j + 1), [string]$shown[$j].path }
    $lines += "详情指针：" + ($pointers -join "；")
    $hidden = ($evergreenPool.Count - $ev.Count) + ($latentPool.Count - $tr.Count)
    if ($hidden -gt 0) {
        $lines += ("（另有 {0} 条未列出，可经 tips.cmd -Command list -Role {1} 查看全量）" -f $hidden, $TargetRole)
    }
    return "`n" + ($lines -join "`n") + "`n"
}

function ConvertTo-RunShortName {
    # planner-session-roster: sidebar-friendly short name of a delivery run —
    # "deliver-2026-09-20-planner-session-roster" -> "planner-session-roster"
    # (run id minus the deliver- prefix, archive name minus its date prefix).
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return "" }
    $archiveName = $Raw -replace '^deliver-', ''
    return ($archiveName -replace '^\d{4}-\d{2}-\d{2}-', '')
}

function Get-RunShortName {
    # planner-session-roster: resolve the run short name from the invocation's
    # own params. Priority: -RunId (PLANNER resume shape) -> -TaskJson / latest
    # archive name (PLANNER takeover shape). Degrades to "" (the caller then
    # skips the rename entirely) — the title is display-only, never a mission
    # parameter.
    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        return (ConvertTo-RunShortName $RunId)
    }
    $taskJsonAbs = $null
    if (-not [string]::IsNullOrWhiteSpace($TaskJson)) {
        $taskJsonAbs = Resolve-AbsolutePath -Path $TaskJson -Root $root
    }
    else {
        $taskJsonAbs = Find-LatestTaskJson -Root $root
    }
    if (-not $taskJsonAbs) { return "" }
    return (ConvertTo-RunShortName (Split-Path -Leaf (Split-Path -Parent $taskJsonAbs)))
}

function Get-SessionTitle {
    # planner-session-roster: the structured, distinguishing title pinned onto
    # the freshly created dsh session (session.rename appends a user-source
    # title event, which pins the title against first-message auto-regeneration
    # — the pointer message is the SAME for every dispatch, so auto titles
    # would collapse the whole run into identical sidebar entries). Shapes, in
    # priority order:
    #   PLANNER body     "<run短名>"（PLANNER 身份由 preset 角色胶囊承载——见 Get-SessionBadges v2）
    #   bridge dispatch  "[<run短名>] T<#>·<角色>·<节点>"   (-GoalTreeRun shape)
    #   off-tree direct  "[直交] <标签>·<角色>"            (-Handoff / -SessionLabel)
    # Returns "" for the unmarked plain handoff (no goal-tree marker, no
    # handoff, no label) — those invocations stay byte-for-byte identical to
    # the pre-feature behavior (regression anchor: no rename call at all, no
    # roster side effects). Title info comes ONLY from existing params; length
    # normalization is the host's business (rename rejects only empty titles).
    if ($Role -eq "PLANNER") {
        $short = Get-RunShortName
        if (-not $short) { return "" }
        return $short
    }
    if (-not [string]::IsNullOrWhiteSpace($GoalTreeRun)) {
        $short = ConvertTo-RunShortName $GoalTreeRun
        if (-not $short) { return "" }
        $parts = @()
        if ($TaskId -ge 1) { $parts += "T$TaskId" }
        $parts += $Role
        if (-not [string]::IsNullOrWhiteSpace($GoalTreeNode)) { $parts += $GoalTreeNode }
        return "[{0}] {1}" -f $short, ($parts -join '·')
    }
    $handoffPresent = -not [string]::IsNullOrWhiteSpace($Handoff)
    $labelPresent = -not [string]::IsNullOrWhiteSpace($SessionLabel)
    if ($handoffPresent -or $labelPresent) {
        $label = ""
        if ($labelPresent) {
            $label = $SessionLabel.Trim()
        }
        else {
            $leaf = Split-Path -Leaf ($Handoff.Trim())
            $label = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        }
        if ([string]::IsNullOrWhiteSpace($label)) { return "" }
        return "[直交] $label·$Role"
    }
    return ""
}

function Get-SessionBadges {
    # session-list-badges v2 (user ruling 2026-09-24): the DSH row renderer
    # derives the role identity pill from the session's live agent preset
    # (rdd-<role>, enum-only text, one distinct glyph per role) — dispatched
    # AND user-created role sessions show it with no badge write at all.
    # setBadges therefore no longer carries role text; it writes only the
    # structural facts the preset cannot know:
    #   PLANNER body     (none — the preset pill covers the identity)
    #   bridge dispatch  rdd:task(T#) [+ rdd:node(<节点>)]（值链文字）
    #   off-tree direct  rdd:direct（无 label：渲染为纯 ▶ 标记；自定义标签只留在钉住标题里）
    # Returns @() whenever nothing structural rides along — zero badges, zero
    # setBadges calls, behavior byte-for-byte identical to the pre-feature
    # output (regression anchor, same contract as Get-SessionTitle's "" return).
    $badges = @()
    if ($Role -eq "PLANNER") {
        return $badges
    }
    if (-not [string]::IsNullOrWhiteSpace($GoalTreeRun)) {
        if ($TaskId -ge 1) { $badges += @{ kind = "rdd:task"; label = "T$TaskId" } }
        if (-not [string]::IsNullOrWhiteSpace($GoalTreeNode)) { $badges += @{ kind = "rdd:node"; label = $GoalTreeNode } }
        return $badges
    }
    $handoffPresent = -not [string]::IsNullOrWhiteSpace($Handoff)
    $labelPresent = -not [string]::IsNullOrWhiteSpace($SessionLabel)
    if ($handoffPresent -or $labelPresent) {
        # Same label validity gate as Get-SessionTitle's 直交 shape: an empty
        # derived label means no marker at all (no title, no badge — the
        # regression anchor stays byte-identical).
        $label = ""
        if ($labelPresent) {
            $label = $SessionLabel.Trim()
        }
        else {
            $leaf = Split-Path -Leaf ($Handoff.Trim())
            $label = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        }
        if (-not [string]::IsNullOrWhiteSpace($label)) {
            $badges += @{ kind = "rdd:direct" }
        }
    }
    return $badges
}

function Get-PinnedTitle {
    # session-list-badges: the title text the rename RPC actually pins, given
    # the legacy marker title, the badge pin verdict, and the optional task
    # summary. Badges pinned → the summary alone replaces the marker text (the
    # chips carry the structure now, freeing the whole 80-byte budget for the
    # requirement line); badges failed → one-shot degraded concatenation keeps
    # the structural facts alive in text form (single rename, no second
    # overwrite); no badges → the legacy shape stands unchanged.
    param([string]$LegacyTitle, [bool]$BadgesPinned, [string]$Summary)
    if ([string]::IsNullOrWhiteSpace($Summary)) { return $LegacyTitle }
    if ($BadgesPinned) { return $Summary.Trim() }
    if ($LegacyTitle) { return "$LegacyTitle $($Summary.Trim())" }
    return $Summary.Trim()
}

function Build-PromptMessage {
    # 优先级：Handoff 模式 > TaskId 模式 > 纯角色激活
    # 路径不套内层引号（避免 wt 参数解析中断）；LLM 按文本读取路径
    $roleLower = $Role.ToLower()
    $base = "/rdd-$roleLower"

    # PLANNER 自举式指针：规划者（PLANNER）是引擎编排形态而非角色卡（无 /rdd-planner
    # 斜杠命令可加载），CLI 预填消息本身携带身份引导——指向 planner-guide.md。
    if ($Role -eq "PLANNER") {
        if (-not [string]::IsNullOrWhiteSpace($RunId)) {
            return "你是 RDD PLANNER（规划者）。先读 rdd-engine/references/planner-guide.md，然后执行 delivery-bridge resume -RunId $RunId 续跑交付。"
        }
        $taskJsonAbs = if (-not [string]::IsNullOrWhiteSpace($TaskJson)) {
            Resolve-AbsolutePath -Path $TaskJson -Root $root
        } else {
            Find-LatestTaskJson -Root $root
        }
        if (-not $taskJsonAbs) {
            Write-Err "未找到 task.json。请用 -TaskJson 显式指定，或确保 .rdd/changes/archive/ 下有归档。"
        }
        return "你是 RDD PLANNER（规划者）。先读 rdd-engine/references/planner-guide.md；接管后先按 rdd-engine/references/review-input-template.md 机械模板派需求审视子代理（独立上下文，禁转述），结论呈用户后用 delivery-bridge promulgate -TaskJson $taskJsonAbs -ReviewMode subagent 接管该归档的整批交付。-ReviewMode 不可省：省略即 legacy 链，设计审查为会话节点、需真实 AUDITOR 会话结算，dsh 默认 preset 面不可派发。"
    }

    # goal-tree generic-run worker mode (planner-tree-dispatch): self-sufficient
    # worker pointer instead of the archive form — CLI prefill IS the message.
    if ($GoalTreeWorker) {
        return Build-GoalTreeWorkerMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($Handoff)) {
        $abs = Resolve-AbsolutePath -Path $Handoff -Root $root
        if (-not $abs) { Write-Err "Handoff 文件不存在: $Handoff" }
        return "$base handoff=$abs$(Get-GoalTreeMarker)"
    }

    if ($TaskId -ge 1) {
        $taskJsonAbs = if (-not [string]::IsNullOrWhiteSpace($TaskJson)) {
            Resolve-AbsolutePath -Path $TaskJson -Root $root
        } else {
            Find-LatestTaskJson -Root $root
        }
        if (-not $taskJsonAbs) {
            Write-Err "未找到 task.json。请用 -TaskJson 显式指定，或确保 .rdd/changes/archive/ 下有归档。"
        }
        # order = base + brief segment + marker segment; marker stays last
        # (Handoff / PLANNER branches above stay unbriefed — bridge dispatches
        # use TaskId mode only)
        return "$base TaskId=$TaskId task=$taskJsonAbs$(Get-TaskBriefSegment)$(Get-GoalTreeMarker)"
    }

    # new-requirement intake (planner-pm-raw-intent 显式形): brief-only prefill —
    # archive resolution is skipped entirely (an older, unrelated archive can
    # never leak into the prefill); the framing prefix tells the role the
    # archive does not exist yet and is ITS to create.
    if ($NoArchive) {
        return "$base 新需求（尚无归档——归档由你创建，勿处理既有归档）$(Get-TaskBriefSegment)$(Get-GoalTreeMarker)"
    }

    # pure-role activation (planner-pm-raw-intent): a raw-intent brief rides the
    # prefill — the PM 立项 channel, where the planner passes the user's
    # requirement verbatim and no archive exists yet. Empty brief keeps this
    # return byte-for-byte with the legacy unbriefed shape.
    return "$base$(Get-TaskBriefSegment)$(Get-GoalTreeMarker)"
}

function Test-WindowsTerminal { return [bool](Get-Command wt.exe -ErrorAction SilentlyContinue) }

function Resolve-RuntimeMode {
    # Plus injects RDD_RUNTIME=app into the opencode server subprocess; that env
    # propagates to every agent/tool spawned inside the app (including this
    # script). A dsh (Web GUI) session instead injects DSH_WEB_URL — the local
    # URL of the Web GUI serving this session — into every shell subprocess.
    # Returns "app", "dsh", or "cli". The chain order is fixed and is the
    # single source of truth for backend selection — agents never judge the
    # mode themselves. RDD_RUNTIME wins so a leaked Plus marker can never
    # reroute a dsh/CLI handoff.
    if ($env:RDD_RUNTIME -eq "app") { return "app" }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_WEB_URL)) { return "dsh" }
    return "cli"
}

function Resolve-TaskJsonAbsolute {
    # Shared by both backends: resolve the task.json path (explicit -TaskJson or
    # latest archive). Returns "" if none found.
    if (-not [string]::IsNullOrWhiteSpace($TaskJson)) {
        return Resolve-AbsolutePath -Path $TaskJson -Root $root
    }
    return Find-LatestTaskJson -Root $root
}

function Get-RelativePathFromRoot {
    # PS 5.1 (.NET Framework) lacks [System.IO.Path]::GetRelativePath, so compute
    # manually. Both inputs are absolute paths under the same root (drive). Returns
    # a forward-slashed relative path (empty if $AbsPath equals the root).
    param([string]$AbsPath, [string]$RootPath)
    if (-not $AbsPath) { return "" }
    $abs = (Resolve-Path -LiteralPath $AbsPath -ErrorAction SilentlyContinue).Path
    $base = (Resolve-Path -LiteralPath $RootPath -ErrorAction SilentlyContinue).Path
    if (-not $abs -or -not $base) { return ($AbsPath -replace '\\', '/') }
    $baseTrim = $base.TrimEnd('\', '/')
    if ($abs -ieq $baseTrim) { return "" }
    $baseWithSep = $baseTrim + '\'
    if ($abs.StartsWith($baseWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $abs.Substring($baseWithSep.Length)
    } else {
        $rel = $abs
    }
    return ($rel -replace '\\', '/')
}

function Resolve-ArchiveRelativePath {
    param([string]$TaskJsonAbs, [string]$RootPath)
    # Derive ".rdd/changes/archive/<name>" from the task.json location.
    # Forward slashes so the pointer message matches transition-guide B2 format.
    if (-not $TaskJsonAbs) { return "" }
    $parent = Split-Path -Parent $TaskJsonAbs
    $rel = Get-RelativePathFromRoot -AbsPath $parent -RootPath $RootPath
    if ($rel) { return "$rel/" }
    return ""
}

function Build-PointerMessage {
    # App-driven backends (Plus, dsh) bind the role SKILL via the employee's
    # agent_mode / the rdd-<role> agent preset, so the slash command form does
    # NOT work there. Instead emit the app-layer pointer message
    # (transition-guide entry B2/C), which the role's SKILL recognizes and
    # pulls handoff from.
    #
    # PLANNER variant: bootstrap pointer (no role card exists to bind) — the
    # message itself names the Planner identity and the first-read document
    # (planner-guide.md), plus the concrete bridge command for takeover/resume.
    if ($Role -eq "PLANNER") {
        if (-not [string]::IsNullOrWhiteSpace($RunId)) {
            return "请以规划者（PLANNER）身份续跑 goal-tree 交付 run ${RunId}：先读 rdd-engine/references/planner-guide.md，随后执行 delivery-bridge -Command resume -RunId $RunId 按断点续跑。"
        }
        $taskJsonAbs = Resolve-TaskJsonAbsolute
        if (-not $taskJsonAbs) {
            Write-Err "应用层交接（Plus/dsh 后端）需要 task.json 来定位归档。请用 -TaskJson 指定，或确保 .rdd/changes/archive/ 下有归档。"
        }
        $archiveRel = Resolve-ArchiveRelativePath -TaskJsonAbs $taskJsonAbs -RootPath $root
        if (-not $archiveRel) { Write-Err "无法从 task.json 路径推导归档相对路径: $taskJsonAbs" }
        return "请以规划者（PLANNER）身份接管 ${archiveRel}的整批交付：先读 rdd-engine/references/planner-guide.md，按 rdd-engine/references/review-input-template.md 机械模板派需求审视子代理（独立上下文，禁转述）并把结论呈用户，随后执行 delivery-bridge -Command promulgate -TaskJson $taskJsonAbs -ReviewMode subagent 颁布交付节点并按需调动角色会话。-ReviewMode 不可省：省略即 legacy 链，设计审查为会话节点、需真实 AUDITOR 会话结算，dsh 默认 preset 面不可派发。"
    }

    # goal-tree generic-run worker mode (planner-tree-dispatch): same
    # self-sufficient worker pointer as the CLI prefill — no archive
    # resolution (generic runs have no task.json to point at).
    if ($GoalTreeWorker) {
        return Build-GoalTreeWorkerMessage
    }

    # new-requirement intake (planner-pm-raw-intent 显式形): the brief is the
    # SOLE anchor — archive resolution is skipped EVEN WHEN an (older,
    # unrelated) archive exists, so the pointer can never send the session off
    # to process a PREVIOUS requirement. Same display-layer segments as the
    # archive-less raw-intent form below (tips degrade soft; marker/appendix
    # are empty in this mode, keeping the shape minimal).
    if ($NoArchive) {
        $msg = "请处理以下新需求（尚无归档——归档由你创建，勿处理既有归档）：$($TaskBrief.Trim())"
        $msg += Get-TipsSegment -Entries (Get-RoleTips -TargetRole $Role) -TargetRole $Role
        $msg += Get-IntakeCallbackSegment
        $msg += Get-GoalTreeMarker
        $msg += Get-AppendixSegment
        return $msg
    }

    $taskJsonAbs = Resolve-TaskJsonAbsolute
    if (-not $taskJsonAbs) {
        # planner-pm-raw-intent: the PM 立项 entry has NO archive to anchor —
        # the archive is created BY PM. A self-sufficient -TaskBrief (the
        # user's raw requirement, passed verbatim by the planner) is a legal
        # pointer on its own (B2 semantics: role identity comes from the
        # preset / agent_mode binding, the message carries the one task).
        # Only a bare role call with neither anchor nor brief stays fail-loud.
        if ([string]::IsNullOrWhiteSpace($TaskBrief)) {
            Write-Err "应用层交接（Plus/dsh 后端）需要 task.json 来定位归档（或以 -TaskBrief 传递自足任务文本）。请用 -TaskJson 指定，或确保 .rdd/changes/archive/ 下有归档。"
        }
        $msg = "请处理以下任务：$($TaskBrief.Trim())"
        # same display-layer segments as the archive form (tips degrade soft;
        # marker/appendix are empty in this mode, keeping the shape minimal)
        $msg += Get-TipsSegment -Entries (Get-RoleTips -TargetRole $Role) -TargetRole $Role
        $msg += Get-GoalTreeMarker
        $msg += Get-AppendixSegment
        return $msg
    }
    $archiveRel = Resolve-ArchiveRelativePath -TaskJsonAbs $taskJsonAbs -RootPath $root
    if (-not $archiveRel) { Write-Err "无法从 task.json 路径推导归档相对路径: $taskJsonAbs" }

    $msg = "请处理 $archiveRel 下的需求。"
    if (-not [string]::IsNullOrWhiteSpace($Handoff)) {
        $handoffAbs = Resolve-AbsolutePath -Path $Handoff -Root $root
        if ($handoffAbs) {
            $handoffRel = Get-RelativePathFromRoot -AbsPath $handoffAbs -RootPath $root
            $msg += "（交接包: $handoffRel）"
        }
    }
    # targeted tips (tips-startup-injection): numbered summary (ordinal +
    # title per line, pointer mapping quarantined on the last line) between
    # the handoff pointer and the task brief; PLANNER branches above return
    # early un-injected — the planner is the callback target, not a tips
    # consumer
    $msg += Get-TipsSegment -Entries (Get-RoleTips -TargetRole $Role) -TargetRole $Role
    # task brief (dispatch-task-goal-anchoring): goal-first statement ahead of
    # the marker; PLANNER branches above return early unbriefed — the planner
    # is the callback target, not a bridge leaf
    $msg += Get-TaskBriefSegment
    # goal-tree marker (PLANNER branches above return early unmarked — the
    # planner is the callback target, not a bridge leaf)
    $msg += Get-GoalTreeMarker
    # appendix (inplace-redo-session-reuse): redo re-anchoring payload rides
    # only re-deliveries into existing sessions; empty → zero injection
    $msg += Get-AppendixSegment
    return $msg
}

function Invoke-PlusHandoff {
    param([string]$Message)
    # POST to Plus; returns $null on connection failure (caller falls back to CLI).
    if (-not $EmployeeId) {
        Write-Err "Plus 模式必须提供 -EmployeeId（目标角色对应的员工 UUID）。"
    }
    $uri = "$PlusUrl/api/rdd/handoff"
    $bodyObj = @{
        project_path = $root
        employee_id  = $EmployeeId
        message      = $Message
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Compress

    if ($DryRun) {
        Write-Host "[DRYRUN] Plus POST $uri" -ForegroundColor Yellow
        Write-Host "[DRYRUN] body: $bodyJson" -ForegroundColor Yellow
        return @{ conversation_id = "<dryrun>"; queued = $false; position = 1 }
    }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json; charset=utf-8" -Body $bodyJson -TimeoutSec 10
        return $resp
    } catch {
        $ex = $_.Exception
        # Distinguish "Plus reachable but rejected" (HTTP 4xx/5xx, has a Response)
        # from "Plus unreachable" (connection refused / timeout, no Response).
        $httpResponse = $null
        if ($ex -is [System.Net.WebException]) { $httpResponse = $ex.Response }
        elseif ($ex.PSObject.Properties['Response']) { $httpResponse = $ex.Response }
        if ($httpResponse) {
            $code = "?"
            try { $code = [int]$httpResponse.StatusCode } catch { }
            Write-Err "Plus handoff 失败 (HTTP $code): $($ex.Message)"
        }
        # No HTTP response → connection-level failure. Caller falls back to CLI.
        return $null
    }
}

function ConvertTo-DshRequestJson {
    # Serialize one client-request envelope for the dsh /api carrier.
    param([string]$Method, [hashtable]$Payload)
    $envelope = @{
        type    = "client-request"
        rpcId   = [guid]::NewGuid().ToString()
        method  = $Method
        payload = $Payload
    }
    return $envelope | ConvertTo-Json -Depth 8 -Compress
}

function Send-DshHttpPost {
    # Transport for one /api RPC: POST the envelope and return the response
    # body text. Both directions carry UTF-8 bytes explicitly — PS 5.1 sends
    # string bodies as Latin-1 (garbling the Chinese pointer message), and its
    # Invoke-RestMethod decodes a charset-less application/json response as
    # Latin-1 too (the server sends no charset), so raw HttpWebRequest handles
    # both here. Connection/carrier failures throw to the caller.
    param([string]$Uri, [string]$Json)
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = "POST"
    $req.ContentType = "application/json; charset=utf-8"
    $req.Timeout = 10000
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $req.ContentLength = $bodyBytes.Length
    $stream = $req.GetRequestStream()
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Close()
    $resp = $req.GetResponse()
    try {
        $rs = $resp.GetResponseStream()
        $ms = New-Object System.IO.MemoryStream
        $rs.CopyTo($ms)
        $rs.Close()
    } finally { $resp.Close() }
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}

function Get-DshFailureStatus {
    # Classify a transport exception into the unreachable result: keep the HTTP
    # status when the server answered (e.g. trust-fence 403), otherwise name the
    # transport status alongside the message. PS 5.1 reports a failed .NET call
    # as a MethodInvocationException wrapping the WebException, so .Status and
    # .Response are read from the inner chain — the caught exception itself
    # carries neither.
    param([System.Exception]$Exception)
    $webError = $Exception
    while ($webError -and -not ($webError -is [System.Net.WebException])) {
        $webError = $webError.InnerException
    }
    if (-not $webError) {
        return @{ status = "unreachable"; message = $Exception.Message; httpStatus = 0 }
    }
    $transportStatus = [string]$webError.Status
    $httpStatus = 0
    if ($webError.Response) {
        try { $httpStatus = [int]$webError.Response.StatusCode } catch { }
    }
    if ($httpStatus) {
        return @{ status = "unreachable"; message = $webError.Message; httpStatus = $httpStatus }
    }
    return @{ status = "unreachable"; message = "$($webError.Message) ($transportStatus)"; httpStatus = 0 }
}

function Invoke-DshApi {
    # One RPC over the dsh /api fetch carrier: a client-request envelope POSTed
    # to $DshUrl/api/<method>. Business errors arrive as HTTP 200 + ok:false;
    # connection/carrier failures throw in the transport. Returns one of:
    #   @{ status = "ok";         value = <business value> }
    #   @{ status = "business";   code; message; details }   server ok:false
    #   @{ status = "unreachable"; message; httpStatus }     not reachable / carrier refused
    param([string]$Method, [hashtable]$Payload)
    $json = ConvertTo-DshRequestJson -Method $Method -Payload $Payload
    try {
        $text = Send-DshHttpPost -Uri "$DshUrl/api/$Method" -Json $json
        $parsed = $text | ConvertFrom-Json
    } catch {
        return Get-DshFailureStatus -Exception $_.Exception
    }
    $result = $parsed.result
    if ($result.ok) { return @{ status = "ok"; value = $result.value } }
    return @{ status = "business"; code = [string]$result.error.code; message = [string]$result.error.message; details = $result.error.details }
}

function New-DshHandoffSession {
    # Workspace resolve-or-create + workspace-scoped session.create for the
    # dsh handoff: the workspace step is realpath-normalized and idempotent
    # (same step the GUI's New Session flow relies on), so the handoff
    # session lands in the project's workspace folder rather than Ungrouped.
    # session-list bundling: name the spawning session as the fresh session's
    # lineage parent ($env:DSH_SESSION_ID — the harness injects the calling
    # session's id into every tool process, so a planner dispatch records the
    # planner itself). The Web GUI bundles spawned rows under their planner;
    # CLI/Plus backends and bare terminals carry no id, so the key is omitted
    # (byte-identical legacy payload). Fail-soft on the host side: an unknown
    # parent simply renders the child as an ordinary top-level row.
    # Returns the LAST api status object (ok only when the session exists);
    # callers early-return on non-ok, success path exposes .value.sessionId.
    param([string]$Preset)
    $ws = Invoke-DshApi -Method "workspace.create" -Payload @{ path = $root }
    if ($ws.status -ne "ok") { return $ws }
    $createPayload = @{ workspaceId = [string]$ws.value.workspace.workspaceId; agentPreset = $Preset }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_SESSION_ID)) {
        $createPayload.parentSessionId = [string]$env:DSH_SESSION_ID
    }
    return Invoke-DshApi -Method "session.create" -Payload $createPayload
}

function Invoke-DshHandoff {
    # Four-shot dsh handoff over the /api carrier: preset pre-check,
    # workspace resolve-or-create, workspace-scoped session.create, then
    # queue-mode session.prompt with the B2 pointer message. The server still
    # mints a random sessionId (never hits the live-reuse or resume branches).
    # The workspace attach puts the new session inside its project folder in
    # the Web GUI sidebar — a cwd-only create joins no workspace account, so
    # it trails in the sidebar's Ungrouped section instead. An accepted prompt
    # wakes the driver so the target role runs its full turn without further
    # user action.
    param([string]$Message, [string]$Preset)

    $list = Invoke-DshApi -Method "agentPreset.list" -Payload @{}
    if ($list.status -ne "ok") { return $list }
    $availablePresets = @($list.value.presets | ForEach-Object { $_.id })
    if ($availablePresets -notcontains $Preset) {
        return @{ status = "preset-missing"; preset = $Preset; availablePresets = $availablePresets }
    }

    $create = New-DshHandoffSession -Preset $Preset
    if ($create.status -ne "ok") { return $create }
    $sessionId = [string]$create.value.sessionId

    # session-list-badges v2: pin the structural chips BEFORE the title
    # rename (design RPC matrix: create → setBadges → rename → prompt — badges
    # first so a badge failure can fold its structural facts into the one
    # rename that follows, never a second overwrite). Same display-only policy
    # as the title: any failure degrades with a warning and NEVER blocks the
    # handoff. Zero badges (plain handoff / preset-covered shapes) → zero
    # calls, byte-identical legacy behavior.
    $badges = @(Get-SessionBadges)
    $badgesResult = $null
    if ($badges.Count -gt 0) {
        $setBadges = Invoke-DshApi -Method "session.setBadges" -Payload @{ sessionId = $sessionId; badges = $badges }
        if ($setBadges.status -eq "ok") {
            $badgesResult = @{ pinned = $true; count = $badges.Count }
        }
        else {
            $reason = $setBadges.message
            if ($setBadges.status -eq "business") { $reason = "业务错误 $($setBadges.code): $($setBadges.message)" }
            $badgesResult = @{ pinned = $false; count = $badges.Count; error = $reason }
        }
    }

    # planner-session-roster: pin the structured title right after create and
    # BEFORE the pointer prompt — the user-source rename pins the title against
    # first-message auto-regeneration, so order matters (rename after the prompt
    # would race the driver's title generation). Display-only: any failure
    # degrades with a warning and NEVER blocks the handoff (the deliberate
    # opposite of the mission-param fail-loud policy — the title carries no
    # mission, see incident-2026-09-20-stray-dispatch). Plus backend has no dsh
    # session concept at all and never reaches this function.
    # session-list-badges v2: the summary-replaces-marker verdict no longer
    # depends on the badge pin — the role identity pill is guaranteed by the
    # agent preset bound at session.create (enum-only text, renderer-derived),
    # so the title budget stays free for the requirement line even when
    # setBadges fails or writes nothing.
    $title = Get-PinnedTitle -LegacyTitle (Get-SessionTitle) -BadgesPinned $true -Summary $TaskSummary
    $titleResult = $null
    if (-not [string]::IsNullOrWhiteSpace($title)) {
        $rename = Invoke-DshApi -Method "session.rename" -Payload @{ sessionId = $sessionId; title = $title }
        if ($rename.status -eq "ok") {
            $titleResult = @{ pinned = $true; title = [string]$rename.value.title }
        }
        else {
            $reason = $rename.message
            if ($rename.status -eq "business") { $reason = "业务错误 $($rename.code): $($rename.message)" }
            $titleResult = @{ pinned = $false; title = $title; error = $reason }
        }
    }

    $prompt = Invoke-DshApi -Method "session.prompt" -Payload @{
        sessionId = $sessionId
        mode      = "queue"
        content   = @(@{ type = "text"; text = $Message })
    }
    if ($prompt.status -ne "ok") {
        return @{ status = "prompt-failed"; sessionId = $sessionId; title = $titleResult; badges = $badgesResult; failure = $prompt }
    }
    return @{ status = "done"; sessionId = $sessionId; title = $titleResult; badges = $badgesResult }
}

function Start-WithWindowsTerminal {
    param([string]$Root, [string]$Message, [string]$Opencode)
    $wtArgs = "-d `"$Root`" $Opencode --prompt `"$Message`""
    Start-Process wt -ArgumentList $wtArgs
}

function Start-WithPowerShell {
    param([string]$Root, [string]$Message, [string]$Opencode)
    Start-Process -FilePath $Opencode -ArgumentList @("--prompt", $Message) -WorkingDirectory $Root
}

function Test-PlannerTakeoverBlocked {
    # PLANNER uniqueness guard, takeover shape (-Role PLANNER, no -RunId):
    # probe the target archive for an active delivery run and print the
    # verdict. Returns $true ONLY after the PLANNER_RUN_ACTIVE reject banner
    # was printed (the caller then exits 1); every pass-through path (-Force
    # override, no task.json, probe self-failure → fail-open warn, no active
    # run) returns $false with output/exit behavior byte-for-byte identical
    # to the former inline guard (regression anchor).
    if ($Force) { return $false }
    $taskJsonProbe = Resolve-TaskJsonAbsolute
    if ([string]::IsNullOrWhiteSpace($taskJsonProbe)) { return $false }
    $probe = Test-ActiveDeliveryRun -TaskJsonAbs $taskJsonProbe
    if ($null -eq $probe) {
        Write-Host "[!] 活跃交付 run 探测失败，fail-open 放行（命令级 RUN_EXISTS / LEASE_HELD 防线仍然生效）" -ForegroundColor Yellow
        return $false
    }
    if (-not $probe.active) { return $false }
    Write-Host "[x] PLANNER_RUN_ACTIVE: 该归档已有活跃的规划者交付 run，拒绝重复启动 PLANNER（唯一有效规划者约束）。" -ForegroundColor Red
    Write-Host "    run:   $($probe.runId)（state=$($probe.state)；节点 done $($probe.done)/$($probe.total)，claimed $($probe.claimed)，reported $($probe.reported)，pending $($probe.pending)）" -ForegroundColor Cyan
    Write-Host "    goal:  $($probe.goal)" -ForegroundColor Cyan
    Write-Host "[i] 续跑合法入口: start-role.cmd -Role PLANNER -RunId $($probe.runId)" -ForegroundColor Cyan
    Write-Host "[i] 查看进度: delivery-bridge.cmd -Command status -RunId $($probe.runId)；确认原规划者会话已死后经 lease -RunId $($probe.runId) -Takeover 留痕接管（他人持新鲜租约时报 LEASE_HELD）" -ForegroundColor Cyan
    Write-Host "[!] 用户显式裁决通道: 追加 -Force 强制启动——仅跳过本校验创建会话，编排权与回调投递仍受租约（LEASE_HELD / lease -Takeover）约束" -ForegroundColor Yellow
    return $true
}

$root = Resolve-ProjectRoot
$mode = Resolve-RuntimeMode

# --- session-reuse backend gate (inplace-redo-session-reuse) -------------------
# -ExistingSessionId names a dsh session to re-enter: only the dsh backend can
# deliver by id (a CLI terminal window cannot be re-entered; Plus conversations
# are addressed by employee, not session). Deterministic reject instead of a
# silent new session — the caller (bridge in-place path) must decide the
# fallback itself, a fresh session here would silently defeat the reuse intent.
if (-not [string]::IsNullOrWhiteSpace($ExistingSessionId) -and $mode -ne "dsh") {
    Write-Err "SESSION_REUSE_UNSUPPORTED: -ExistingSessionId 只在 dsh 后端可用（当前后端 $mode 无法按 id 重入既有会话）。调用方应回落新建会话路径（reclaim 回落 / -NoReuse）。"
}

# --- TaskBriefFile resolution (dispatch-brief-file) ---------------------------
# One resolution point before any backend dispatch (message builders stay pure
# functions of $TaskBrief): the file content becomes $TaskBrief verbatim, so
# every downstream consumer (GoalTreeWorker pointer, archive brief segment)
# keeps a single source. Loud failure on missing/empty files — never proceed
# with a half-delivered task statement.
if (-not [string]::IsNullOrWhiteSpace($TaskBriefFile)) {
    if (-not (Test-Path -LiteralPath $TaskBriefFile -PathType Leaf)) {
        Write-Err "-TaskBriefFile not found: $TaskBriefFile"
    }
    $TaskBrief = [System.IO.File]::ReadAllText($TaskBriefFile, [System.Text.Encoding]::UTF8).TrimEnd()
    if ([string]::IsNullOrWhiteSpace($TaskBrief)) {
        Write-Err "-TaskBriefFile resolved to an empty brief: $TaskBriefFile"
    }
}

# --- NoArchive 守卫（planner-pm-raw-intent 显式形）-----------------------------
# 在任何后端派发前校验互斥与自足性（消息构建器保持纯函数）。brief 已在此前完成
# 文件解析，故此处的 $TaskBrief 就是最终文本。
if ($NoArchive) {
    if ($Role -eq "PLANNER") { Write-Err "-NoArchive 不适用于 PLANNER（规划者接管/续跑用 -TaskJson / -RunId）。" }
    if ($TaskId -ge 1) { Write-Err "-NoArchive 与 -TaskId 互斥（任务号属于既有归档）。" }
    if (-not [string]::IsNullOrWhiteSpace($TaskJson)) { Write-Err "-NoArchive 与 -TaskJson 互斥（新需求尚无归档可锚）。" }
    if ($GoalTreeWorker) { Write-Err "-NoArchive 与 -GoalTreeWorker 互斥（通用树 worker 自带节点锚）。" }
    if ([string]::IsNullOrWhiteSpace($TaskBrief)) { Write-Err "-NoArchive 需要 -TaskBrief / -TaskBriefFile 提供自足任务文本（brief 是唯一锚）。" }
}

# --- PLANNER uniqueness guard (planner-uniqueness-callback) ------------------
# start-role is the single handoff entry shared by all three backends, so the
# gate sits BEFORE any backend dispatch (message builders stay pure functions).
# Two shapes:
#   * takeover shape (-Role PLANNER, no -RunId): probe the target archive for
#     an active delivery run via the public goal-tree status CLI. Active →
#     reject with PLANNER_RUN_ACTIVE + run facts + the -RunId resume guidance
#     (which chains into LEASE_HELD / lease -Takeover). A probe self-failure
#     fails OPEN (proceed + warn) — the command-level RUN_EXISTS/LEASE_HELD
#     guards remain the hard backstop. No active run → output and behavior are
#     identical to before (regression anchor; only one extra read-only child
#     process). -Force skips ONLY this gate (explicit user override).
#   * resume shape (-Role PLANNER -RunId <id>): the legal re-entry, never
#     blocked; prints an advisory line naming the current lease holder.
if ($Role -eq "PLANNER") {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        if (Test-PlannerTakeoverBlocked) { exit 1 }
    }
    else {
        $leaseHolder = Get-PlannerLeaseHolder -Root $root -RunId $RunId
        $holderText = if ($leaseHolder) { "当前租约持有者: $leaseHolder" } else { "当前无租约持有者记录（可能已过期或从未获取）" }
        Write-Host "[i] PLANNER 续跑模式（run $RunId）为合法入口，不拦截；$holderText。若原规划者会话仍存活请勿并发操作——接管经 delivery-bridge.cmd -Command lease -RunId $RunId -Takeover 留痕。" -ForegroundColor Cyan
    }
}

# --- Plus backend -----------------------------------------------------------
# When running inside the app (RDD_RUNTIME=app), drive the target role's
# conversation via Plus's handoff endpoint instead of spawning an external
# terminal window. On connection failure, fall back to the CLI backend so the
# user is never blocked (the env marker can leak into a standalone shell).
if ($mode -eq "app") {
    $plusMessage = Build-PointerMessage
    Write-Step "检测到 Plus 运行时，向应用层交接角色 $Role ..."
    $result = Invoke-PlusHandoff -Message $plusMessage
    if ($result) {
        $conv = $result.conversation_id
        $queued = [bool]$result.queued
        if ($queued) {
            Write-Ok "已加入队列（位置 $($result.position)），将在当前会话结束后启动 $Role"
        } else {
            Write-Ok "已在 Plus 内为 $Role 开启对话 ($conv)"
        }
        Write-Host "[i] 指针消息: $plusMessage" -ForegroundColor Cyan
        Write-Host "[i] 请在应用层切换到该员工查看对话" -ForegroundColor Cyan
        exit 0
    }
    Write-Host "[!] Plus 后端不可达（$PlusUrl），降级为 CLI 开窗" -ForegroundColor Yellow
}

# --- dsh backend ------------------------------------------------------------
# Inside a dsh Web GUI session (DSH_WEB_URL injected by the harness into shell
# subprocesses), drive the target role through the GUI's own /api carrier:
# resolve-or-create the project workspace, create a session bound to the
# rdd-<role> preset inside it (the GUI's own New Session path), then send the
# B2 pointer message. No external window opens; the new session appears inside
# the project's workspace folder in the Web GUI sidebar. Failures never fall
# back to the CLI backend — a local terminal window is useless to a Web GUI
# user: unreachable → error + manual guidance, business error → error code,
# prompt-failed → pointer message for manual paste into the already-created
# session.
if ($mode -eq "dsh") {
    if ([string]::IsNullOrWhiteSpace($DshUrl)) { $DshUrl = $env:DSH_WEB_URL }
    if ([string]::IsNullOrWhiteSpace($DshUrl)) {
        Write-Err "dsh 模式需要 Web GUI 服务地址：设置 DSH_WEB_URL 环境变量或传 -DshUrl。"
    }
    $DshUrl = $DshUrl.TrimEnd('/')
    if (-not [string]::IsNullOrWhiteSpace($EmployeeId)) {
        Write-Host "[i] -EmployeeId 属 Plus 语义，dsh 后端不适用，已忽略。" -ForegroundColor Yellow
    }

    $pointerMessage = Build-PointerMessage
    $preset = "rdd-" + $Role.ToLower()

    # --- reuse carrier (inplace-redo-session-reuse) ---------------------------
    # Re-delivery into an EXISTING session: no preset pre-check, no workspace,
    # no session.create, no badges/rename (the session already carries its
    # identity/title) — one queue-mode session.prompt with the pointer message
    # (+ the redo appendix when present). Failures never fall back to creating
    # a fresh session: the bridge classifies (pointer class) and decides; the
    # pointer message stays visible for a manual paste into the same session.
    if (-not [string]::IsNullOrWhiteSpace($ExistingSessionId)) {
        if ($DryRun) {
            Write-Host "[DRYRUN] 模式:    dsh backend reuse ($DshUrl)" -ForegroundColor Yellow
            Write-Host "[DRYRUN] 项目根:  $root" -ForegroundColor Yellow
            Write-Host "[DRYRUN] 复用会话: $ExistingSessionId（跳过 preset/workspace/session.create/setBadges/rename 四步）" -ForegroundColor Yellow
            Write-Host "[DRYRUN] RPC 1:   POST $DshUrl/api/session.prompt" -ForegroundColor Yellow
            Write-Host "[DRYRUN] payload: sessionId=$ExistingSessionId mode=queue text=$pointerMessage" -ForegroundColor Yellow
            exit 0
        }
        Write-Step "检测到 dsh 运行时（$DshUrl），向角色 $Role 的既有会话投递指针（复用会话 $ExistingSessionId）..."
        $prompt = Invoke-DshApi -Method "session.prompt" -Payload @{
            sessionId = $ExistingSessionId
            mode      = "queue"
            content   = @(@{ type = "text"; text = $pointerMessage })
        }
        if ($prompt.status -ne "ok") {
            if ($prompt.status -eq "business") {
                $detailsText = ""
                try { $detailsText = " details: $($prompt.details | ConvertTo-Json -Depth 6 -Compress)" } catch { }
                Write-Host "[x] 既有会话指针投递失败（业务错误 $($prompt.code)）: $($prompt.message)$detailsText" -ForegroundColor Red
            }
            else {
                Write-Host "[x] dsh 服务不可达（$DshUrl）: $($prompt.message)" -ForegroundColor Red
            }
            Write-Host "[!] 会话 $ExistingSessionId 未收到指针；可在该会话内手动粘贴发送下面的指针消息（或由规划者 dispatch -NoReuse 重建新会话）：" -ForegroundColor Yellow
            Write-Host "[i] 指针消息: $pointerMessage" -ForegroundColor Cyan
            exit 1
        }
        Write-Ok "已向角色 $Role 的既有会话投递指针（复用会话 sessionId: $ExistingSessionId）"
        Write-Host "[i] 指针消息: $pointerMessage" -ForegroundColor Cyan
        Write-Host "[i] 目标会话保留原上下文，目标角色已在原会话内继续工作，可点开查看进度" -ForegroundColor Cyan
        exit 0
    }

    if ($DryRun) {
        Write-Host "[DRYRUN] 模式:    dsh backend ($DshUrl)" -ForegroundColor Yellow
        Write-Host "[DRYRUN] 项目根:  $root" -ForegroundColor Yellow
        Write-Host "[DRYRUN] preset:  $preset（经 agentPreset.list 预检存在性）" -ForegroundColor Yellow
        Write-Host "[DRYRUN] RPC 1:   POST $DshUrl/api/workspace.create" -ForegroundColor Yellow
        Write-Host "[DRYRUN] payload: path=$root（resolve-or-create，realpath 规范化）" -ForegroundColor Yellow
        Write-Host "[DRYRUN] RPC 2:   POST $DshUrl/api/session.create" -ForegroundColor Yellow
        # session-list bundling: parentSessionId rides along only when the
        # harness injected the caller's session id (planner-context dispatch).
        $dryParent = if ([string]::IsNullOrWhiteSpace($env:DSH_SESSION_ID)) { "" } else { " parentSessionId=$env:DSH_SESSION_ID（血统打包：侧栏并入发起会话）" }
        Write-Host "[DRYRUN] payload: workspaceId=<RPC 1 返回> agentPreset=$preset（入账 workspace，侧栏进项目文件夹）$dryParent" -ForegroundColor Yellow
        # planner-session-roster + session-list-badges: the setBadges/rename
        # RPCs print ONLY when they apply — an unmarked plain handoff keeps the
        # exact legacy DryRun lines (byte-for-byte regression anchor).
        $dryBadges = @(Get-SessionBadges)
        $rpcNo = 3
        if ($dryBadges.Count -gt 0) {
            $dryBadgesJson = $dryBadges | ConvertTo-Json -Compress
            if ($dryBadges.Count -eq 1) { $dryBadgesJson = "[{0}]" -f ($dryBadges | ConvertTo-Json -Compress) }
            Write-Host "[DRYRUN] RPC 3:   POST $DshUrl/api/session.setBadges" -ForegroundColor Yellow
            Write-Host "[DRYRUN] payload: sessionId=<RPC 2 返回> badges=$dryBadgesJson（rdd:* 结构芯片：值链/▶ 直交标记；角色胶囊由 preset 派生，不经此 RPC）" -ForegroundColor Yellow
            $rpcNo = 4
        }
        $dryTitle = Get-PinnedTitle -LegacyTitle (Get-SessionTitle) -BadgesPinned $true -Summary $TaskSummary
        if ($dryTitle) {
            Write-Host "[DRYRUN] RPC $rpcNo`:   POST $DshUrl/api/session.rename" -ForegroundColor Yellow
            Write-Host "[DRYRUN] payload: sessionId=<RPC 2 返回> title=$dryTitle（user 源钉住标题；失败降级警告不阻断）" -ForegroundColor Yellow
            $rpcNo++
        }
        Write-Host "[DRYRUN] RPC $rpcNo`:   POST $DshUrl/api/session.prompt" -ForegroundColor Yellow
        Write-Host "[DRYRUN] payload: sessionId=<RPC 2 返回> mode=queue text=$pointerMessage" -ForegroundColor Yellow
        exit 0
    }

    Write-Step "检测到 dsh 运行时（$DshUrl），为角色 $Role 自动创建会话 ..."
    $result = Invoke-DshHandoff -Message $pointerMessage -Preset $preset
    switch ($result.status) {
        "done" {
            Write-Ok "已在 dsh 内为 $Role 创建会话（preset: $preset, sessionId: $($result.sessionId)）"
            if ($result.badges) {
                if ($result.badges.pinned) {
                    Write-Host "[i] 会话结构芯片已钉住（值链/▶ 直交标记；角色胶囊由 preset 派生）: $($result.badges.count) 枚" -ForegroundColor Cyan
                }
                else {
                    Write-Host "[!] 会话结构芯片钉住失败（$($result.badges.error)），角色胶囊与标题不受影响，会话照常创建与派发" -ForegroundColor Yellow
                }
            }
            if ($result.title) {
                if ($result.title.pinned) {
                    Write-Host "[i] 会话标题已钉住（user 源，不再随首消息重生成）: $($result.title.title)" -ForegroundColor Cyan
                }
                else {
                    Write-Host "[!] 会话标题钉住失败（$($result.title.error)），已降级跳过——会话照常创建与派发" -ForegroundColor Yellow
                }
            }
            Write-Host "[i] 指针消息: $pointerMessage" -ForegroundColor Cyan
            Write-Host "[i] 新会话已出现在 Web GUI 侧栏，目标角色已自动开工，可点开查看进度" -ForegroundColor Cyan
            exit 0
        }
        "preset-missing" {
            $availableText = ($result.availablePresets) -join ", "
            Write-Err "目标角色 preset 不存在: $($result.preset)。可用 preset: $availableText"
        }
        "business" {
            $detailsText = ""
            try { $detailsText = " details: $($result.details | ConvertTo-Json -Depth 6 -Compress)" } catch { }
            Write-Err "dsh 交接失败（业务错误 $($result.code)）: $($result.message)$detailsText"
        }
        "prompt-failed" {
            $failure = $result.failure
            if ($failure.status -eq "business") {
                $reason = "业务错误 $($failure.code): $($failure.message)"
            } else {
                $reason = $failure.message
            }
            Write-Host "[x] 会话已创建（$($result.sessionId)）但指针消息发送失败: $reason" -ForegroundColor Red
            if ($result.title -and -not $result.title.pinned) {
                Write-Host "[!] 会话标题钉住亦失败（$($result.title.error)），已降级跳过" -ForegroundColor Yellow
            }
            Write-Host "[!] 可在 Web GUI 侧栏点开该会话，手动粘贴发送下面的指针消息：" -ForegroundColor Yellow
            Write-Host "[i] 指针消息: $pointerMessage" -ForegroundColor Cyan
            exit 1
        }
        "unreachable" {
            Write-Host "[x] dsh 服务不可达（$DshUrl）: $($result.message)" -ForegroundColor Red
            if ($result.httpStatus -eq 403) {
                Write-Host "[i] HTTP 403：Host 不在信任栅栏内。DSH_WEB_URL 指向非 loopback 地址时，需在 dsh 启动时以 --trusted-host 声明该地址。" -ForegroundColor Cyan
            }
            Write-Host "[!] 人工回退：在 Web GUI 侧栏新建会话并选择 preset $preset，粘贴发送下面的指针消息：" -ForegroundColor Yellow
            Write-Host "[i] 指针消息: $pointerMessage" -ForegroundColor Cyan
            exit 1
        }
        default {
            Write-Err "dsh 交接返回未知结果: $($result.status)"
        }
    }
}

# --- CLI backend (default / Plus fallback) ----------------------------------
$opencode = Find-OpencodeExecutable
if (-not $opencode) { Write-Err "未找到 opencode（.cmd/.exe/.bat），请先安装 (npm install -g opencode-ai)" }

$message = Build-PromptMessage
$useWt = Test-WindowsTerminal

if ($DryRun) {
    Write-Host "[DRYRUN] 模式:      $mode (cli backend)" -ForegroundColor Yellow
    Write-Host "[DRYRUN] 项目根:    $root" -ForegroundColor Yellow
    Write-Host "[DRYRUN] opencode:  $opencode" -ForegroundColor Yellow
    Write-Host "[DRYRUN] 预填消息:  $message" -ForegroundColor Yellow
    if ($useWt) {
        Write-Host "[DRYRUN] 终端:     Windows Terminal (wt.exe)" -ForegroundColor Yellow
    } else {
        Write-Host "[DRYRUN] 终端:     PowerShell 窗口 (wt.exe 不可用，降级)" -ForegroundColor Yellow
    }
    exit 0
}

Write-Step "为角色 $Role 开新窗口 ..."
if ($useWt) {
    Start-WithWindowsTerminal -Root $root -Message $message -Opencode $opencode
    Write-Ok "已开启 Windows Terminal 窗口"
} else {
    Start-WithPowerShell -Root $root -Message $message -Opencode $opencode
    Write-Ok "已开启 PowerShell 窗口"
}

Write-Host "[i] 预填消息: $message" -ForegroundColor Cyan
Write-Host "[i] 在新窗口按回车发送即可进入 $Role 角色" -ForegroundColor Cyan
