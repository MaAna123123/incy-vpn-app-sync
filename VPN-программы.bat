@echo off
chcp 65001 >nul
setlocal
set "INCY_SYNC_BATCH=%~f0"
set "INCY_SYNC_MODE=%~1"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$batchPath=$env:INCY_SYNC_BATCH; $mode=$env:INCY_SYNC_MODE; $content=Get-Content -LiteralPath $batchPath -Encoding UTF8; $marker=[Array]::IndexOf($content,'# POWERSHELL'); if($marker -lt 0){throw 'PowerShell section not found.'}; $code=$content[($marker+1)..($content.Length-1)] -join [Environment]::NewLine; $block=[ScriptBlock]::Create($code); Invoke-Command -ScriptBlock $block -ArgumentList $batchPath,$mode"

set "INCY_SYNC_EXIT=%ERRORLEVEL%"
if "%~1"=="" (
  echo.
  pause
)
exit /b %INCY_SYNC_EXIT%

# POWERSHELL
param(
    [Parameter(Mandatory = $true)]
    [string] $BatchPath,
    [string] $Mode
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$LocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$RoamingAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
$CommonAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = $LocalAppData }
if (-not $env:APPDATA) { $env:APPDATA = $RoamingAppData }
if (-not $env:ProgramData) { $env:ProgramData = $CommonAppData }

function Get-ConfiguredPath {
    param([string] $EnvironmentName, [string] $DefaultPath)
    $override = [Environment]::GetEnvironmentVariable($EnvironmentName, 'Process')
    if ($override) { return [Environment]::ExpandEnvironmentVariables($override) }
    return [Environment]::ExpandEnvironmentVariables($DefaultPath)
}

$DataRoot = Get-ConfiguredPath 'INCY_SYNC_DATA_ROOT' (Join-Path $LocalAppData 'INCY-VPN-Sync')
$InstallRoot = Get-ConfiguredPath 'INCY_SYNC_INSTALL_ROOT' (Join-Path $CommonAppData 'INCY-VPN-Sync')
$PreferencesPath = Get-ConfiguredPath 'INCY_SYNC_PREFERENCES' (Join-Path $RoamingAppData 'incy\preferences.json')
$IncyExe = Get-ConfiguredPath 'INCY_SYNC_INCY_EXE' (Join-Path $env:ProgramFiles 'INCY\incy.exe')
$PatternsPath = Join-Path $DataRoot 'vpn-patterns.json'
$BackupsRoot = Join-Path $DataRoot 'backups'
$LastSyncPath = Join-Path $DataRoot 'last-sync.json'
$TaskLogPath = Join-Path $InstallRoot 'scheduled-sync.log'

function Write-JsonUtf8 {
    param([string] $Path, [object] $Value)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $Utf8NoBom)
}

function Get-DefaultPatternDocument {
    [ordered]@{
        version = 1
        folders = @(
            [ordered]@{ name = 'Google Chrome'; pattern = '%ProgramFiles%\Google\Chrome'; builtIn = $true }
            [ordered]@{ name = 'Discord'; pattern = '%LOCALAPPDATA%\Discord'; builtIn = $true }
            [ordered]@{ name = 'Codex tools'; pattern = '%LOCALAPPDATA%\OpenAI\Codex'; builtIn = $true }
            [ordered]@{ name = 'ChatGPT / Codex app'; pattern = '%ProgramFiles%\WindowsApps\OpenAI.Codex_*'; builtIn = $true }
        )
    }
}

function Initialize-PatternDocument {
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    if (-not (Test-Path -LiteralPath $PatternsPath -PathType Leaf)) {
        Write-JsonUtf8 $PatternsPath (Get-DefaultPatternDocument)
    }
}

function Read-PatternDocument {
    Initialize-PatternDocument
    $document = Get-Content -Raw -LiteralPath $PatternsPath -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $document.folders) {
        throw "В файле паттернов нет массива folders: $PatternsPath"
    }
    return $document
}

