---
name: windows-utf8-bom-safety
description: >-
  Detect, prevent, and repair UTF-8 BOM (EF BB BF) problems on Windows. Use whenever you write or
  rewrite text or config files (JSON, YAML, JS/TS, PS1, CSV, .env), when a program fails to start
  or parse with an error at position 0 naming an invisible character ("Unexpected token '\uFEFF'",
  "is not valid JSON", "Expecting value: line 1 column 1 (char 0)", "0xEF"), or when editing DSH
  profile manifests under ~/.dsh/profiles. Includes per-tool safe write recipes, defensive reading,
  and a check/scan/strip script that runs on Windows PowerShell 5.1 and PowerShell 7+.
license: Apache-2.0
metadata:
  version: "1.0.0"
  platform: windows
  tags: [encoding, bom, utf-8, json, powershell, dsh]
---

# windows-utf8-bom-safety

三字节 `EF BB BF` 可以让一个内容完全正确的 JSON 无法启动应用。这个技能负责三件事：
**写的时候别产生 BOM、读的时候容忍 BOM、坏了的时候按字节修好。**

## 何时使用

- 要写或改写配置文件：`package.json`、`*.yml`、`*.json`、`.env`、`*.ps1`、`*.csv`、脚本头
- 程序**启动即崩**，或解析失败，报错指向**第 1 行第 1 列 / position 0 / char 0**
- 报错文本里出现看不见的字符：`Unexpected token '\uFEFF'`、`Unexpected token ''`
- 跨工具的报错形态：`Expecting value: line 1 column 1 (char 0)`、`0xEF`、`\ufeffid` 列名
- 要改 DSH 的 `~/.dsh/profiles/<profile>/package.json`
- 在中文 Windows + Windows PowerShell 5.1 环境里做文件写入（本机即如此）

## 核心原则

1. **默认不带 BOM 写入，写完按字节校验**，不要按"显示看起来正常"判断。
2. **改别人的配置走它自己的接口**（CLI / API / 官方命令）。"读成对象 → 改字段 → 整体序列化写回"会同时换排版、换编码、丢字段。
3. **读外部文件时防御式剥离**：`text.replace(/^\uFEFF/, '')`，成本为零。

## 诊断：先看三个字节

```powershell
Format-Hex .\file.json | Select-Object -First 1
# 00000000  EF BB BF 7B 0D 0A ...   ← 有 BOM
# 00000000  7B 0D 0A 20 20 20 ...    ← 正常（{）

# 不依赖 Format-Hex（老版本没有 -Count）的写法
$b = Get-Content -LiteralPath .\file.json -Encoding Byte -TotalCount 3
"$($b -join ',')"   # 239,187,191 = EF BB BF
```

**识别口诀**：报错在第 1 行第 1 列、字符看不见 → 先查前三字节，再谈别的。

| 报错（原样） | 出处 |
|---|---|
| `SyntaxError: Unexpected token '\uFEFF', "\uFEFF{...` | `JSON.parse`（Node / 浏览器 / Electron） |
| `json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)` | Python `json.load` |
| `SyntaxError: Invalid or unexpected token`，指向 1:1 | JS 引擎直接执行 |
| `JsonReaderException ... position 0 ... 0xEF` | .NET / Newtonsoft |
| `found character '\ufeff' that cannot start any token` | YAML 解析 |
| CSV 第一列表头变成 `\ufeffid`，按 `id` 取列失败 | Excel / pandas |
| `bad interpreter`，`#!` 前面多了字节 | Shell 脚本 |

注意：`Get-Content` 显示正常**不代表没 BOM**——它在解码时会自动吞掉 BOM。判断只能靠字节。

## 原理

BOM 解码后是真实字符 `U+FEFF`，占据索引 0；RFC 8259 规定 JSON 文本不得以 BOM 开头，`JSON.parse` 严格不剥：

```js
JSON.parse('\uFEFF{"a":1}')  // SyntaxError: Unexpected token '\uFEFF'
JSON.parse('{"a":1}')        // OK
```

## 写文件：安全配方

| 场景 | ✅ 安全 | ❌ 会产生 BOM / 错误编码 |
|---|---|---|
| Node / Electron | `fs.writeFileSync(p, s, 'utf8')` | 手工拼接 Buffer 时把 BOM 当内容 |
| PowerShell 7 | `-Encoding utf8NoBOM`；`[IO.File]::WriteAllText($p,$s,[Text.UTF8Encoding]::new($false))` | `[Text.Encoding]::UTF8`（属性自带 BOM） |
| Windows PowerShell 5.1 | 只用 `[IO.File]::WriteAllText($p,$s,[Text.UTF8Encoding]::new($false))` | `Set-Content -Encoding UTF8`、`Out-File`、`>`、`>>`（`>` 默认是 UTF-16LE） |
| Python | `open(p,'w',encoding='utf-8',newline='\n')` | 写时用 `utf-8-sig`、Windows 默认 `gbk` |
| VS Code | 状态栏选 `UTF-8` | `UTF-8 with BOM` |
| 记事本 | 另存为选 `UTF-8`（新版默认无 BOM，但别赌） | `UTF-8 with BOM` |
| Git / CI | `.gitattributes` + `* text=auto eol=lf` | 让工具链各自决定编码 |

两个易错点：

