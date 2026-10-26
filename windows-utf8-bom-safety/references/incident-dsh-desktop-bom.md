# 事故复盘：DSH 桌面端“应用无法启动”（2026-10-20）

一次**“修 A 问题把 A 修好了、顺手造出 B 问题”**的典型事故。保留全部证据链，供其他智能体做同类判断时比对。

## 现象

启动 `@deepseek-ai/dsh-desktop 0.2.1-rc.2` 弹出：

```
DeepSeek Harness is unavailable
The application could not start or stopped unexpectedly.
... Error details shortened.
Unexpected token '﻿', "﻿{
    "n"... is not valid JSON
Diagnostic report:
%APPDATA%\@deepseek-ai\dsh-desktop\logs\crash-2026-10-20T08-26-40-054Z-host.log
```

`Exit / Restart / Disable third-party plugins, back up profile patch, and restart` 三个按钮都没用，重启必然复现。

## 崩溃日志关键内容

```text
time: 2026-10-20T08:26:40.054Z
source: host
phase: startup
app: @deepseek-ai/dsh-desktop 0.2.1-rc.2

DesktopHostFatalError: Unexpected token '﻿', "﻿{
    "n"... is not valid JSON
    at ChildProcess.<anonymous> (file:///D:/dsh/dsh/resources/app.asar/lib/main.js:3831:49)

--- host diagnostic ---
SyntaxError: Unexpected token '﻿', "﻿{
    "n"... is not valid JSON
    at JSON.parse (<anonymous>)
    at readProfileManifest (.../dsh-app-boot/lib/index.js:913:22)
    at loadProfileDirectory (.../dsh-app-boot/lib/index.js:1016:42)
    at main (.../dsh-desktop-host/lib/index.js:224:18)
```

注意 `phase: startup`、`JSON.parse`、`readProfileManifest`——错误发生在“读配置”阶段，早于任何插件加载。

## 根因

`C:\Users\hh350\.dsh\profiles\desktop\package.json` 开头被写入了 UTF-8 BOM。

`dsh-app-boot` 的读取实现（0.2.0-rc.2，行为一致）是：

```js
function readProfileManifest(binName, dir) {
    const path = join(dir, "package.json");
    let raw;
    try {
        raw = readFileSync(path, "utf8");   // BOM 保留为 U+FEFF
    } catch (error) { ... }
    const parsed = JSON.parse(raw);          // 首字符 U+FEFF → SyntaxError
    ...
}
```

Node 的 `JSON.parse` 严格遵循 RFC 8259（JSON 文本不得以 BOM 开头），不剥 BOM。用同一台机器复现，报错文本与日志逐字节一致：

```text
first char code: feff
JSON.parse -> Unexpected token '﻿', "﻿{
    "n"... is not valid JSON
```

## BOM 是怎么进去的：证据链

### 1. 文件差异

| 文件 | 字节数 | 前 3 字节 |
|---|---|---|
| `package.json.bak`（坏） | 1021 | `EF BB BF` |
| `package.json`（修复后） | 1018 | `7B` (`{`) |

差的正好 3 字节，其余内容逐字节相同 → 事故只是“多了一个 BOM”，JSON 语义完全正确。

### 2. 排版指纹指向 Windows PowerShell 5.1

坏文件的排版是：顶层 4 空格缩进、冒号后**两个**空格、嵌套属性对齐到左花括号下方：

```json
{
    "name":  "dsh-profile-desktop",
    "dependencies":  {
                         "dsh-orb":  "^0.1.8"
                     }
}
```

这是 `ConvertTo-Json`（Windows PowerShell 5.1，5.1.26100）的固定输出格式，用本机 `powershell.exe` 复现，输出格式与 `.bak` 完全一致。结论：文件被“反序列化成对象 → 改字段 → `ConvertTo-Json` → 写回”整体重写过，而不是原地编辑。

而 5.1 的写回路径几乎都会带 BOM：`Set-Content -Encoding UTF8`（该版本的 `utf8` = UTF-8 **with BOM**）、`Out-File`、`[System.Text.Encoding]::UTF8`。

### 2.1 环境事实：执行命令的 shell 本身就是 5.1

