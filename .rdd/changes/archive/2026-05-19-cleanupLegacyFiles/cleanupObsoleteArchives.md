# 删除 11 个过时归档

- **描述**：删除 `.rdd/changes/archive/` 下已无参考价值的 11 个历史归档目录（第一组 6 个 + 第二组 5 个），保留近期的 10 个核心归档
- **验收标准**：
  1. 以下 11 个目录及其全部内容已删除：
     - `2026-04-29-codeMapPanorama`
     - `2026-04-30-codeCompassAnalysis`
     - `2026-04-30-codeCompassChinese`
     - `2026-05-01-codeCompassScripting`
     - `2026-05-01-codeCompassSkillRewrite`
     - `2026-05-01-pendingNoiseFilter`
     - `2026-05-01-pmRedlineWhitelist`
     - `2026-05-01-skillIntegration`
     - `2026-05-06-optimizeSkills`
     - `2026-05-10-skillOptimization`
     - `2026-05-10-traceCommand`
  2. 以下 10 个目录保持完好：
     - `2026-05-10-ctoSearchAndEffort`
     - `2026-05-11-devDeliveryQuality`
     - `2026-05-12-devBugFixWorkflow`
     - `2026-05-13-skillAssistedWorkflow`
     - `2026-05-15-rddUxSkill`
     - `2026-05-16-devSkillLightweight`
     - `2026-05-16-rddDocStructure`
     - `2026-05-16-skillCollaboration`
     - `2026-05-16-skillLearning`
     - `2026-05-16-splitCtoSkill`
- **优先级**：高
- **来源细节**：讨论收敛

- **影响范围**：`.rdd/changes/archive/` 下的 11 个子目录
- **边界与异常**：保留的 10 个归档均为近一周产物，与当前 skill 版本一致；删除的归档为 code-compass 早期版本（已被重写）或被后续需求迭代覆盖的过程记录
