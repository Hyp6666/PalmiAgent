# 工作区文件工具全覆盖测试提示词

> 将下面「测试提示词」部分的内容完整粘贴到一个空白项目的对话中。
> Palmi 应当依次完成所有步骤，每步都给出执行结果。
> 测试结束后，对照「核验标准」逐项确认。

---

## 测试提示词

```
请按照下面的步骤，依次完成全部文件操作。每步完成后告诉我结果，不要跳步，不要合并步骤。

———— 第一阶段：创建目录结构 ————

1. 创建目录 `project/src`
2. 创建目录 `project/src/utils`
3. 创建目录 `project/docs`
4. 创建目录 `project/data`
5. 创建目录 `project/backup`

———— 第二阶段：写入文件 ————

6. 在 `project/src/main.py` 写入以下内容：
```python
import json
from utils.helpers import format_name

def main():
    data = {"name": "Palmi", "version": "1.0"}
    print(json.dumps(data, ensure_ascii=False))

if __name__ == "__main__":
    main()
```

7. 在 `project/src/utils/helpers.py` 写入以下内容：
```python
def format_name(name: str) -> str:
    return f"[{name.upper()}]"

def calculate_sum(numbers: list) -> int:
    return sum(numbers)
```

8. 在 `project/docs/README.md` 写入以下内容：
```markdown
# 测试项目

这是一个用于验证 Palmi 文件操作能力的测试项目。

## 功能清单
- 文件读写
- 目录管理
```

9. 在 `project/data/records.csv` 写入以下内容：
```
姓名,年龄,城市
张三,28,北京
李四,32,上海
```

10. 在 `project/config.json` 写入以下内容：
```json
{
  "app_name": "TestApp",
  "version": "1.0.0",
  "debug": true
}
```

———— 第三阶段：查看目录结构 ————

11. 查看 `project` 目录的完整目录树（递归）
12. 查看 `project/src` 目录的直接子项（不递归）

———— 第四阶段：读取文件（多种模式）————

13. 正常读取 `project/src/main.py` 的完整内容
14. 用 head 模式读取 `project/docs/README.md` 的开头
15. 用 tail 模式读取 `project/data/records.csv` 的结尾
16. 用 section 模式读取 `project/docs/README.md`，focus 设为「功能清单」

———— 第五阶段：追加内容 ————

17. 向 `project/data/records.csv` 追加一行：
```
王五,25,深圳
```

18. 向 `project/docs/README.md` 追加以下内容：
```markdown

## 更新日志
- v1.0：初始版本
```

19. 向一个不存在的文件 `project/logs/build.log` 追加以下内容（验证自动创建）：
```
[2025-01-01 10:00:00] 构建开始
```

20. 读取 `project/data/records.csv`，确认追加的「王五」行存在
21. 读取 `project/logs/build.log`，确认文件已自动创建且内容正确

———— 第六阶段：文件信息与存在性检查 ————

22. 查看 `project/config.json` 的文件信息（大小、类型、修改时间）
23. 查看 `project/src` 的文件信息（应显示为目录，含子项数）
24. 检查 `project/src/main.py` 是否存在（应为「存在」）
25. 检查 `project/nonexistent.txt` 是否存在（应为「不存在」）

———— 第七阶段：复制文件 ————

26. 将 `project/config.json` 复制到 `project/backup/config.json`
27. 将 `project/data/records.csv` 复制到 `project/backup/records_backup.csv`
28. 读取 `project/backup/config.json`，确认内容与原文件一致

———— 第八阶段：移动与重命名 ————

29. 将 `project/src/utils/helpers.py` 移动到 `project/src/lib.py`（相当于重命名+移动到上层）
30. 检查 `project/src/utils/helpers.py` 是否还存在（应为「不存在」）
31. 检查 `project/src/lib.py` 是否存在（应为「存在」）
32. 将 `project/docs/README.md` 重命名为 `project/docs/GUIDE.md`
33. 读取 `project/docs/GUIDE.md`，确认内容包含「功能清单」和「更新日志」

———— 第九阶段：覆盖写入 ————

34. 用 fileWrite 覆盖 `project/config.json` 的内容为：
```json
{
  "app_name": "TestApp",
  "version": "2.0.0",
  "debug": false,
  "new_field": "added"
}
```

35. 读取 `project/config.json`，确认 version 已变为 2.0.0 且 new_field 存在
36. 读取 `project/backup/config.json`，确认备份仍然是旧版本 1.0.0（验证复制独立性）

———— 第十阶段：Python 脚本执行 ————

37. 用内联 Python 脚本执行以下代码：
```python
import workspace
content = workspace.read_text("project/data/records.csv")
lines = content.strip().split("\n")
print(f"CSV 共 {len(lines)} 行（含表头）")
for line in lines[1:]:
    parts = line.split(",")
    print(f"  {parts[0]} 来自 {parts[2]}")