- `ConvertTo-Json` 只产字符串、不加 BOM，坑在写回时的 `-Encoding`。5.1 的 `ConvertTo-Json` 会把排版改成 4 空格缩进 + 冒号后双空格——看到这种排版，说明文件被 PowerShell 整体重写过。
- **本机实测（2026-10）**：DSH 的 shell 是 Windows PowerShell **5.1.26100**，没有 `pwsh` 7，`-AsByteStream` / `utf8NoBOM` 都不存在。默认 `Set-Content -Encoding UTF8` 就带 BOM，所以这个环境特别容易踩。

## 读文件：防御式剥离

```js
const raw = require('fs').readFileSync(p, 'utf8').replace(/^\uFEFF/, '');
```

```python
text = path.read_text(encoding='utf-8-sig')   # 读：自动吃 BOM
# 写：仍用 encoding='utf-8'，不要沿用 utf-8-sig
```

```powershell
$raw = [IO.File]::ReadAllText($p) -replace '^\uFEFF', ''
```

## 校验闭环

```powershell
# 1) 字节层
$b = Get-Content -LiteralPath $p -Encoding Byte -TotalCount 3
if ($b.Count -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { throw "BOM written to $p" }

# 2) 语义层：用消费方的解析器验证
node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" $p
```

改的是**启动配置**时再严格一档：先校验，再重启应用，亲眼看到它起来，才算完成。

## DSH 专属规则

启动早期会 `JSON.parse` 读取 profile 清单：

```
<DSH_HOME>/profiles/<profile>/package.json     # 默认 C:\Users\<you>\.dsh\profiles\desktop\package.json
```

- `dsh-app-boot` 的 `readProfileManifest` 用 `readFileSync(path,'utf8')` + `JSON.parse`，**不剥 BOM**；失败会在启动阶段抛 `DesktopHostFatalError`，界面只有一句"应用无法启动"。
- **只通过官方命令修改**：`dsh plugin --profile <p> add|remove <pkg>`（内部 `writeProfileManifest` 输出 `JSON.stringify(...,2)` + 换行，无 BOM）。
- **绝对不要**用"`ConvertFrom-Json` → 改字段 → `ConvertTo-Json` → `Set-Content -Encoding UTF8`"整体重写清单，这是 2026-10-20 事故的直接原因。
- 改完必须同时满足：`node -e "JSON.parse(...)"` 通过，且 `dsh` 能真正启动（只验其一都不够）。

**启动失败后的恢复顺序**：

1. 别点"Disable third-party plugins / 重装"——两者都不动清单，重装也不影响 `~/.dsh`。
2. 备份：`Copy-Item package.json package.json.bak`
3. 查首三字节 → 有 BOM 就剥：`scripts/bom.ps1 -Mode strip -Apply -Backup`
4. `JSON.parse` 验证 → 重启。
5. 清单结构被改坏（如丢了 `dsh.profile.bundles`）时还原 `.bak`，或按同版本模板重建。

## 工具：scripts/bom.ps1

```powershell
# 单文件检查（0=干净 1=有 BOM 2=参数/IO 错误）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bom.ps1 -Path .\package.json -Mode check

# 目录扫描（默认跳过 node_modules/.git；列出所有带 BOM 的文件）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bom.ps1 -Path "$env:USERPROFILE\.dsh\profiles" -Mode scan -Recurse

# 剥离（默认 dry-run；-Apply 落盘，-Backup 留 <file>.bom-backup，可重入）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bom.ps1 -Path .\package.json -Mode strip -Apply -Backup
```

兼容 Windows PowerShell 5.1（`-Encoding Byte`）与 PowerShell 7+（`-AsByteStream`），只用 cmdlet，ConstrainedLanguage 下可用；三种模式均已在本机 5.1 实测。

## 反模式

- ❌ 用 `ConvertTo-Json` 整体重写 `package.json` / 启动配置
- ❌ 用 `>`、`Out-File`、`Set-Content -Encoding UTF8` 生成配置
- ❌ Python 以 `utf-8-sig` **写**文件
- ❌ 用 `Get-Content` / 记事本显示判断有没有 BOM
- ❌ 不看首三字节就断言"文件是对的"
- ❌ 变量名与参数重名：PowerShell 大小写不敏感，`$backup = "x"` 会覆盖 `[switch]$Backup` 并抛 `Cannot convert System.String to SwitchParameter`（本技能脚本第一版踩过，改名 `$backupPath` 解决）

## 自检清单

- [ ] 走的是官方写入接口，还是自己序列化重写？
- [ ] 写入路径会不会加 BOM（PS 5.1 `-Encoding UTF8`、`Out-File`、`>`、`[Text.Encoding]::UTF8`、Python `utf-8-sig`）？
- [ ] 写完是否按字节验过前三字节？
- [ ] 改的是启动配置吗？是否实际重启确认过？
- [ ] 报错在 position 0 / char 0 时，是否第一时间 `Format-Hex`？
- [ ] 是否留下了可回滚的备份？

## References 索引

| 文件 | 内容 |
|---|---|
| `references/incident-dsh-desktop-bom.md` | 2026-10-20 DSH 桌面端"应用无法启动"完整证据链：崩溃日志、1018/1021 字节差、PS 5.1 排版指纹、恢复步骤 |
| `scripts/bom.ps1` | `check` / `scan` / `strip` 实现与退出码 |
