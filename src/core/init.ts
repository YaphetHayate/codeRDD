import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { checkbox } from '@inquirer/prompts';
import {
  AI_TOOLS,
  ROLES,
  Role,
  MANIFEST_PATH,
  BACKUP_DIR,
  RDD_SKILLS_DIR,
  SKILLS_LINK_DIR,
  THIN_FILES,
  SOURCE_ROOT,
  VERSION,
  Manifest,
  roleSourceDir,
} from './config';
import { copyDirEx, copyFileEx, exists, gitHead, isLink, linkDir, readJson, writeJson } from './fs-utils';

export interface InitOptions {
  target: string;
  tools?: string;
  roles?: string;
  force: boolean;
  yes: boolean;
}

function parseList(v: string | undefined): string[] {
  if (!v) return [];
  return v
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

function detectTools(target: string): string[] {
  return AI_TOOLS.filter((t) => t.detectionPaths.some((p) => exists(path.join(target, p)))).map((t) => t.id);
}

async function promptTools(target: string): Promise<string[]> {
  const detected = new Set(detectTools(target));
  return checkbox({
    message: '选择要适配的 AI 客户端（已检测到的已预选）:',
    choices: AI_TOOLS.map((t) => ({
      name: t.label + (detected.has(t.id) ? '（已检测到）' : ''),
      value: t.id,
      checked: detected.has(t.id) || detected.size === 0,
    })),
  });
}

async function promptRoles(): Promise<string[]> {
  return checkbox({
    message: '选择要安装的角色（rdd-engine 为必装核心）:',
    choices: ROLES.map((r) => ({ name: r, value: r, checked: true })),
  });
}

export async function runInit(opts: InitOptions): Promise<void> {
  const target = path.resolve(opts.target);
  if (!exists(target)) {
    throw new Error(`目标目录不存在: ${target}`);
  }

  // 1. 确定客户端与角色
  let tools = parseList(opts.tools);
  if (tools.length === 0) {
    if (opts.yes || !process.stdin.isTTY) {
      tools = ['opencode'];
    } else {
      tools = await promptTools(target);
    }
  }
  const invalidTools = tools.filter((t) => !AI_TOOLS.some((a) => a.id === t));
  if (invalidTools.length > 0) throw new Error(`未知的客户端: ${invalidTools.join(', ')}（可选: ${AI_TOOLS.map((t) => t.id).join(', ')}）`);
  if (tools.length === 0) throw new Error('未选择任何客户端，无事可做');

  let roles = parseList(opts.roles);
  if (roles.length === 0) {
    if (opts.yes || !process.stdin.isTTY) {
      roles = [...ROLES];
    } else {
      roles = await promptRoles();
    }
  }
  const invalidRoles = roles.filter((r) => !ROLES.includes(r as Role));
  if (invalidRoles.length > 0) throw new Error(`未知的角色: ${invalidRoles.join(', ')}（可选: ${ROLES.join(', ')}）`);
  if (!roles.includes('engine')) roles.unshift('engine');

  await applyInstall(target, tools, roles, opts.force, false);
}

/**
 * 执行安装/更新主体。force 在 update 场景下对受管理文件始终为 true。
 * 返回 manifest。
 */
export async function applyInstall(
  target: string,
  tools: string[],
  roles: string[],
  force: boolean,
  isUpdate: boolean
): Promise<Manifest> {
  const manifestPath = path.join(target, MANIFEST_PATH);
  const prev: Manifest | null = exists(manifestPath) ? readJson(manifestPath) : null;

  // 2. 复制真实源到 .rdd/skills/
  const skillsDir = path.join(target, RDD_SKILLS_DIR);
  fs.mkdirSync(skillsDir, { recursive: true });
  for (const role of roles) {
    const src = roleSourceDir(role);
    if (!exists(src)) throw new Error(`源仓库缺少角色目录: ${src}`);
    const res = copyDirEx(src, path.join(skillsDir, `rdd-${role}`), isUpdate || force);
    console.log(`  rdd-${role}: 复制 ${res.copied} 个文件，跳过相同 ${res.skipped}`);
    for (const w of res.warnings) console.warn(`  ! ${w}`);
  }

  // 3. 为各客户端建 skill 链接
  const links: string[] = [...(prev?.links ?? [])];
  for (const tool of tools) {
    const linkDirRel = SKILLS_LINK_DIR[tool];
    if (!linkDirRel) continue; // 该客户端无专属链接目录（如 zcode，skill 走共享 .agents/skills）
    const linkDirPath = path.join(target, linkDirRel);
    for (const role of roles) {
      const linkPath = path.join(linkDirPath, `rdd-${role}`);
      const realTarget = path.join(RDD_SKILLS_DIR, `rdd-${role}`);
      if (exists(linkPath) && !isLink(linkPath) && (force || isUpdate)) {
        // 旧安装留下的普通目录副本，替换为链接
        fs.rmSync(linkPath, { recursive: true, force: true });
      }
      const r = linkDir(path.join(target, realTarget), linkPath);
      if (r === 'created') {
        const rel = path.relative(target, linkPath);
        if (!links.includes(rel)) links.push(rel);
        console.log(`  链接 ${rel} -> ${realTarget}`);
      } else if (r === 'error') {
        console.warn(`  ! ${tool}/skills/rdd-${role} 链接失败，该角色在此客户端不可用`);
      }
    }
  }

  // 4. 宿主专属薄文件
  const files: string[] = [...(prev?.files ?? [])];
  for (const tool of tools) {
    for (const tf of THIN_FILES[tool] ?? []) {
      const src = path.join(SOURCE_ROOT, tf.src);
      if (!exists(src)) {
        console.warn(`  ! 源缺失，跳过薄文件: ${tf.src}`);
        continue;
      }
      const dest = tf.userScope ? path.join(os.homedir(), tf.dest) : path.join(target, tf.dest);
      const r = copyFileEx(src, dest, isUpdate || force);
      // 清单统一记录相对 target 的路径；用户级文件用 ~ 前缀标记
      const rel = tf.userScope ? '~/' + tf.dest.split(path.sep).join('/') : path.relative(target, dest);
      if (r === 'created' || r === 'overwritten') {
        if (!files.includes(rel)) files.push(rel);
        console.log(`  薄文件 ${rel}: ${r === 'created' ? '已创建' : '已更新'}`);
      } else if (r === 'skipped-diff') {
        console.warn(`  ! 薄文件内容不同，已跳过（--force 覆盖）: ${rel}`);
      }
    }
  }

  // 5. 配置合并（OpenCode 相关）
  const merged: string[] = [...(prev?.merged ?? [])];
  if (tools.includes('opencode')) {
    const backupDir = path.join(target, BACKUP_DIR);
    const mergeConfig = (rel: string, mutate: (data: any) => any, initial: () => any) => {
      const p = path.join(target, rel);
      const firstTime = !merged.includes(rel);
      const isNew = !exists(p);
      let data: any;
      if (!isNew) {
        data = readJson(p);
        if (firstTime) {
          // 首次合并前备份原文件
          const bak = path.join(backupDir, rel.split(/[\\/]/).join('__'));
          fs.mkdirSync(path.dirname(bak), { recursive: true });
          fs.copyFileSync(p, bak);
        }
      } else {
        data = initial();
      }
      const before = JSON.stringify(data);
      data = mutate(data);
      if (isNew || JSON.stringify(data) !== before) {
        fs.mkdirSync(path.dirname(p), { recursive: true });
        fs.writeFileSync(p, JSON.stringify(data, null, 2) + '\n', 'utf8');
        console.log(`  合并配置 ${rel}`);
      }
      if (!merged.includes(rel)) merged.push(rel);
    };

    // docs/code-quality.md：存在即跳过，instructions 引用它
    const docRel = path.join('docs', 'code-quality.md');
    const docSrc = path.join(SOURCE_ROOT, docRel);
    if (exists(docSrc)) {
      const r = copyFileEx(docSrc, path.join(target, docRel), false);
      if (r === 'created') console.log(`  ${docRel}`);
    }
    mergeConfig(
      'opencode.json',
      (d) => ({ ...d, instructions: [...new Set([...(d.instructions ?? []), docRel])] }),
      () => ({ instructions: [docRel] })
    );
    const srcPkg = readJson(path.join(SOURCE_ROOT, '.opencode', 'package.json'));
    mergeConfig(
      path.join('.opencode', 'package.json'),
      (d) => ({ ...d, dependencies: { ...srcPkg.dependencies, ...(d.dependencies ?? {}) } }),
      () => ({ dependencies: { ...srcPkg.dependencies } })
    );
  }

  // 6. 写清单
  const manifest: Manifest = {
    ...(prev ?? {}),
    version: VERSION,
    sourceRoot: SOURCE_ROOT,
    sourceCommit: gitHead(SOURCE_ROOT),
    installedAt: prev?.installedAt ?? new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    tools: [...new Set([...(prev?.tools ?? []), ...tools])],
    roles: [...new Set([...(prev?.roles ?? []), ...roles])],
    links,
    files,
    merged,
  };
  writeJson(manifestPath, manifest);

  console.log(`\n完成${isUpdate ? '更新' : '安装'}: ${roles.length} 个角色 -> ${path.join(RDD_SKILLS_DIR)}，链接至 ${tools.join(', ')} 的 skills 目录。`);
  return manifest;
}

export function readManifest(target: string): Manifest {
  const p = path.join(target, MANIFEST_PATH);
  if (!exists(p)) {
    throw new Error(`未找到安装清单 ${MANIFEST_PATH}，请先在目标项目执行 init`);
  }
  return readJson(p);
}
