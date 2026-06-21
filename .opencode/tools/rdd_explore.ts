import { tool, type ToolContext, type ToolResult } from "@opencode-ai/plugin"

const SCRIPT_REL = ".rdd/skills/rdd-engine/scripts/explore.ps1"

type ExploreData = {
  cache?: "hit" | "miss"
  action?: string
  subagentHint?: string
  query?: string
  matchScore?: number
  key?: string
  path?: string
  brief?: string
  files?: Record<string, string>
  artifact?: string
  prompt?: string
  registered?: boolean
  filesCount?: number
}

type ExploreResponse = {
  success: boolean
  data?: ExploreData
  error?: { code: string; message: string }
}

async function runExploreScript(
  type: "explore" | "register",
  params: string[],
  context: ToolContext,
): Promise<ExploreResponse> {
  const scriptPath = `${context.worktree}/${SCRIPT_REL}`
  const binary = process.platform === "win32" ? "powershell.exe" : "pwsh"
  const cmd = [
    binary,
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    scriptPath,
    "-Type",
    type,
    ...params,
  ]

  let stdout: string
  let stderr: string
  let exitCode: number
  try {
    const proc = Bun.spawn({ cmd, cwd: context.worktree, stdout: "pipe", stderr: "pipe" })
    stdout = await new Response(proc.stdout).text()
    stderr = await new Response(proc.stderr).text()
    exitCode = await proc.exited
  } catch (err) {
    const hint =
      process.platform === "win32"
        ? "powershell.exe not found"
        : "pwsh not installed — install PowerShell 7+ (e.g. `brew install pwsh`)"
    throw new Error(`Failed to launch explore script: ${hint}. ${(err as Error).message}`)
  }

  let parsed: ExploreResponse | null = null
  try {
    parsed = JSON.parse(stdout) as ExploreResponse
  } catch {
    const detail = (stderr || stdout).trim()
    throw new Error(`explore.ps1 produced unparseable output (exit=${exitCode}): ${detail.slice(0, 500)}`)
  }

  if (!parsed.success) {
    const msg = parsed.error?.message ?? "unknown error"
    const code = parsed.error?.code ?? "UNKNOWN"
    throw new Error(`explore.ps1 [${code}]: ${msg}`)
  }

  return parsed
}

export default tool({
  description:
    "查询 rdd-engine 代码探索缓存。命中时直接返回探索 artifact 全文（零 LLM 成本）；" +
    "未命中时返回内嵌协议的 dispatch prompt，需自行探索代码、写 artifact、" +
    "再调用 rdd_explore_register 注册。适合『主题级』代码理解（如『认证流程怎么走』" +
    "『状态机如何流转』），不适合单符号快速定位（用内置 explore subagent）。" +
    "跨会话共享：PM 探索过的结果 CTO/DEV/QA/UX 可直接命中。",
  args: {
    query: tool.schema
      .string()
      .describe("自然语言探索主题，中文可用。如『订单状态机的状态流转逻辑』"),
  },
  async execute(args, context): Promise<ToolResult> {
    const res = await runExploreScript("explore", ["-Query", args.query], context)
    const data = res.data!

    if (data.cache === "hit") {
      return {
        title: `Cache HIT (score=${data.matchScore?.toFixed(2) ?? "?"}) — ${data.path}`,
        output: `${data.path}\n\n${data.artifact ?? ""}`,
        metadata: {
          cache: "hit",
          key: data.key,
          path: data.path,
          brief: data.brief,
          matchScore: data.matchScore,
        },
      }
    }

    return {
      title: `Cache MISS (score=${data.matchScore?.toFixed(2) ?? "0"}) — 探索后用 rdd_explore_register 注册`,
      output:
        `探索缓存未命中。请按下方 dispatch prompt 探索代码、写 artifact、注册。\n\n${data.prompt ?? ""}`,
      metadata: {
        cache: "miss",
        query: args.query,
        subagentHint: data.subagentHint,
      },
    }
  },
})

export const register = tool({
  description:
    "向 rdd-engine 探索缓存注册一份 artifact。在 rdd_explore 返回 miss 后、" +
    "你完成代码探索并写出 artifact 文件后调用。注册时需传入实际分析过的文件列表，" +
    "这些文件的 SHA-256 会被记录，日后任一变更会自动触发缓存失效。",
  args: {
    key: tool.schema.string().describe("语义 key，中文可用，与探索 Query 主题对应"),
    path: tool.schema
      .string()
      .describe("artifact 文件路径，repo-relative，如 .rdd/exploration/artifacts/auth.md"),
    brief: tool.schema.string().describe("一句话摘要，命中后供调用方快速核对"),
    files: tool.schema
      .array(tool.schema.string())
      .describe("实际读过并分析过的文件路径列表，repo-relative"),
  },
  async execute(args, context): Promise<ToolResult> {
    const filesStr = args.files.join(",")
    const res = await runExploreScript(
      "register",
      ["-Key", args.key, "-Path", args.path, "-Brief", args.brief, "-Files", filesStr],
      context,
    )
    const data = res.data!

    return {
      title: `Registered: ${data.key}`,
      output: `已注册到缓存。key=${data.key} path=${data.path} files=${data.filesCount}`,
      metadata: {
        cache: "registered",
        key: data.key,
        path: data.path,
        filesCount: data.filesCount,
      },
    }
  },
})
