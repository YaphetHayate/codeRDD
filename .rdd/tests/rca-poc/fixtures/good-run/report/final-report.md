# 结案报告(fixture-good-orchestrated)

## 调查摘要

fixture 最小合法 run,单轮收敛。

## 根因结论

release-2185(T-45 上线)引入的 orders 表按 customer_id 查询缺索引,rows_examined≈49万呈全表扫描特征,长期占用连接使连接池耗尽(上限 100),web 层等待连接导致 /v1/orders p99 突增至 8s+ 并产生 504。写接口不受影响与新查询仅命中读路径一致。

## 证据链索引

| id | 轮 | 假设 | 类型 | 判定 | conf | 要点 |
|----|----|------|------|------|------|------|
| E1 | 1 | H1 | causal | support | 0.9 | 部署→慢查询→池耗尽→等待,时序递进 |
