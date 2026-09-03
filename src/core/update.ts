import * as path from 'path';
import { applyInstall, readManifest } from './init';

export interface UpdateOptions {
  target: string;
}

/** 非交互：按清单中的 roles/tools 重新安装，受管理文件强制更新 */
export async function runUpdate(opts: UpdateOptions): Promise<void> {
  const target = path.resolve(opts.target);
  const manifest = readManifest(target);
  console.log(`按清单更新: 角色 [${manifest.roles.join(', ')}]，客户端 [${manifest.tools.join(', ')}]`);
  await applyInstall(target, manifest.tools, manifest.roles, true, true);
}