function Resolve-FolderPattern {
    param([string] $Pattern)
    if (-not $Pattern) { return @() }

    $expanded = [Environment]::ExpandEnvironmentVariables($Pattern.Trim().Trim('"'))
    if ([System.IO.Path]::GetExtension($expanded) -ieq '.exe') {
        $expanded = Split-Path -Parent $expanded
    }

    $resolved = @(Get-Item -Path $expanded -ErrorAction SilentlyContinue |
        Where-Object { $_.PSIsContainer } |
        ForEach-Object { $_.FullName })

    if ($expanded -match '\\WindowsApps\\OpenAI\.Codex_\*') {
        $appxOverride = [Environment]::GetEnvironmentVariable('INCY_SYNC_CHATGPT_ROOT', 'Process')
        if ($appxOverride -and (Test-Path -LiteralPath $appxOverride -PathType Container)) {
            $resolved += [IO.Path]::GetFullPath($appxOverride)
        } else {
            $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($package -and $package.InstallLocation -and (Test-Path -LiteralPath $package.InstallLocation -PathType Container)) {
                $resolved += $package.InstallLocation
            } else {
                $runningPath = Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.ExecutablePath } |
                    Where-Object { $_ } |
                    Select-Object -First 1
                if ($runningPath) {
                    $resolved += Split-Path -Parent (Split-Path -Parent $runningPath)
                }
            }
        }
    }

    @($resolved | Sort-Object -Unique)
}

function Get-DiscoveredExecutables {
    param([object] $PatternDocument)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $results = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($PatternDocument.folders)) {
        foreach ($folder in @(Resolve-FolderPattern ([string]$entry.pattern))) {
            Get-ChildItem -LiteralPath $folder -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $fullPath = [System.IO.Path]::GetFullPath($_.FullName)
                    if ($seen.Add($fullPath)) { $results.Add($fullPath) }
                }
        }
    }
    @($results | Sort-Object)
}

function Get-ManagedIncyProcesses {
    $overrideWasSet = [bool][Environment]::GetEnvironmentVariable('INCY_SYNC_INCY_EXE', 'Process')
    $processes = @(Get-Process -Name 'incy' -ErrorAction SilentlyContinue)
    if (-not $overrideWasSet) { return $processes }

    @($processes | Where-Object {
        try { $_.Path -and ([System.IO.Path]::GetFullPath($_.Path) -ieq [System.IO.Path]::GetFullPath($IncyExe)) }
        catch { $false }
    })
}

function Update-IncyPreferences {
    param([string[]] $Executables)

    if (-not (Test-Path -LiteralPath $PreferencesPath -PathType Leaf)) {
        throw "Не найден файл INCY preferences.json: $PreferencesPath"
    }
    if (@($Executables).Count -eq 0) {
        throw 'Не найден ни один EXE. Настройки INCY не изменены.'
    }

    New-Item -ItemType Directory -Force -Path $BackupsRoot | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupPath = Join-Path $BackupsRoot "preferences-$stamp.json"

    $preferences = Get-Content -Raw -LiteralPath $PreferencesPath -Encoding UTF8 | ConvertFrom-Json
    $preferences | Add-Member -NotePropertyName 'perAppProxyEnabled' -NotePropertyValue $true -Force
    $preferences | Add-Member -NotePropertyName 'perAppProxyMode' -NotePropertyValue 'proxy' -Force
    $preferences | Add-Member -NotePropertyName 'perAppProxyApps' -NotePropertyValue @($Executables) -Force

    $tempPath = "$PreferencesPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        Write-JsonUtf8 $tempPath $preferences
        [System.IO.File]::Replace($tempPath, $PreferencesPath, $backupPath)
    } catch {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        if (-not (Test-Path -LiteralPath $PreferencesPath) -and (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $backupPath -Destination $PreferencesPath -Force
        }
        throw
    }
    return $backupPath
}

