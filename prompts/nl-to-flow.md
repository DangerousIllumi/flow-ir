# 直接把这段发给你的 AI 助手

> 用法：在 IDE 里打开本仓库（或你 fork 的副本），把下面整段复制给 AI，末尾写上你的需求。

```text
我在用 nlg-workflow-toolkit 这个仓库。请按仓库里的 AGENTS.md 帮我做一条 PAD 工作流。

步骤：
1. 先读仓库根目录的 AGENTS.md；如果需要，执行 .\setup.ps1 和 .\scripts\check-env.ps1（只做一次）。
2. 按 skills/pad-flow-designer 的规则，把我的需求写成 flows/<name>.json。
   - pad_hint 必须是 pad-robin-action-kb 里真实存在的 actionId，不许编。
   - params 只能用该动作的真实参数名。
   - 必须有 budget；脚本类节点必须有 intent；发信/过账/删文件放进 guard。
3. 依次执行，并把每一步结果贴给我：
   node tools\pad-robin\flow-to-robin.js flows\<name>.json out.robin
   node tools\pad-robin\check.js out.robin
   .\tools\pad-sync\pad-admit.ps1 -FlowFile flows\<name>.json -RobinFile out.robin
4. 任何一步失败，都改 flows\<name>.json 后重跑，不要改生成器、不要手改 out.robin。

交付要求：
- 生成 0 error、check.js 0 errors、准入 0 fail（warn 可以，但要说明原因）。
- 告诉我 out.robin 的完整路径、粘贴进 PAD 的步骤，以及哪些地方必须我手工补（UI 元素、VBS、账号）。

我的需求：
<在这里写你的需求，例如：每天把某个目录下的 CSV 归档到另一个目录，同名覆盖，结束后弹窗提示>
```

## 如果你的 AI 说"找不到文件"

- 确认当前工作目录就是仓库根（能看到 `AGENTS.md` 和 `tools\`）。
- 让它先列一下仓库根目录，再读 `AGENTS.md`。
- 第一次使用必须先跑 `.\setup.ps1`，否则没有 `pad-robin-action-kb/`，生成器会直接拒绝。

## 可参考的现成样例

`tests/eval/fixtures/` 里有 9 个可直接抄的 `flow.json`：
foreach 遍历、switch 三路、guard 发信、有界循环+break、文件读写、Excel 读写、HTTP 调用、多条件 AND、无匹配提前结束。
