---
requirement_id: req-xxx
priority: 高
role: cto
status: active
acceptance_ref: requirements/{name}.md（对齐验收标准 1/2/3）
---

# 需求标题 — 技术方向文档

## 需求概述
一句话说清要解决什么。

## 变更地图

project-root/
├── backend/app/
│   ├── `backend/app/models/xxx.py`             [修改] 字段扩展说明
│   └── `backend/app/api/xxx.py`                [修改] 处理逻辑说明
├── frontend/src/
│   ├── `frontend/src/types/index.ts`           [修改] 类型新增说明
│   └── `frontend/src/components/xxx.tsx`       [修改] 映射/渲染说明

[新增] 0 | [修改] N | [删除] N | 无新增依赖

> **机读契约（并行文件冲突检测基础）**：每个文件行必须是「`仓库根相对完整路径` [新增]/[修改]/[删除] 说明」——**完整路径以反引号包裹、与 [op] 标注同一行**是硬格式（delivery-bridge 据此机械机读：文件重叠检测/计数核对/回执一致性软核对）；目录树行仅视觉分组、可省略；计数行与文件行机械核对。不合契约的行报 `DESIGN_MAP_INVALID` 警示（不阻塞流转，但机械重叠检测对失明文档降级人工核对）。

## 技术方案
每项一句话，不做展开：

- **存储**：xxx
- **落盘时机**：xxx
- **向后兼容**：xxx
- **字段命名**：xxx

> 对方案有疑问或需了解决策理由，请查阅附带产物 `*-decisions.md`。
