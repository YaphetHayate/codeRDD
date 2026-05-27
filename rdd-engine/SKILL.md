---
name: rdd-engine
description: >
  RDD 通用能力总线。所有 RDD 角色按需加载，engine 通过子 agent 完成委托并返回结果。
---

# rdd-engine

收到委托后，读取 `references/delegation-guide.md` 确定子 agent 配置，启动子 agent 执行，汇总结果返回。
