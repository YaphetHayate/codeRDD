#!/usr/bin/env node
/**
 * 发布前检查（prepublishOnly 调用，构建已在调用链中先行执行）：
 * 1. 防止 IDE / 本地工具文件随 files 白名单目录混入 tarball
 *    （.npmignore 对 files 白名单内的路径无效，只能物理检查）
 * 2. 确认构建产物存在
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
let failed = false;

// 1. 角色源目录中的本地产物（files 按 rdd-*/ 整目录打包，会随之带上）
const LEAKS = ['.idea', path.join('.claude', 'settings.local.json')];
const roleDirs = fs
  .readdirSync(ROOT)
  .filter((d) => /^rdd-/.test(d) && fs.statSync(path.join(ROOT, d)).isDirectory());
for (const role of roleDirs) {
  for (const leak of LEAKS) {
    if (fs.existsSync(path.join(ROOT, role, leak))) {
      console.error(`✗ 发现会混入 tarball 的本地产物: ${role}/${leak.replace(/\\/g, '/')}（删除后再发布）`);
      failed = true;
    }
  }
}

// 2. 构建产物
for (const f of ['dist/cli/index.js', 'bin/coderrdd.js', 'LICENSE']) {
  if (!fs.existsSync(path.join(ROOT, f))) {
    console.error(`✗ 缺失 ${f}`);
    failed = true;
  }
}

// 3. npm pack 边界（rdd-as-dsh-plugin R6 联动核对）：
//    dist/ 下除 cli/core（npm 运行时构建产物）外还有 engine/plugin/skills/
//    skills-staging/release 等发布构建目录——files 白名单必须枚举到子目录，
//    裸 "dist/" 会把这些 tarball/中间产物（含嵌套 package.json）全部收进根包。
const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
const files = manifest.files || [];
if (files.includes('dist') || files.includes('dist/')) {
  console.error('✗ files 白名单含裸 dist/——发布构建产物（*.tgz / skills-staging）会混入根包，请枚举为 dist/cli/ + dist/core/');
  failed = true;
}
// 引擎以独立包身份随根包分发：嵌套 rdd-engine/package.json 是有意的
// （发行版本真相源 + coderrdd init 拷贝后保留版本身份），缺失即破坏契约。
if (!fs.existsSync(path.join(ROOT, 'rdd-engine', 'package.json'))) {
  console.error('✗ 缺失 rdd-engine/package.json（引擎包清单是发行版本真相源，须随根包分发）');
  failed = true;
}

if (failed) process.exit(1);
console.log('发布前检查通过：无泄漏文件，构建产物与 LICENSE 就绪，npm pack 边界（dist 子目录枚举 + 嵌套引擎清单）符合契约');