2026-10-20 复查时实测：DSH 会话里执行命令用的宿主是 `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`（`$PSVersionTable.PSVersion` = **5.1.26100.9711**），`pwsh` 7 未安装。所以对当时的 agent 来说，最"顺手"的写法：

```powershell
$json = Get-Content $p -Raw | ConvertFrom-Json
$json.dsh.profile.bundles = $json.dsh.profile.bundles | Where-Object { $_ -ne 'dsh-orb' }
$json | ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8   # ← 这里落 BOM
```

产出物与 `.bak` 的特征完全吻合：4 空格缩进、冒号后双空格、BOM 开头、1021 字节。这不是"某个人手动加了个 BOM"，而是**默认编码行为 + 整体重写**这两个习惯叠加的必然结果。

### 3. 谁在 16:25 改的

- `package.json` 的修改时间：`16:25:01`
- 同一时刻 `~\.dsh\storages\session_projcache` 里活跃的是 `dsh_orb` 会话（`agentPreset: computer-use`，正在无人值守地做 MATLAB 网页作业），其 turn 3 提示词是“检查刚刚崩溃的原因”，turn 5 是“修复并完成作业”，草稿写着“**修复已落盘（重启后不再加载 dsh-orb）**”。
- 现在清单里 `dsh-orb` 确实已从 `dsh.profile.bundles` 移除，但仍留在 `dependencies`（`^0.1.8`）。

即：该 agent 为了修另一个崩溃，移除了 dsh-orb，用 PS 5.1 风格脚本整体重写了清单，顺手带进了 BOM。

### 4. 时间线

| 时间（本地） | 事件 |
|---|---|
| 16:19:51 – 16:25:16 | 4 次 `exited with 3221226356`（`0xC0000374` 堆损坏），日志含 `dsh-orb` —— **另一个独立问题** |
| 16:25:01 | `package.json` 被重写（BOM 落盘） |
| 16:25:23 / 16:25:30 / 16:26:40 | 3 次启动全部死于 `readProfileManifest` 的 `JSON.parse` |
| 17:02:26 | 用户脚本按字节检测、剥掉 BOM 并写回，恢复 |

## 为什么“重装/禁用插件”没用

- 清单在启动早期就被解析，**每次启动读的都是同一个坏文件**，必然复现。
- “Disable third-party plugins, back up profile patch” 只处理 patch 层（`cordis.patch.yml`），清单仍要解析 → 无效。
- “reinstall” 只替换程序文件，用户 profile 在 `~/.dsh` 下，重装不影响 → 误导。

## 恢复步骤（可复用）

```powershell
$p = "$env:USERPROFILE\.dsh\profiles\desktop\package.json"

# 1) 备份
Copy-Item $p "$p.bak" -ErrorAction Stop

# 2) 按字节判断（不要用 Get-Content 判断，它会自动吞 BOM）
$b = Get-Content -LiteralPath $p -AsByteStream -TotalCount 3
if ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
    $bytes = Get-Content -LiteralPath $p -AsByteStream
    $body  = [byte[]]$bytes[3..($bytes.Count-1)]
    Set-Content -LiteralPath $p -Value $body -AsByteStream -NoNewline
}

# 3) 用消费方的解析器验证
node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); console.log('ok')" $p
```

也可以直接用本技能的 `scripts/bom.ps1 -Mode strip -Apply -Backup`。

## 教训

1. **不要用通用序列化器整体重写启动配置。** 用应用自己的写入接口（DSH 是 `dsh plugin ...` → `writeProfileManifest`），它保证无 BOM、2 空格、末尾换行。
2. **“看不见的字符”按字节验证。** `Get-Content` 会静静吃掉 BOM，显示正常、`ConvertFrom-Json` 也通过，唯独启动器挂掉。
3. **修完必须实际启动一次。** 该 agent 写了“修复已落盘”就继续做作业，真正的验证发生在下一次启动——而那次启动崩了。
4. **应用侧应容错。** `readFileSync(p,'utf8').replace(/^\uFEFF/, '')` 一行即可；或解析失败时隔离坏清单、回退模板，而不是 `DesktopHostFatalError`。