```

38. 先写一个 Python 脚本文件 `project/src/analyze.py`，内容为：
```python
import workspace
import json

config = json.loads(workspace.read_text("project/config.json"))
print(f"应用：{config['app_name']}")
print(f"版本：{config['version']}")
print(f"调试模式：{'开启' if config['debug'] else '关闭'}")

workspace.write_text("project/data/analysis_result.txt", f"分析完成：{config['app_name']} v{config['version']}")
```
然后用 script_path 方式运行 `project/src/analyze.py`

39. 读取 `project/data/analysis_result.txt`，确认 Python 脚本成功创建了这个文件

———— 第十一阶段：批量读取 ————

40. 用 listDirectory 的 include_content=true 模式批量读取 `project/src` 目录下所有文件的内容

———— 第十二阶段：清理 ————

41. 删除文件 `project/logs/build.log`
42. 删除目录 `project/backup`（连同里面的文件）
43. 检查 `project/backup` 是否还存在（应为「不存在」）
44. 检查 `project/logs/build.log` 是否还存在（应为「不存在」）

———— 第十三阶段：最终验证 ————

45. 查看 `project` 目录的完整目录树，展示最终的文件结构
```

---

## 核验标准

测试完成后，逐项对照以下清单。**全部通过才算合格。**

### A. 目录结构核验（步骤 45 的目录树）

最终的 `project/` 目录树应当精确匹配以下结构（不多不少）：

```
project/
├── config.json
├── data/
│   ├── analysis_result.txt    ← Python 脚本创建
│   └── records.csv
├── docs/
│   └── GUIDE.md               ← 原 README.md 重命名而来
├── logs/                       ← 空目录（build.log 已删除）或不存在
└── src/
    ├── analyze.py
    ├── lib.py                  ← 原 utils/helpers.py 移动而来
    ├── main.py
    └── utils/                  ← 空目录（helpers.py 已移走）或不存在
```

**注意**：`backup/` 目录应当已经不存在。`logs/` 和 `src/utils/` 是否存在取决于删除/移动实现是否会留下空目录——两种都可以。

### B. 工具覆盖核验

| 工具 | 要求调用次数 | 涉及步骤 |
|------|-------------|----------|
| `fileManage(mkdir)` | >= 5 | 1-5 |
| `fileManage(delete)` | >= 2 | 41, 42 |
| `fileManage(move)` | >= 1 | 29 |
| `fileManage(rename)` | >= 1 | 32 |
| `fileManage(copy)` | >= 2 | 26, 27 |
| `fileManage(info)` | >= 2 | 22, 23 |
| `fileManage(exists)` | >= 4 | 24, 25, 30, 31, 43, 44 |
| `fileWrite` | >= 5 | 6, 7, 8, 9, 10, 34, 38(写脚本) |
| `fileAppend` | >= 3 | 17, 18, 19 |
| `fileRead` | >= 8 | 13, 14, 15, 16, 20, 21, 28, 33, 35, 36, 39 |
| `listDirectory` | >= 3 | 11, 12, 40, 45 |
| `runPython` | >= 2 | 37, 38 |

### C. 关键行为核验

逐条检查，在后面打勾：

