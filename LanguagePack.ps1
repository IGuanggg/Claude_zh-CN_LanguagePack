param(
    [switch]$PauseAtEnd,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Info {
    param([string]$Message)
    Write-Host "[Claude Chinese Pack] $Message"
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return New-Object psobject
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return New-Object psobject
    }
    return $raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $Utf8NoBom)
}

function Set-JsonProperty {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    $json = Read-JsonFile -Path $Path
    if (-not ($json.PSObject.Properties.Name -contains $Name)) {
        $json | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $json.$Name = $Value
    }
    Write-JsonFile -Path $Path -Value $json
}

function Backup-Once {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $backup = "$Path.bak"
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $Path -Destination $backup -Force
            Write-Info "Backup created: $backup"
        }
    }
}

function Restore-Backup {
    param([string]$Path)
    $backup = "$Path.bak"
    if (Test-Path -LiteralPath $backup) {
        Copy-Item -LiteralPath $backup -Destination $Path -Force
        Write-Info "Restored backup: $Path"
        return $true
    }
    return $false
}

function Resolve-PackFile {
    param(
        [string]$RelativePath,
        [string]$FallbackPath
    )
    $path = Join-Path $PSScriptRoot $RelativePath
    if (Test-Path -LiteralPath $path) {
        return $path
    }
    if ($FallbackPath -and (Test-Path -LiteralPath $FallbackPath)) {
        return $FallbackPath
    }

    $rawBase = "https://raw.githubusercontent.com/pheohu-42/Claude_zh-CN_LanguagePack/master"
    $urlPath = $RelativePath -replace "\\", "/"
    $url = "$rawBase/$urlPath"
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    Write-Info "Downloading missing language pack file: $urlPath"
    try {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
    } catch {
        throw "Missing language pack file and download failed: $path"
    }

    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing language pack file: $path"
    }
    return $path
}

function Get-LatestClaudeApp {
    $root = Join-Path $env:LOCALAPPDATA "AnthropicClaude"
    if (-not (Test-Path -LiteralPath $root)) {
        throw "Claude install directory was not found: $root"
    }

    $apps = Get-ChildItem -LiteralPath $root -Directory -Filter "app-*" |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "resources") } |
        Sort-Object -Property @{ Expression = {
            try { [version]($_.Name -replace "^app-", "") } catch { [version]"0.0.0" }
        }; Descending = $true }

    if (-not $apps -or $apps.Count -eq 0) {
        throw "Claude app-* version directory was not found."
    }
    return $apps[0]
}

function Stop-Claude {
    $processes = Get-Process -Name "claude" -ErrorAction SilentlyContinue
    if (-not $processes) {
        return
    }

    Write-Info "Claude is running; closing it before applying the language pack..."
    foreach ($process in $processes) {
        try {
            if ($process.MainWindowHandle -ne 0) {
                [void]$process.CloseMainWindow()
            }
        } catch {}
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        $processes = Get-Process -Name "claude" -ErrorAction SilentlyContinue
        if (-not $processes) {
            return
        }
        foreach ($process in $processes) {
            try {
                Stop-Process -Id $process.Id -Force
            } catch {}
        }
    }

    $processes = Get-Process -Name "claude" -ErrorAction SilentlyContinue
    if ($processes) {
        throw "Claude processes are still running. Please close Claude manually and run the installer again."
    }
}

function Patch-IonLanguageList {
    param([string]$ResourcesPath)
    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    if (-not (Test-Path -LiteralPath $assetsDir)) {
        throw "Missing ion assets directory: $assetsDir"
    }

    $jsFiles = Get-ChildItem -LiteralPath $assetsDir -Filter "index-*.js" -File -ErrorAction SilentlyContinue
    if (-not $jsFiles) {
        throw "No index-*.js file was found in: $assetsDir"
    }

    foreach ($jsFile in $jsFiles) {
        $content = [System.IO.File]::ReadAllText($jsFile.FullName, [System.Text.Encoding]::UTF8)
        if ($content.Contains('"zh-CN"')) {
            Write-Info "zh-CN is already registered in $($jsFile.Name)."
            continue
        }

        Backup-Once -Path $jsFile.FullName
        $regex = [regex]'((?:\w+)=\["en-US"(?:,"[^"]+")+\]?)'
        $patched = $regex.Replace($content, { param($m) $m.Groups[1].Value.TrimEnd(']') + ',"zh-CN"]' }, 1)
        if ($patched -eq $content) {
            throw "Could not find Claude language list in $($jsFile.Name)."
        }

        [System.IO.File]::WriteAllText($jsFile.FullName, $patched, $Utf8NoBom)
        Write-Info "Registered zh-CN in $($jsFile.Name)."
    }
}

