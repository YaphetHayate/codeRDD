import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';
import { EXCLUDED_COPY_ENTRIES } from './config';

export function sha256(p: string): string {
  return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}

export function exists(p: string): boolean {
  try {
    fs.statSync(p);
    return true;
  } catch {
    return false;
  }
}

export function isLink(p: string): boolean {
  try {
    return fs.lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
}

export function linkTarget(p: string): string | null {
  try {
    return fs.readlinkSync(p);
  } catch {
    return null;
  }
}

export function readJson(p: string): any {
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

export function writeJson(p: string, data: unknown): void {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(data, null, 2) + '\n', 'utf8');
}

export interface CopyResult {
  copied: number;
  skipped: number;
  warnings: string[];
}

/**
 * 递归复制目录。内容相同（SHA256）的文件跳过；内容不同默认跳过并记录警告，
 * force 为 true 时覆盖（用于受管理文件）。
 */
export function copyDirEx(src: string, dest: string, force: boolean): CopyResult {
  const result: CopyResult = { copied: 0, skipped: 0, warnings: [] };
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    if (EXCLUDED_COPY_ENTRIES.has(entry.name)) continue;
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      const sub = copyDirEx(s, d, force);
      result.copied += sub.copied;
      result.skipped += sub.skipped;
      result.warnings.push(...sub.warnings);
    } else if (entry.isFile()) {
      if (exists(d)) {
        if (sha256(s) === sha256(d)) {
          result.skipped++;
          continue;
        }
        if (!force) {
          result.warnings.push(`内容不同，已跳过（使用 --force 覆盖）: ${path.relative(process.cwd(), d)}`);
          continue;
        }
      }
      fs.mkdirSync(path.dirname(d), { recursive: true });
      fs.copyFileSync(s, d);
      result.copied++;
    }
  }
  return result;
}

export function copyFileEx(src: string, dest: string, force: boolean): 'created' | 'skipped-same' | 'skipped-diff' | 'overwritten' {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  if (exists(dest)) {
    if (sha256(src) === sha256(dest)) return 'skipped-same';
    if (!force) return 'skipped-diff';
    fs.copyFileSync(src, dest);
    return 'overwritten';
  }
  fs.copyFileSync(src, dest);
  return 'created';
}

/**
 * 创建指向 target 的目录链接：Windows 用 junction（无需管理员权限），
 * 其他平台用相对 symlink。linkPath 已存在时返回 'exists'。
 */
export function linkDir(target: string, linkPath: string): 'created' | 'exists' | 'error' {
  if (exists(linkPath) || isLink(linkPath)) return 'exists';
  fs.mkdirSync(path.dirname(linkPath), { recursive: true });
  try {
    if (process.platform === 'win32') {
      // junction 要求绝对目标
      fs.symlinkSync(path.resolve(target), linkPath, 'junction');
    } else {
      const rel = path.relative(path.dirname(linkPath), target);
      fs.symlinkSync(rel, linkPath, 'dir');
    }
    return 'created';
  } catch (err) {
    console.warn(`  ! 创建链接失败 ${linkPath}: ${(err as Error).message}`);
    return 'error';
  }
}

export function removeIfEmptyDir(p: string): boolean {
  try {
    if (!fs.statSync(p).isDirectory()) return false;
    if (fs.readdirSync(p).length > 0) return false;
    fs.rmdirSync(p);
    return true;
  } catch {
    return false;
  }
}

export function gitHead(repo: string): string {
  try {
    const { execSync } = require('child_process') as typeof import('child_process');
    return execSync('git rev-parse HEAD', { cwd: repo, encoding: 'utf8' }).trim();
  } catch {
    return 'unknown';
  }
}