function Invoke-IncySync {
    $patterns = Read-PatternDocument
    $executables = @(Get-DiscoveredExecutables $patterns)
    $managedProcesses = @(Get-ManagedIncyProcesses)
    $wasRunning = $managedProcesses.Count -gt 0
    $backupPath = Update-IncyPreferences $executables

    $summary = [ordered]@{
        synchronizedAt = (Get-Date).ToString('o')
        executableCount = $executables.Count
        incyWasRunning = $wasRunning
        preferencesPath = $PreferencesPath
        backupPath = $backupPath
        executables = $executables
    }
    Write-JsonUtf8 $LastSyncPath $summary
    return [pscustomobject]$summary
}

$InstalledBatchPath = Join-Path $InstallRoot 'vpn-apps-sync.bat'
$TaskName = 'INCY VPN Application Sync'
$InstallPlanPath = Join-Path $DataRoot 'install-plan.json'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-ElevationIfNeeded {
    if ([Environment]::GetEnvironmentVariable('INCY_SYNC_NO_ELEVATION', 'Process')) { return $true }
    if (Test-IsAdministrator) { return $true }

    $modeArgument = if ($Mode) { " $Mode" } else { '' }
    $arguments = "/d /c `"`"$BatchPath`"$modeArgument`""
    Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -Verb RunAs | Out-Null
    return $false
}

function Get-InstallPlan {
    $taskArguments = "/d /c call `"$InstalledBatchPath`" --sync >> `"$TaskLogPath`" 2>&1"
    [ordered]@{
        taskName = $TaskName
        installedBatchPath = $InstalledBatchPath
        taskExecutable = $env:ComSpec
        taskArguments = $taskArguments
        taskLogPath = $TaskLogPath
        taskWorkingDirectory = $null
        taskRunLevel = 'Highest'
        taskTrigger = 'AtLogOn'
        taskDelay = 'PT0S'
    }
}

function Install-AutomaticSync {
    Initialize-PatternDocument
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    $plan = Get-InstallPlan
    Write-JsonUtf8 $InstallPlanPath $plan

    $sourceFull = [IO.Path]::GetFullPath($BatchPath)
    $targetFull = [IO.Path]::GetFullPath($InstalledBatchPath)
    if ($sourceFull -ine $targetFull) {
        Copy-Item -LiteralPath $BatchPath -Destination $InstalledBatchPath -Force
    }

    if ([Environment]::GetEnvironmentVariable('INCY_SYNC_NO_SCHEDULE', 'Process')) {
        return [pscustomobject]$plan
    }

    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $plan.taskExecutable -Argument $plan.taskArguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    if ($plan.taskDelay -ne 'PT0S') { $trigger.Delay = $plan.taskDelay }
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    return [pscustomobject]$plan
}

function Save-PatternDocument {
    param([object] $Document)
    Write-JsonUtf8 $PatternsPath $Document
}

function Show-AddPatternInstructions {
    Write-Host ''
    Write-Host '=== КАК ДОБАВИТЬ ПРОГРАММУ ===' -ForegroundColor Cyan
    Write-Host '1. Открой папку программы в Проводнике.'
    Write-Host '2. Нажми на адресную строку сверху и скопируй путь: Ctrl+C.'
    Write-Host '3. Вернись в это окно, вставь путь: Ctrl+V, затем нажми Enter.'
    Write-Host ''
    Write-Host 'Что можно вставить:' -ForegroundColor Yellow
    Write-Host '  Папку:       C:\Program Files\Моя программа'
    Write-Host '  Один EXE:    C:\Program Files\Моя программа\program.exe'
    Write-Host '  Шаблон:      C:\Users\Имя\AppData\Local\Моя программа\app-*'
    Write-Host ''
    Write-Host 'Если вставишь EXE, будет добавлена вся его папка.'
    Write-Host 'Все EXE во вложенных папках тоже найдутся автоматически.'
    Write-Host 'Кавычки вокруг пути можно оставить — скрипт сам их уберёт.'
    Write-Host ''
}

