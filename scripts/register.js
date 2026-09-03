#!/usr/bin/env node
/**
 * 源码安装模式注册器：把当前源码仓注册为全局 `coderrdd` 命令（npm link）。
 *
 * 用法（在 codeRDD 仓根）：
 *   npm run register      # 依赖检查 -> npm install（按需）-> 构建 -> npm link -> 自检
 *   npm run unregister    # 移除全局命令
 *
 * 说明：
 * - link 后全局命令始终执行本仓的 dist/，改源码后 `npm run build` 即生效；
 * - 源仓目录移动/重命名会使全局链接失效，回仓根重新 `npm run register`；
 * - 与 `npm i -g coderrdd` 占用同一命令槽位，后装者覆盖。
 */
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const PKG = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
const IS_WIN = process.platform === 'win32';

/** 运行依赖（安装器运行时 + 构建所需），齐全则跳过 npm install，便于离线/重复注册 */
const REQUIRED_DEPS = ['commander', '@inquirer/prompts', 'typescript'];

function fail(msg) {
  console.error(`\n注册失败: ${msg}`);
  process.exit(1);
}

function run(cmdLine) {
  return spawnSync(cmdLine, { cwd: ROOT, stdio: 'inherit', shell: true });
}

/**
 * 运行命令并捕获 stdout（经 shell 重定向到临时文件，不占用管道，
 * 避免某些受限环境下 pipe stdio 被拒绝；stderr 丢弃，防止 npm 警告污染输出）。
 */
function captureRun(cmdLine) {
  const os = require('os');
  const devnull = IS_WIN ? '2>NUL' : '2>/dev/null';
  const tmp = path.join(os.tmpdir(), `coderrdd-reg-${Date.now()}-${process.pid}.txt`);
  const r = spawnSync(`${cmdLine} > "${tmp}" ${devnull}`, { cwd: ROOT, stdio: 'ignore', shell: true });
  let out = '';
  try {
    out = fs.readFileSync(tmp, 'utf8');
    fs.unlinkSync(tmp);
  } catch {
    /* ignore */
  }
  return { status: r.status, stdout: out };
}

function step(name) {
  console.log(`\n==> ${name}`);
}

console.log(`codeRDD 源码安装注册 (v${PKG.version})`);
console.log(`  仓库: ${ROOT}`);

// 1. Node 版本检查（与 package.json engines 一致）
const major = parseInt(process.version.slice(1).split('.')[0], 10);
if (major < 18) {
  fail(`需要 Node.js 18+，当前 ${process.version}`);
}
console.log(`  Node: ${process.version} ✓`);

// 2. 依赖安装（运行依赖齐全时跳过；如需更新依赖请手动 npm install）
step('检查依赖');
const depsReady = REQUIRED_DEPS.every((d) => fs.existsSync(path.join(ROOT, 'node_modules', d)));
if (depsReady) {
  console.log('  依赖已就绪，跳过 npm install（更新依赖请手动执行 npm install）');
} else {
  console.log('  npm install ...');
  if (run('npm install').status !== 0) fail('npm install 失败（检查网络或手动执行 npm install）');
}

// 3. 构建
step('构建 (npm run build)');
if (run('npm run build').status !== 0) fail('构建失败（检查 TypeScript 报错）');
if (!fs.existsSync(path.join(ROOT, 'dist', 'cli', 'index.js'))) {
  fail('构建产物缺失: dist/cli/index.js');
}

// 4. 已有全局安装提示（link 会覆盖；npm 对 junction 目标的显示不稳定，不做路径比对）
const ls = captureRun('npm ls -g coderrdd --depth=0');
if (ls.status === 0) {
  const out = ls.stdout || '';
  if (out.includes('->')) {
    console.log('  已有 coderrdd 全局链接，将刷新指向本仓');
  } else if (out.includes('coderrdd@')) {
    console.warn('  ! 检测到 npm 安装的全局 coderrdd，本次注册将覆盖（恢复: npm i -g coderrdd）');
  }
}

// 5. 注册全局命令（--ignore-scripts：第 3 步已构建并校验过 dist，跳过 link 时
//    prepare 钩子的重复构建；也避免受限环境下 npm 生命周期脚本的管道捕获问题）
step('npm link');
if (run('npm link --ignore-scripts').status !== 0) fail('npm link 失败');

// 6. 自检：直接经全局 bin 目录调用（不依赖 PATH 刷新）
step('自检');
const prefix = captureRun('npm config get prefix');
if (prefix.status !== 0) fail('无法获取 npm 全局 prefix');
const binDir = (prefix.stdout || '').trim();
const shim = IS_WIN ? path.join(binDir, 'coderrdd.cmd') : path.join(binDir, 'bin', 'coderrdd');
const probe = captureRun(`"${shim}" --version`);
const got = (probe.stdout || '').trim();
if (probe.status !== 0 || got !== PKG.version) {
  fail(`自检不通过: coderrdd --version 输出 "${got}"，期望 "${PKG.version}"（status=${probe.status}, shim=${shim}）`);
}
console.log(`  coderrdd --version -> ${got} ✓`);
console.log(`  全局命令位置: ${binDir}`);

console.log(`
注册完成！接下来在任意目标项目里：

  coderrdd init .                                # 交互式：选择 AI 客户端与角色
  coderrdd init . --tools opencode,claude --yes  # 非交互（CI / 脚本）
  coderrdd update .                              # 更新已安装项目
  coderrdd uninstall .                           # 卸载（保留 .rdd 运行时数据）

提示：
- 升级：源仓 git pull && npm run build，目标项目里 coderrdd update .
- 移除全局命令: npm run unregister（在本仓根）
- 源仓移动/重命名后链接失效，回仓根重新 npm run register
- PowerShell 若提示"无法加载脚本"，改用 coderrdd.cmd 或执行
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`);
