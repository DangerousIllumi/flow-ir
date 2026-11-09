# 冒烟示例

在全新 clone 上用一条命令验证工具链：画布 → 生成 → 静态校验 → 准入 → 结构评估。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File examples\smoke.ps1
```

- 任意一步非 0，整体退出码为 1；全部通过为 0。
- 不依赖业务目录、指纹基线或 PAD 运行历史；进程内的临时产物会自动清理。
- 没执行过 `npm install` 时，「画布」会自动退回仓库自带的确定性 BFS 布局，不需要联网装依赖。
- `smoke-kb.json` 是只含两个中性动作的最小动作表，仅用于本示例，不能替代正式的 `pad-robin-action-kb/`。
