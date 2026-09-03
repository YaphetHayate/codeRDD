import * as path from 'path';

/** codeRDD 仓库根（dist/core/config.js -> ../../），rdd-* 源资产与薄文件都在这里 */
export const SOURCE_ROOT = path.resolve(__dirname, '..', '..');

export const VERSION = require(path.join(SOURCE_ROOT, 'package.json')).version;

/** 可安装的角色，engine 为必装核心 */
export const ROLES = ['engine', 'pm', 'cto', 'ux', 'dev', 'qa', 'eval', 'pse'] as const;
export type Role = (typeof ROLES)[number];

export const MANDATORY_ROLES: Role[] = ['engine'];

export interface AiTool {
  id: string;
  label: string;
  /** 用于 init 时检测目标项目里已有哪些客户端（存在即预选） */
  detectionPaths: string[];
}

export const AI_TOOLS: AiTool[] = [
  { id: 'opencode', label: 'OpenCode', detectionPaths: ['.opencode', 'opencode.json'] },
  { id: 'claude', label: 'Claude Code', detectionPaths: ['.claude', 'CLAUDE.md'] },
  // ZCode 的 skill 发现走共享的 .agents/skills（选 opencode 即可覆盖），
  // 这里只为安装用户级 rdd-explore 子代理
  { id: 'zcode', label: 'ZCode', detectionPaths: ['.zcode'] },
];

export const EXCLUDED_COPY_ENTRIES = new Set(['.git', '.idea', '.claude', 'node_modules']);

/** 源仓库中各角色的 skill 目录 */
export function roleSourceDir(role: string): string {
  return path.join(SOURCE_ROOT, `rdd-${role}`);
}

/**
 * 宿主专属薄文件：src 相对 SOURCE_ROOT；dest 默认相对 target 根，
 * userScope 为 true 时 dest 相对用户主目录（ZCode 仅支持用户级子代理）。
 */
export const THIN_FILES: Record<string, Array<{ src: string; dest: string; userScope?: boolean }>> = {
  opencode: [
    { src: path.join('.opencode', 'agent', 'rdd-explore.md'), dest: path.join('.opencode', 'agent', 'rdd-explore.md') },
  ],
  claude: [
    { src: path.join('.claude', 'agents', 'rdd-explore.md'), dest: path.join('.claude', 'agents', 'rdd-explore.md') },
  ],
  zcode: [
    { src: path.join('.zcode', 'agents', 'rdd-explore.md'), dest: path.join('.zcode', 'agents', 'rdd-explore.md') },
  ],
};

/**
 * 各客户端放置 skill 链接的目录（相对 target 根）。
 * OpenCode/Codex/Warp 等均支持中立共享路径 .agents/skills/，
 * Claude Code 不读 .agents/，单独链到 .claude/skills/。
 */
export const SKILLS_LINK_DIR: Record<string, string> = {
  opencode: path.join('.agents', 'skills'),
  claude: path.join('.claude', 'skills'),
};

export const MANIFEST_PATH = path.join('.rdd', 'install.json');
export const BACKUP_DIR = path.join('.rdd', 'install-backup');
export const RDD_SKILLS_DIR = path.join('.rdd', 'skills');

export interface Manifest {
  version: string;
  sourceRoot: string;
  sourceCommit: string;
  installedAt: string;
  updatedAt?: string;
  tools: string[];
  roles: string[];
  /** 相对 target 根 */
  links: string[];
  /** 相对 target 根 */
  files: string[];
  /** 被合并过的配置文件（相对 target 根），uninstall 时从备份还原 */
  merged: string[];
}