- [ ] **C1 - mkdir 嵌套创建**：步骤 2 创建 `project/src/utils` 时，父目录 `project/src` 已在步骤 1 创建，不应报错
- [ ] **C2 - fileWrite 自动建父目录**：步骤 6 写入 `project/src/main.py`，目录已存在时正常写入
- [ ] **C3 - fileAppend 自动创建文件**：步骤 19 向不存在的 `project/logs/build.log` 追加，应自动创建 `logs/` 目录和文件（不报错）
- [ ] **C4 - fileAppend 内容正确**：步骤 20 读取 records.csv，应看到 4 行（表头 + 张三 + 李四 + 王五）
- [ ] **C5 - fileRead head 模式**：步骤 14 只返回 README.md 开头部分
- [ ] **C6 - fileRead tail 模式**：步骤 15 只返回 records.csv 结尾部分
- [ ] **C7 - fileRead section+focus**：步骤 16 围绕「功能清单」返回相关片段
- [ ] **C8 - info 返回文件元数据**：步骤 22 返回 config.json 的大小（字节）、类型（文件）、修改时间
- [ ] **C9 - info 返回目录元数据**：步骤 23 返回 `project/src` 的类型（目录）和子项数
- [ ] **C10 - exists 正确判断存在**：步骤 24 返回「存在」
- [ ] **C11 - exists 正确判断不存在**：步骤 25 返回「不存在」
- [ ] **C12 - copy 独立性**：步骤 36 读取备份的 config.json，version 仍为 1.0.0（与步骤 35 的 2.0.0 不同）
- [ ] **C13 - move 源消失**：步骤 30 确认原路径 helpers.py 不存在
- [ ] **C14 - move 目标出现**：步骤 31 确认新路径 lib.py 存在
- [ ] **C15 - rename 内容保留**：步骤 33 确认 GUIDE.md 包含原 README.md 的全部内容（含追加的更新日志）
- [ ] **C16 - 覆盖写入生效**：步骤 35 确认 config.json 的 version=2.0.0 且 new_field 存在
- [ ] **C17 - Python inline 执行**：步骤 37 输出 CSV 行数和各人城市信息
- [ ] **C18 - Python script_path 执行**：步骤 38 先写入 analyze.py，然后用 script_path 运行，输出应用名和版本
- [ ] **C19 - Python 写文件生效**：步骤 39 确认 analysis_result.txt 存在且内容包含「TestApp v2.0.0」
- [ ] **C20 - listDirectory include_content**：步骤 40 返回 src/ 下所有文件的内容文本
- [ ] **C21 - delete 文件**：步骤 41 删除 build.log 成功，步骤 44 确认不存在
- [ ] **C22 - delete 目录（递归）**：步骤 42 删除 backup/ 连带其中文件，步骤 43 确认不存在
- [ ] **C23 - 最终目录树正确**：步骤 45 的目录树与「A. 目录结构核验」匹配
- [ ] **C24 - 每步都有响应**：Palmi 对 45 个步骤逐一给出了执行结果文本，没有跳步或静默执行

### D. 错误处理观察（可选加分项）

如果想进一步测试健壮性，可以在测试结束后额外输入以下命令：

```
额外测试：
A. 尝试读取一个不存在的文件 `project/ghost.txt`，应返回错误而非空内容
B. 尝试将文件复制到一个已存在的路径（比如把 config.json 再复制到 data/records.csv），看是否报错或提示冲突
C. 运行一段会报错的 Python 脚本：`print(1/0)`，看是否正确返回 ZeroDivisionError
D. 尝试用 fileManage 传一个不支持的 operation，比如 `compress`，应返回错误
```

| 测试 | 期望行为 |
|------|---------|
| A - 读取不存在文件 | 返回明确错误信息，不是空白 |
| B - 复制到已存在路径 | 返回错误或冲突提示 |
| C - Python 运行时错误 | 返回 ZeroDivisionError 错误信息 |
| D - 不支持的 operation | 返回「不支持的 operation」错误 |

---

## 评分

- **C1-C24 全部通过** + **B 表工具覆盖达标** + **A 目录树正确** = 合格
- **D 项 4/4 通过** = 优秀（错误处理也正确）
- **任一 C 项未通过** = 该工具或该行为存在 bug，需要修复
