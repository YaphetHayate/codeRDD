import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { BACKUP_DIR, MANIFEST_PATH, RDD_SKILLS_DIR, SKILLS_LINK_DIR } from './config';
import { exists, removeIfEmptyDir } from './fs-utils';
import { readManifest } from './init';

export interface UninstallOptions {
  target: string;
}

/** 按清单卸载：删链接与薄文件、删受管理角色目录、还原合并配置；保留 .rdd 下运行时数据 */
export async function runUninstall(opts: UninstallOptions): Promise<void> {
  const target = path.resolve(opts.target);
  const manifest = readManifest(target);

  // 1. 删链接
  for (const rel of manifest.links ?? []) {
    const p = path.join(target, rel);
    try {
      fs.unlinkSync(p);
      console.log(`  已删除链接 ${rel}`);
    } catch {
      console.warn(`  ! 删除链接失败（可能已不存在）: ${rel}`);
    }
  }

  // 2. 删薄文件，并向上清理因此变空的父目录（不越过 target / 用户主目录）
  for (const rel of manifest.files ?? []) {
    const isUser = rel.startsWith('~/');
    const base = isUser ? os.homedir() : target;
    const p = path.join(base, rel.slice(isUser ? 2 : 0));
    if (exists(p)) {
      fs.rmSync(p, { force: true });
      console.log(`  已删除文件 ${rel}`);
    }
    let dir = path.dirname(p);
    while (dir.startsWith(base) && dir !== base && removeIfEmptyDir(dir)) {
      dir = path.dirname(dir);
    }
  }

  // 3. 删受管理的角色目录（仅清单记录的，不动用户自建）
  for (const role of manifest.roles ?? []) {
    const p = path.join(target, RDD_SKILLS_DIR, `rdd-${role}`);
    if (exists(p)) {
      fs.rmSync(p, { recursive: true, force: true });
      console.log(`  已删除 ${path.join(RDD_SKILLS_DIR, `rdd-${role}`)}`);
    }
  }

  // 4. 从备份还原合并过的配置
  const backupDir = path.join(target, BACKUP_DIR);
  for (const rel of manifest.merged ?? []) {
    const bak = path.join(backupDir, rel.split(/[\\/]/).join('__'));
    const p = path.join(target, rel);
    if (exists(bak)) {
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.copyFileSync(bak, p);
      console.log(`  已从备份还原 ${rel}`);
    } else {
      // 没有备份说明该文件是 init 创建的，直接删除
      try {
        fs.rmSync(p, { force: true });
        console.log(`  已删除 init 创建的 ${rel}`);
      } catch {
        /* ignore */
      }
    }
  }

  // 5. 清理清单/备份与空目录（保留 .rdd 运行时数据）
  const manifestPath = path.join(target, MANIFEST_PATH);
  if (exists(manifestPath)) fs.rmSync(manifestPath, { force: true });
  if (exists(backupDir)) fs.rmSync(backupDir, { recursive: true, force: true });
  for (const tool of manifest.tools ?? []) {
    removeIfEmptyDir(path.join(target, SKILLS_LINK_DIR[tool] ?? path.join(`.${tool}`, 'skills')));
  }
  removeIfEmptyDir(path.join(target, RDD_SKILLS_DIR));
  removeIfEmptyDir(path.join(target, '.opencode', 'skills')); // 旧布局残留
  removeIfEmptyDir(path.join(target, '.agents', 'skills'));
  removeIfEmptyDir(path.join(target, '.agents'));
  removeIfEmptyDir(path.join(target, '.opencode'));
  removeIfEmptyDir(path.join(target, '.claude'));
  removeIfEmptyDir(path.join(target, '.rdd'));
  console.log('卸载完成（.rdd 下 changes/exploration/handoff 等运行时数据已保留，如不再需要请手动删除）。');
}
