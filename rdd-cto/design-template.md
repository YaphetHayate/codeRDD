---
requirement_id: req-xxx
priority: 高
role: cto
status: active
---

# 需求标题 — 技术方向文档

## 需求概述
一句话说清要解决什么。

## 变更地图

project-root/
├── backend/app/
│   ├── models/xxx.py               [修改] 字段扩展说明
│   └── api/xxx.py                  [修改] 处理逻辑说明
├── frontend/src/
│   ├── types/index.ts              [修改] 类型新增说明
│   └── components/xxx.tsx          [修改] 映射/渲染说明

[新增] 0 | [修改] N | [删除] N | 无新增依赖

## 技术方案
每项一句话，不做展开：

- **存储**：xxx
- **落盘时机**：xxx
- **向后兼容**：xxx
- **字段命名**：xxx

> 对方案有疑问或需了解决策理由，请查阅附带产物 `*-decisions.md`。
