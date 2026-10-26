# BOM_Safety_SKILL

2026-10-20 DSH 桌面端“应用无法启动”事故的排查产出：一个可直接给智能体加载的技能包，外加完整的证据复盘。

## 30 秒结论

`%USERPROFILE%\.dsh\profiles\desktop\package.json` 开头被写入了 UTF-8 BOM（`EF BB BF`），
启动时 `JSON.parse` 拒绝解析 → `DesktopHostFatalError` → 弹“应用无法启动”。
文件内容完全正确，只是多了 3 个字节。

## 目录结构

```
BOM_Safety_SKILL/
├─ README.md                                    ← 本文件
├─ windows-utf8-bom-safety-skill.zip             ← 打包版，可直接分发
└─ windows-utf8-bom-safety\                      ← 技能源目录（可整体拷到任意 agent 的 skills 目录）
   ├─ SKILL.md                                   ← 技能主体：识别 / 防范 / 修复 / 校验闭环
   ├─ scripts\bom.ps1                            ← check / scan / strip 工具，PS 5.1 与 7 双兼容
   └─ references\incident-dsh-desktop-bom.md     ← 本次事故的完整证据链与恢复步骤
```

> 同一份技能已安装在 `C:\Users\hh350\.agents\skills\windows-utf8-bom-safety`，本会话的技能目录里可见。
> 修改内容时请以本目录为准，改完再同步过去（或删掉安装副本，只保留这里）。

## 怎么用

### 1）给智能体加载

- **DSH / Claude Code（用户级）**：把 `windows-utf8-bom-safety` 整个目录复制到 `%USERPROFILE%\.agents\skills\`。
- **项目级**：复制到项目的 `.claude/skills/`（或对应平台的 skills 目录）。
- **其他平台**：只需把 `SKILL.md` 作为上下文喂给模型；它本身就是自包含的操作手册。

技能会在这些场景自动命中：写/改配置文件、程序启动即崩、报错指向“第 1 行第 1 列 / position 0”、
报错里出现看不见的字符、要改 `~/.dsh` 下的 profile 清单。

### 2）直接用脚本

```powershell
# 检查单个文件（0=干净 1=有 BOM 2=错误）
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-utf8-bom-safety\scripts\bom.ps1 -Path .\package.json -Mode check

# 扫描目录（默认跳过 node_modules/.git；列出所有带 BOM 的文件）
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-utf8-bom-safety\scripts\bom.ps1 -Path "$env:USERPROFILE\.dsh\profiles" -Mode scan -Recurse

# 剥离 BOM（默认 dry-run；-Apply 落盘，-Backup 留 .bom-backup 副本）
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-utf8-bom-safety\scripts\bom.ps1 -Path .\package.json -Mode strip -Apply -Backup
```

### 3）再次遇到 DSH 启动失败

```powershell
$p = "$env:USERPROFILE\.dsh\profiles\desktop\package.json"
Copy-Item $p "$p.bak" -ErrorAction Stop
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-utf8-bom-safety\scripts\bom.ps1 -Path $p -Mode strip -Apply -Backup
node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));console.log('ok')" $p
# 然后重启桌面端
```

## 关键事实（排查中确认的）

| 事实 | 说明 |
|---|---|
| 报错里的 `Unexpected token '\uFEFF'` | 那个不可见字符就是 `U+FEFF` |
| 坏文件 1021 字节 / 好文件 1018 字节 | 差的正是 `EF BB BF` |
| 坏文件排版是 4 空格缩进、冒号后双空格 | Windows PowerShell 5.1 `ConvertTo-Json` 的指纹 |
| 本机 DSH 的 shell 是 PowerShell **5.1**，没有 `pwsh` 7 | 5.1 的 `Set-Content -Encoding UTF8` = 带 BOM，事故几乎是必然 |
| `Get-Content` 显示正常 | 它解码时会吞掉 BOM，按显示判断必翻车，要按字节验证 |
| 重装 / 禁用插件无效 | 清单在启动早期解析，且 profile 在 `~/.dsh`，重装不动它 |

## 说明

本目录所有文件均以 **UTF-8 无 BOM** 保存——技能内容自己就得先做对。
若用 PowerShell 5.1 编辑这里的文件，别用 `Set-Content -Encoding UTF8`，用：

```powershell
[System.IO.File]::WriteAllText($p, $s, [System.Text.UTF8Encoding]::new($false))
```

## License

Apache-2.0，见 [LICENSE](LICENSE)。
