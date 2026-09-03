import { Command } from 'commander';
import { VERSION } from '../core/config';
import { runInit } from '../core/init';
import { runUpdate } from '../core/update';
import { runUninstall } from '../core/uninstall';

const program = new Command();

program
  .name('coderrdd')
  .description('RDD 工作流安装器：skills 安装到 .rdd/ 作为唯一真实源，并将 AI 客户端目录链接到它')
  .version(VERSION);

program
  .command('init')
  .description('在目标目录安装 RDD 工作流（交互式，或用 --tools/--roles 非交互）')
  .argument('[target]', '目标项目目录', '.')
  .option('--tools <tools>', '要适配的客户端，逗号分隔（opencode,claude）')
  .option('--roles <roles>', '要安装的角色，逗号分隔（engine,pm,cto,ux,dev,qa,eval,pse）')
  .option('--force', '内容不同的受管理文件直接覆盖')
  .option('--yes', '跳过交互确认，使用默认值（全部角色，opencode）')
  .action(async (target: string, opts) => {
    await runInit({ target, tools: opts.tools, roles: opts.roles, force: !!opts.force, yes: !!opts.yes });
  });

program
  .command('update')
  .description('按安装清单非交互更新（只更新受管理的文件）')
  .argument('[target]', '目标项目目录', '.')
  .action(async (target: string) => {
    await runUpdate({ target });
  });

program
  .command('uninstall')
  .description('按安装清单卸载（保留 .rdd 运行时数据）')
  .argument('[target]', '目标项目目录', '.')
  .action(async (target: string) => {
    await runUninstall({ target });
  });

program.parseAsync(process.argv).catch((err: Error) => {
  console.error(`错误: ${err.message}`);
  process.exitCode = 1;
});
