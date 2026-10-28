# 从一句话到可运行流程：示例与打分

> 这份文档回答两个问题：
> 1. 「需求 → flow.json → 校验通过 → 粘进 PAD」具体长什么样？
> 2. Agent 一次生成 9 条需求，怎么量化它到底靠不靠谱？

---

## 1. 示例：一句话如何变成 flow.json

**用户原话**

> 每天把 `C:\Temp\input.txt` 的内容原样复制到 `output.txt`，出问题就提示我。

**Agent A 要做的事**（按 `skills/pad-flow-designer/` 的步骤）

1. 提取要素：触发=每天；步骤=读文件 → 写文件；没有分支、没有循环、没有外部系统。
2. 查知识库确认动作存在（**不许凭记忆编**）：

   ```powershell
   node -e "const kb=require('./pad-robin-action-kb/PAD_Robin_ActionKB.json');for(const id of ['File.ReadTextFromFile.ReadText','File.WriteText'])console.log(id, kb.actions.some(a=>a.actionId===id)?'OK':'MISS')"
   ```

3. 产出 `flows/copy-text.json`（可直接复制 `tests/eval/fixtures/file-copy-text.json` 再改）：

   ```json
   {
     "name": "copy-text",
     "budget": { "maxLoop": 1 },
     "variables": [
       { "name": "InputFile",  "type": "string", "default": "C:\\Temp\\input.txt" },
       { "name": "OutputFile", "type": "string", "default": "C:\\Temp\\output.txt" }
     ],
     "edges": [{ "from": "1", "to": "2" }],
     "nodes": [
       { "id": "1", "pad_hint": "File.ReadTextFromFile.ReadText",
         "params": { "File": "{{variables.InputFile}}", "Encoding": "UTF8" },
         "output_map": { "Content": "FileContent" }, "next": ["2"] },
       { "id": "2", "pad_hint": "File.WriteText",
         "params": { "File": "{{variables.OutputFile}}", "TextToWrite": "{{1.FileContent}}",
                     "IfFileExists": "Overwrite", "AppendNewLine": false, "Encoding": "UTF8" } }
     ]
   }
   ```

   要点：`budget` 必填；参数值走 `{{variables.X}}` / `{{1.FileContent}}`；字符串字面量写成 `$'''…'''`。

4. 产出配套声明（缺了准入会拦）：
   - `flows/copy-text.requirements.json`：环境依赖（目录、Python 等）
   - `acceptance`：写进 flow.json 或 `flows/copy-text.acceptance.json`
   - `tests/eval/<需求id>.cases.json`：把"需求里必须成立的事实"写成断言

**四步验证**（顺序不能乱）

```powershell
node tools\pad-robin\flow-to-robin.js flows\copy-text.json out.robin
node tools\pad-robin\check.js out.robin
.\tools\pad-sync\pad-admit.ps1 -FlowFile flows\copy-text.json -RobinFile out.robin
node tools\pad-robin\eval-flow.js tests\eval\file-copy-text.cases.json
```

预期输出：

```text
已生成: out.robin（2 个节点）          <- 生成器把"已生成"写 stderr，属正常
OK   out.robin: 2 action lines, 0 errors
[admit] 通过 9 / 警告 4 / 待批 0 / 失败 0
PASS  read-then-write  需求：先读源文件，再写目标文件
[eval-flow] 通过 2 / 2
```

4 条警告是"没给 config / 没给批准记录"这类**信息性**提示；只要有 `[FAIL]` 就不能继续。

最后：PAD 新建流程 → 粘贴 `out.robin` → 补 UI 元素（本示例没有）→ 运行。

---

## 2. 批量打分：衡量"生成质量"而不是"这一次跑没跑通"

固定需求集就是 `tests/eval/*.cases.json`（9 条合成 + 1 条真实流程）。每个用例文件里的 `flow` 指向被测的 `flow.json`。

**打分流程**

1. 把 9 条需求的原文交给 Agent A，要求它每条的产出落到 `candidates/<需求id>.json`
2. 为每条需求准备得分规则（复用现有 `*.cases.json`，把 `flow` 改指向候选文件）
3. 逐条跑四件事：**结构断言 → 生成 → 静态校验 → 准入**
4. 记录到表里

**一条命令跑完（PowerShell 示例）**

```powershell
$rows = @()
Get-ChildItem candidates\*.json | ForEach-Object {
    $id = $_.BaseName
    $cases = "tests\eval\$id.cases.json"
    $out = "candidates\$id.robin"
    $struct = "skip"
    if (Test-Path $cases) {
        node tools\pad-robin\eval-flow.js $cases *> $null; $struct = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
    }
    node tools\pad-robin\flow-to-robin.js $_.FullName $out --no-check 2>$null
    $gen = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
    $chk = "-"
    if ($gen -eq "PASS") {
        node tools\pad-robin\check.js $out *> $null; $chk = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File tools\pad-sync\pad-admit.ps1 -FlowFile $_.FullName -RobinFile $out *> $null
    $admit = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
    $rows += [pscustomobject]@{ 需求 = $id; 结构 = $struct; 生成 = $gen; 静态 = $chk; 准入 = $admit }
}
$rows | Format-Table -AutoSize
"可交付率 = {0:P0}" -f (($rows | Where-Object { $_.结构 -eq 'PASS' -and $_.生成 -eq 'PASS' -and $_.静态 -eq 'PASS' -and $_.准入 -eq 'PASS' }).Count / $rows.Count)
```

**记分表模板**

| 需求 id | 结构断言 | 生成 | 静态校验 | 准入 | 判定 |
|---|---|---|---|---|---|
| foreach-archive | PASS | PASS | PASS | PASS | 可交付 |
| switch-exit-code | PASS | PASS | FAIL | - | 设计对、参数写错 |
| http-webhook | FAIL | - | - | - | 设计错（少了失败分支） |

判定口径：

- **四项全绿** → 可交付（仍需人工看业务语义）
- **结构绿、后面红** → 设计对了，参数/变量写错，属于"可自动修复"类
- **结构红** → 需求理解就错了，改参数没用，必须回到设计

**两条纪律**

1. 通过率只衡量**结构与可生成性**，不衡量文案和业务正确性——金额、批次、口径仍要人工确认。
2. 需求集固定，才可比较。改需求就等于换考卷，历史通过率不能直接对比；新增需求请另记一行并标注开始日期。