function Add-FolderPattern {
    param([string] $Name, [string] $Pattern)

    if (-not $Name -or -not $Pattern) { Show-AddPatternInstructions }
    if (-not $Name) { $Name = Read-Host 'Название приложения (например: Telegram)' }
    if (-not $Pattern) { $Pattern = Read-Host 'Вставь путь к папке, шаблону или EXE' }
    if (-not $Name -or -not $Pattern) { throw 'Название и путь не могут быть пустыми.' }

    $normalized = [Environment]::ExpandEnvironmentVariables($Pattern.Trim().Trim('"'))
    if ([IO.Path]::GetExtension($normalized) -ieq '.exe') {
        $normalized = Split-Path -Parent $normalized
    }
    if (-not $normalized) { throw 'Не удалось определить папку из введённого пути.' }

    $document = Read-PatternDocument
    $folders = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($document.folders)) { $folders.Add($entry) }
    $existing = @($folders | Where-Object { ([string]$_.pattern).TrimEnd('\') -ieq $normalized.TrimEnd('\') }) | Select-Object -First 1
    if ($existing) {
        $existing.name = $Name
    } else {
        $folders.Add([pscustomobject]@{ name = $Name; pattern = $normalized; builtIn = $false })
    }
    $document.folders = $folders.ToArray()
    Save-PatternDocument $document
    return $normalized
}

function Show-FolderPatterns {
    $document = Read-PatternDocument
    Write-Host ''
    Write-Host 'Сохранённые папки и паттерны:' -ForegroundColor Cyan
    for ($index = 0; $index -lt @($document.folders).Count; $index++) {
        $entry = @($document.folders)[$index]
        Write-Host ("{0}. {1}
   {2}" -f ($index + 1), $entry.name, $entry.pattern)
    }
}

function Remove-FolderPattern {
    $document = Read-PatternDocument
    Show-FolderPatterns
    $answer = Read-Host 'Номер для удаления'
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt @($document.folders).Count) {
        throw 'Неверный номер.'
    }
    $kept = for ($index = 0; $index -lt @($document.folders).Count; $index++) {
        if ($index -ne ($number - 1)) { @($document.folders)[$index] }
    }
    $document.folders = @($kept)
    Save-PatternDocument $document
}

function Restore-LatestBackup {
    $backup = Get-ChildItem -LiteralPath $BackupsRoot -Filter 'preferences-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $backup) { throw 'Нет резервных копий для восстановления.' }

    $undoPath = Join-Path $BackupsRoot ("preferences-before-restore-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $tempPath = "$PreferencesPath.restore-$([Guid]::NewGuid().ToString('N'))"
    try {
        Copy-Item -LiteralPath $backup.FullName -Destination $tempPath -Force
        [IO.File]::Replace($tempPath, $PreferencesPath, $undoPath)
    } catch {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        throw
    }
    Write-Host ("Восстановлено: {0}" -f $backup.FullName) -ForegroundColor Green
}

function Show-MainMenuInstructions {
    Write-Host ''
    Write-Host '=== INCY: ПРОГРАММЫ ЧЕРЕЗ VPN ===' -ForegroundColor Cyan
    Write-Host 'При запуске BAT уже проверил сохранённые папки и обновил список EXE.' -ForegroundColor DarkGray
    Write-Host ''

    Write-Host '1. СИНХРОНИЗИРОВАТЬ СЕЙЧАС' -ForegroundColor Yellow
    Write-Host '   Заново ищет все EXE и записывает актуальный список в INCY.'
    Write-Host '   Пример: Discord обновился и установился в новую папку — нажми 1.'
    Write-Host ''

    Write-Host '2. ДОБАВИТЬ ПРОГРАММУ, ПАПКУ ИЛИ EXE' -ForegroundColor Yellow
    Write-Host '   Сохраняет новую папку. Все EXE внутри неё и подпапок будут найдены.'
    Write-Host '   Пример: вставь C:\Users\Имя\AppData\Roaming\Telegram Desktop'
    Write-Host '   После добавления нажми 1, чтобы сразу обновить список INCY.'
    Write-Host ''

    Write-Host '3. ПОКАЗАТЬ СОХРАНЁННЫЕ ПАПКИ' -ForegroundColor Yellow
    Write-Host '   Показывает Chrome, Discord, ChatGPT/Codex и добавленные тобой пути.'
    Write-Host '   Пример: нажми 3, чтобы проверить, сохранён ли Telegram.'
    Write-Host ''

    Write-Host '4. УДАЛИТЬ ПАПКУ ИЗ СПИСКА' -ForegroundColor Yellow
    Write-Host '   Показывает нумерованный список и просит номер записи для удаления.'
    Write-Host '   Пример: программа больше не должна идти через VPN — удали её и нажми 1.'
    Write-Host '   Осторожно: не удаляй Chrome, Discord или ChatGPT/Codex случайно.' -ForegroundColor DarkYellow
    Write-Host ''

    Write-Host '5. ПОЧИНИТЬ АВТОСИНХРОНИЗАЦИЮ' -ForegroundColor Yellow
    Write-Host '   Заново создаёт задачу Windows для обновления списка при входе в систему.'
    Write-Host '   Пример: после переустановки Windows автозапуск не работает — нажми 5.'
    Write-Host '   INCY при этом не выключается и не перезапускается.'
    Write-Host ''

    Write-Host '6. ВОССТАНОВИТЬ РЕЗЕРВНУЮ КОПИЮ' -ForegroundColor Yellow
    Write-Host '   Возвращает настройки INCY, сохранённые перед последней синхронизацией.'
    Write-Host '   Пример: после изменения списка что-то стало не так — нажми 6.'
    Write-Host '   Используй этот пункт как аварийный откат.' -ForegroundColor DarkYellow
    Write-Host ''

    Write-Host '0. ВЫХОД' -ForegroundColor Yellow
    Write-Host '   Закрывает только это окно. INCY и VPN продолжат работать.'
    Write-Host ''
}

function Start-InteractiveMenu {
    $plan = Install-AutomaticSync
    $initial = Invoke-IncySync
    Write-Host ("Готово: {0} EXE. Автосинхронизация установлена." -f $initial.executableCount) -ForegroundColor Green

    while ($true) {
        Show-MainMenuInstructions
        $choice = Read-Host 'Выбор'
        try {
            switch ($choice) {
                '1' { $result = Invoke-IncySync; Write-Host ("Синхронизировано: {0} EXE" -f $result.executableCount) -ForegroundColor Green }
                '2' { $saved = Add-FolderPattern; Write-Host ("Добавлено: {0}" -f $saved) -ForegroundColor Green }
                '3' { Show-FolderPatterns }
                '4' { Remove-FolderPattern; Write-Host 'Удалено.' -ForegroundColor Green }
                '5' { Install-AutomaticSync | Out-Null; Write-Host 'Автосинхронизация переустановлена.' -ForegroundColor Green }
                '6' { Restore-LatestBackup }
                '0' { return }
                default { Write-Warning 'Неизвестный пункт.' }
            }
        } catch {
            Write-Host ("Ошибка: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }
}

switch ($Mode) {
    '--sync' {
        if (-not (Request-ElevationIfNeeded)) { return }
        $result = Invoke-IncySync
        Write-Host ("INCY: синхронизировано EXE: {0}" -f $result.executableCount)
    }
    '--scan' {
        $patterns = Read-PatternDocument
        Get-DiscoveredExecutables $patterns | ForEach-Object { Write-Output $_ }
    }
    '--install-dry-run' {
        Initialize-PatternDocument
        Write-JsonUtf8 $InstallPlanPath (Get-InstallPlan)
    }
    '--add-pattern' {
        $name = [Environment]::GetEnvironmentVariable('INCY_SYNC_INPUT_NAME', 'Process')
        $pattern = [Environment]::GetEnvironmentVariable('INCY_SYNC_INPUT_PATTERN', 'Process')
        Add-FolderPattern $name $pattern | Out-Null
    }
    '--install' {
        if (-not (Request-ElevationIfNeeded)) { return }
        Install-AutomaticSync | Out-Null
        $result = Invoke-IncySync
        Write-Host ("Гото: {0} EXE, автосинхронизация установлена." -f $result.executableCount) -ForegroundColor Green
    }
    default {
        if (-not (Request-ElevationIfNeeded)) { return }
        Start-InteractiveMenu
    }
}
