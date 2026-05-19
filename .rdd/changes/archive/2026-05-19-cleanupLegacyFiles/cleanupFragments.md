# 删除项目根目录下的历史碎片文件

- **描述**：删除开发目录中已被新机制取代的历史兼容文件和 IDE 配置碎片
- **验收标准**：
  1. `rdd-engine/skill-registry.md` 已删除
  2. `rdd-cto/.idea/` 整个目录已删除
  3. 删除后 `rdd-engine/references/skill-manager.md` 中对该文件的引用需同步移除
  4. 以上路径不再存在于文件系统中
- **优先级**：高
- **来源细节**：讨论收敛

- **影响范围**：`rdd-engine/skill-registry.md`、`rdd-cto/.idea/`、`rdd-engine/references/skill-manager.md`
- **边界与异常**：
  - `skill-registry.md` 在 `skill-manager.md` 中有一处兜底引用（line 138），需同步清理
  - `.idea/` 目录中的 `workspace.xml` 包含用户本地路径，不宜保留在任何版本管理中