function Restore-IonLanguageList {
    param([string]$ResourcesPath)
    $assetsDir = Join-Path $ResourcesPath "ion-dist\assets\v1"
    if (-not (Test-Path -LiteralPath $assetsDir)) {
        return
    }

    $jsFiles = Get-ChildItem -LiteralPath $assetsDir -Filter "index-*.js" -File -ErrorAction SilentlyContinue
    foreach ($jsFile in $jsFiles) {
        if (Restore-Backup -Path $jsFile.FullName) {
            continue
        }

        $content = [System.IO.File]::ReadAllText($jsFile.FullName, [System.Text.Encoding]::UTF8)
        if (-not $content.Contains('"zh-CN"')) {
            continue
        }

        $patched = $content -replace ',"zh-CN"', ''
        [System.IO.File]::WriteAllText($jsFile.FullName, $patched, $Utf8NoBom)
        Write-Info "Removed zh-CN registration from $($jsFile.Name)."
    }
}

try {
    $legacyLanguageFile = Join-Path $PSScriptRoot "zh-CN.json"
    $desktopShellLanguageFile = Resolve-PackFile -RelativePath "translated-zh-CN\desktop-shell\zh-CN.json" -FallbackPath $legacyLanguageFile
    $ionLanguageFile = Resolve-PackFile -RelativePath "translated-zh-CN\ion-dist\zh-CN.json" -FallbackPath $null
    $statsigLanguageFile = Resolve-PackFile -RelativePath "translated-zh-CN\statsig\zh-CN.json" -FallbackPath $null

    foreach ($file in @($desktopShellLanguageFile, $ionLanguageFile, $statsigLanguageFile)) {
        $languageJson = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        [void]($languageJson | ConvertFrom-Json)
    }

    $app = Get-LatestClaudeApp
    $resources = Join-Path $app.FullName "resources"
    $targetLanguageFile = Join-Path $resources "zh-CN.json"
    $englishLanguageFile = Join-Path $resources "en-US.json"
    $ionTargetLanguageFile = Join-Path $resources "ion-dist\i18n\zh-CN.json"
    $statsigTargetLanguageFile = Join-Path $resources "ion-dist\i18n\statsig\zh-CN.json"
    $configFile = Join-Path $env:APPDATA "Claude\config.json"

    Write-Info "Claude version directory: $($app.FullName)"
    Stop-Claude

    Backup-Once -Path $configFile
    Backup-Once -Path $englishLanguageFile

    if ($Restore) {
        [void](Restore-Backup -Path $englishLanguageFile)
        Restore-IonLanguageList -ResourcesPath $resources
        Remove-Item -LiteralPath $targetLanguageFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ionTargetLanguageFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $statsigTargetLanguageFile -Force -ErrorAction SilentlyContinue
        Set-JsonProperty -Path $configFile -Name "locale" -Value "en-US"
        Write-Info "Claude locale was restored to en-US."
    } else {
        [void](Restore-Backup -Path $englishLanguageFile)
        Copy-Item -LiteralPath $desktopShellLanguageFile -Destination $targetLanguageFile -Force
        Copy-Item -LiteralPath $ionLanguageFile -Destination $ionTargetLanguageFile -Force
        Copy-Item -LiteralPath $statsigLanguageFile -Destination $statsigTargetLanguageFile -Force
        Write-Info "Installed desktop shell language pack: $targetLanguageFile"
        Write-Info "Installed app language pack: $ionTargetLanguageFile"
        Write-Info "Installed statsig language pack: $statsigTargetLanguageFile"
        Patch-IonLanguageList -ResourcesPath $resources
        Set-JsonProperty -Path $configFile -Name "locale" -Value "zh-CN"
        Write-Info "Claude locale was set to zh-CN."
    }

    $launcher = Join-Path (Split-Path -Parent $app.FullName) "claude.exe"
    if (Test-Path -LiteralPath $launcher) {
        Start-Process -FilePath $launcher
        Write-Info "Claude was restarted."
    } else {
        Write-Info "Launcher was not found. Please start Claude manually."
    }

    Write-Info "Done. If Claude returns to English after an update, run this installer again."
    exit 0
} catch {
    Write-Host ""
    Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($PauseAtEnd) {
        Write-Host ""
        Read-Host "Press Enter to exit"
    }
}
