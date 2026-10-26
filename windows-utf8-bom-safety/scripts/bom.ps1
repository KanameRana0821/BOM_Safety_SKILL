<#
.SYNOPSIS
    Detect, scan for, and strip a UTF-8 BOM (EF BB BF) from text files.

.DESCRIPTION
    Works on both Windows PowerShell 5.1 (-Encoding Byte) and PowerShell 7+
    (-AsByteStream). Only cmdlets are used, so it also runs in ConstrainedLanguage.

    Exit codes
      0  clean / operation succeeded
      1  BOM found (check, scan) or strip failed
      2  bad arguments / IO error

.PARAMETER Path
    File or directory to inspect.

.PARAMETER Mode
    check  - inspect a single file (default)
    scan   - recurse over a directory and list every file with a BOM
    strip  - remove the BOM; dry-run unless -Apply is given

.PARAMETER Apply
    With -Mode strip: actually rewrite the file. Without it: print only.

.PARAMETER Backup
    With -Mode strip -Apply: copy to "<file>.bom-backup" first (refuses to overwrite).

.PARAMETER Recurse
    With -Mode scan: recurse into subdirectories.

.PARAMETER Include
    With -Mode scan: filename patterns to test.

.EXAMPLE
    powershell -NoProfile -File bom.ps1 -Path .\package.json
    powershell -NoProfile -File bom.ps1 -Path C:\Users\me\.dsh\profiles -Mode scan -Recurse
    powershell -NoProfile -File bom.ps1 -Path .\package.json -Mode strip -Apply -Backup
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [ValidateSet('check', 'scan', 'strip')]
    [string]$Mode = 'check',

    [switch]$Apply,
    [switch]$Backup,
    [switch]$Recurse,

    [string[]]$Include = @(
        '*.json', '*.jsonc', '*.json5',
        '*.yml', '*.yaml',
        '*.md', '*.txt',
        '*.js', '*.mjs', '*.cjs', '*.ts',
        '*.ps1', '*.psm1', '*.sh',
        '*.csv', '*.env'
    ),

    [string[]]$ExcludeDir = @('node_modules', '.git', '.pnpm', '.cache')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PS7 = ($PSVersionTable.PSVersion.Major -ge 6)

function Read-RawBytes {
    param([string]$File, [int]$TotalCount = 0)
    if ($script:PS7) {
        if ($TotalCount -gt 0) {
            return [byte[]]@(Get-Content -LiteralPath $File -AsByteStream -TotalCount $TotalCount -ErrorAction Stop)
        }
        return [byte[]]@(Get-Content -LiteralPath $File -AsByteStream -ErrorAction Stop)
    }
    if ($TotalCount -gt 0) {
        return [byte[]]@(Get-Content -LiteralPath $File -Encoding Byte -TotalCount $TotalCount -ErrorAction Stop)
    }
    return [byte[]]@(Get-Content -LiteralPath $File -Encoding Byte -ErrorAction Stop)
}

function Write-RawBytes {
    param([string]$File, [byte[]]$Bytes)
    if ($script:PS7) {
        Set-Content -LiteralPath $File -Value $Bytes -AsByteStream -NoNewline -ErrorAction Stop
    }
    else {
        Set-Content -LiteralPath $File -Value $Bytes -Encoding Byte -NoNewline -ErrorAction Stop
    }
}

function Test-BomBytes {
    param([byte[]]$Head)
    return ($Head.Count -ge 3 -and $Head[0] -eq 0xEF -and $Head[1] -eq 0xBB -and $Head[2] -eq 0xBF)
}

function Test-Excluded {
    param([string]$FullName)
    foreach ($dir in $ExcludeDir) {
        if ($FullName -match ('\\' + [regex]::Escape($dir) + '\\')) { return $true }
    }
    return $false
}

try {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
}
catch {
    Write-Error "path not found: $Path"
    exit 2
}

switch ($Mode) {
    'check' {
        if ($item.PSIsContainer) {
            Write-Error "-Mode check expects a file; use -Mode scan for directories"
            exit 2
        }
        if (Test-BomBytes (Read-RawBytes -File $item.FullName -TotalCount 3)) {
            Write-Output "BOM     $($item.FullName)"
            exit 1
        }
        Write-Output "clean   $($item.FullName)"
        exit 0
    }

    'scan' {
        if (-not $item.PSIsContainer) {
            $files = @($item)
        }
        else {
            $files = @(Get-ChildItem -LiteralPath $item.FullName -File -Force -Recurse:$Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $name = $_.Name
                    -not (Test-Excluded $_.FullName) -and
                    (@($Include | Where-Object { $name -like $_ }).Count -gt 0)
                })
        }

        $found = 0
        $tested = 0
        foreach ($f in $files) {
            if ($f.Length -lt 3) { continue }
            $tested++
            try {
                if (Test-BomBytes (Read-RawBytes -File $f.FullName -TotalCount 3)) {
                    Write-Output "BOM     $($f.FullName)"
                    $found++
                }
            }
            catch {
                Write-Warning "unreadable: $($f.FullName)"
            }
        }
        Write-Output "---- tested $tested file(s), $found with BOM"
        if ($found -gt 0) { exit 1 } else { exit 0 }
    }

    'strip' {
        if ($item.PSIsContainer) {
            Write-Error "-Mode strip expects a file"
            exit 2
        }
        $file = $item.FullName
        if (-not (Test-BomBytes (Read-RawBytes -File $file -TotalCount 3))) {
            Write-Output "clean   $file (nothing to do)"
            exit 0
        }

        $bytes = Read-RawBytes -File $file
        if ($bytes.Count -le 3) {
            Write-Error "file holds only a BOM: $file"
            exit 1
        }
        $body = [byte[]]$bytes[3..($bytes.Count - 1)]

        if (-not $Apply) {
            Write-Output "would strip 3 BOM byte(s): $file ($($bytes.Count) -> $($body.Count) bytes)"
            Write-Output "re-run with -Apply to write"
            exit 1
        }

        if ($Backup) {
            # NOTE: do not name this $backup - PowerShell variables are case-insensitive
            # and $Backup is the [switch] parameter; assigning a path would throw.
            $backupPath = "$file.bom-backup"
            if (Test-Path -LiteralPath $backupPath) {
                Write-Error "backup already exists, refusing to overwrite: $backupPath"
                exit 1
            }
            Copy-Item -LiteralPath $file -Destination $backupPath -ErrorAction Stop
            Write-Output "backup  $backupPath"
        }

        Write-RawBytes -File $file -Bytes $body

        if (Test-BomBytes (Read-RawBytes -File $file -TotalCount 3)) {
            Write-Error "strip failed, BOM still present: $file"
            exit 1
        }
        $after = (Get-Item -LiteralPath $file).Length
        Write-Output "stripped $file ($($bytes.Count) -> $after bytes)"
        exit 0
    }
}
