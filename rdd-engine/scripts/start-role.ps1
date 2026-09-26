[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("PM", "CTO", "UX", "DEV", "QA", "EVAL", "PSE", "PLANNER")]
    [string]$Role,

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

    # PLANNER uniqueness guard (planner-uniqueness-callback): explicit user
    # override that skips ONLY the startup gate below — the session gets
    # created, but the orchestration right and callback re-pointing still
    # require the command-level lease (LEASE_HELD / lease -Takeover). Absent →
    # an active delivery run rejects the startup with PLANNER_RUN_ACTIVE.
    [switch]$Force,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Step { param([string]$Message); Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message); Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Err  { param([string]$Message); Write-Host "[x] $Message" -ForegroundColor Red; exit 1 }

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
        return "你是 RDD PLANNER（规划者）。先读 rdd-engine/references/planner-guide.md，然后用 delivery-bridge promulgate -TaskJson $taskJsonAbs 接管该归档的整批交付。"
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

    return "$base$(Get-GoalTreeMarker)"
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
        return "请以规划者（PLANNER）身份接管 ${archiveRel}的整批交付：先读 rdd-engine/references/planner-guide.md，随后执行 delivery-bridge -Command promulgate -TaskJson $taskJsonAbs 颁布交付节点并按需调动角色会话。"
    }

    $taskJsonAbs = Resolve-TaskJsonAbsolute
    if (-not $taskJsonAbs) {
        Write-Err "应用层交接（Plus/dsh 后端）需要 task.json 来定位归档。请用 -TaskJson 指定，或确保 .rdd/changes/archive/ 下有归档。"
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
    # task brief (dispatch-task-goal-anchoring): goal-first statement ahead of
    # the marker; PLANNER branches above return early unbriefed — the planner
    # is the callback target, not a bridge leaf
    $msg += Get-TaskBriefSegment
    # goal-tree marker (PLANNER branches above return early unmarked — the
    # planner is the callback target, not a bridge leaf)
    $msg += Get-GoalTreeMarker
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

    # Resolve-or-create (realpath-normalized, idempotent): same step the GUI's
    # New Session flow relies on, so the handoff session lands in the project's
    # workspace folder rather than Ungrouped.
    $ws = Invoke-DshApi -Method "workspace.create" -Payload @{ path = $root }
    if ($ws.status -ne "ok") { return $ws }
    $workspaceId = [string]$ws.value.workspace.workspaceId

    $create = Invoke-DshApi -Method "session.create" -Payload @{ workspaceId = $workspaceId; agentPreset = $Preset }
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

    if ($DryRun) {
        Write-Host "[DRYRUN] 模式:    dsh backend ($DshUrl)" -ForegroundColor Yellow
        Write-Host "[DRYRUN] 项目根:  $root" -ForegroundColor Yellow
        Write-Host "[DRYRUN] preset:  $preset（经 agentPreset.list 预检存在性）" -ForegroundColor Yellow
        Write-Host "[DRYRUN] RPC 1:   POST $DshUrl/api/workspace.create" -ForegroundColor Yellow
        Write-Host "[DRYRUN] payload: path=$root（resolve-or-create，realpath 规范化）" -ForegroundColor Yellow
        Write-Host "[DRYRUN] RPC 2:   POST $DshUrl/api/session.create" -ForegroundColor Yellow
        Write-Host "[DRYRUN] payload: workspaceId=<RPC 1 返回> agentPreset=$preset（入账 workspace，侧栏进项目文件夹）" -ForegroundColor Yellow
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
