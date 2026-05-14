param(
    [switch]$PauseAtEnd,
    [switch]$Restore
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:ClaudeWritableCopyPath = $null

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

function Get-ClaudeAppVersion {
    param([string]$Path)

    $name = Split-Path -Leaf $Path
    if ($name -match "^app-(.+)$") {
        try { return [version]$Matches[1] } catch { return [version]"0.0.0" }
    }

    $parent = Split-Path -Parent $Path
    $packageName = Split-Path -Leaf $parent
    if ($packageName -match "^Claude_(.+?)_") {
        try { return [version]$Matches[1] } catch { return [version]"0.0.0" }
    }

    return [version]"0.0.0"
}

function Test-ClaudeProtectedAppPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        $fullPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        $fullPath = [Environment]::ExpandEnvironmentVariables($Path)
    }

    return $fullPath -match "\\WindowsApps\\Claude_"
}

function Add-ClaudeAppCandidate {
    param(
        [System.Collections.ArrayList]$Candidates,
        [string]$Path
    )

    if (-not $Path) {
        return
    }

    $resources = Join-Path $Path "resources"
    if (-not (Test-Path -LiteralPath $resources)) {
        return
    }

    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    if (Test-ClaudeProtectedAppPath -Path $fullPath) {
        return
    }

    if ($Candidates | Where-Object { $_.FullName -eq $fullPath }) {
        return
    }

    [void]$Candidates.Add([pscustomobject]@{
        FullName = $fullPath
        Name = Split-Path -Leaf $fullPath
        Version = Get-ClaudeAppVersion -Path $fullPath
    })
}

function Add-ClaudeAppCandidatesFromPath {
    param(
        [System.Collections.ArrayList]$Candidates,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim('"'))
    if (-not (Test-Path -LiteralPath $expandedPath)) {
        return
    }

    $item = Get-Item -LiteralPath $expandedPath -ErrorAction SilentlyContinue
    if (-not $item) {
        return
    }

    if (-not $item.PSIsContainer) {
        $expandedPath = $item.DirectoryName
    }

    if ((Split-Path -Leaf $expandedPath) -eq "resources") {
        Add-ClaudeAppCandidate -Candidates $Candidates -Path (Split-Path -Parent $expandedPath)
        return
    }

    Add-ClaudeAppCandidate -Candidates $Candidates -Path $expandedPath
    Add-ClaudeAppCandidate -Candidates $Candidates -Path (Join-Path $expandedPath "app")

    $versionDirs = Get-ChildItem -LiteralPath $expandedPath -Directory -Filter "app-*" -ErrorAction SilentlyContinue
    foreach ($versionDir in $versionDirs) {
        Add-ClaudeAppCandidate -Candidates $Candidates -Path $versionDir.FullName
    }
}

function Get-ClaudeExecutablePathsFromShortcut {
    $paths = @()
    $shortcutRoots = @(
        [Environment]::GetFolderPath("StartMenu"),
        [Environment]::GetFolderPath("CommonStartMenu"),
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("CommonDesktopDirectory")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    if (-not $shortcutRoots -or $shortcutRoots.Count -eq 0) {
        return $paths
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
    } catch {
        return $paths
    }

    foreach ($root in $shortcutRoots) {
        $shortcuts = Get-ChildItem -LiteralPath $root -Recurse -Filter "*Claude*.lnk" -File -ErrorAction SilentlyContinue
        foreach ($shortcutFile in $shortcuts) {
            try {
                $shortcut = $shell.CreateShortcut($shortcutFile.FullName)
                if ($shortcut.TargetPath) {
                    $paths += $shortcut.TargetPath
                }
                if ($shortcut.WorkingDirectory) {
                    $paths += $shortcut.WorkingDirectory
                }
            } catch {}
        }
    }

    return $paths
}

function Get-ClaudePathsFromRegistry {
    $paths = @()
    $registryRoots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($registryRoot in $registryRoots) {
        $apps = Get-ItemProperty -Path $registryRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Claude*" -or $_.Publisher -like "*Anthropic*" }

        foreach ($app in $apps) {
            if ($app.InstallLocation) {
                $paths += $app.InstallLocation
            }
            if ($app.DisplayIcon -match '"([^"]+\.exe)"|([A-Za-z]:\\[^,]+\.exe)') {
                if ($Matches[1]) {
                    $paths += $Matches[1]
                } elseif ($Matches[2]) {
                    $paths += $Matches[2]
                }
            }
            if ($app.UninstallString -match '"([^"]+\.exe)"|([A-Za-z]:\\[^\s]+\.exe)') {
                if ($Matches[1]) {
                    $paths += $Matches[1]
                } elseif ($Matches[2]) {
                    $paths += $Matches[2]
                }
            }
        }
    }

    return $paths
}

function Get-ClaudePathsFromProcess {
    $paths = @()
    try {
        $processes = Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" -ErrorAction SilentlyContinue
        foreach ($process in $processes) {
            if ($process.ExecutablePath) {
                $paths += $process.ExecutablePath
            }
        }
    } catch {
        $processes = Get-Process -Name "claude" -ErrorAction SilentlyContinue
        foreach ($process in $processes) {
            try {
                if ($process.Path) {
                    $paths += $process.Path
                }
            } catch {}
        }
    }

    return $paths
}

function Get-ClaudePathsFromCommand {
    $paths = @()
    $commands = Get-Command "claude.exe" -ErrorAction SilentlyContinue
    foreach ($command in $commands) {
        if ($command.Source) {
            $paths += $command.Source
        }
    }
    return $paths
}

function Get-ClaudeInstallRoots {
    $roots = @()

    if ($env:CLAUDE_INSTALL_DIR) {
        $roots += [Environment]::ExpandEnvironmentVariables($env:CLAUDE_INSTALL_DIR)
    }
    if ($env:LOCALAPPDATA) {
        $roots += Join-Path $env:LOCALAPPDATA "AnthropicClaude"
        $roots += Join-Path $env:LOCALAPPDATA "Programs\Claude"
    }
    if ($env:ProgramFiles) {
        $roots += Join-Path $env:ProgramFiles "Claude"
    }
    if (${env:ProgramFiles(x86)}) {
        $roots += Join-Path ${env:ProgramFiles(x86)} "Claude"
    }

    return $roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

function Get-ClaudeSearchRoots {
    $roots = @()

    if ($env:LOCALAPPDATA) {
        $roots += $env:LOCALAPPDATA
    }
    if ($env:ProgramFiles) {
        $roots += $env:ProgramFiles
    }
    if (${env:ProgramFiles(x86)}) {
        $roots += ${env:ProgramFiles(x86)}
    }

    return $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
}

function Get-ClaudeWritableCopyRoot {
    if (-not $env:LOCALAPPDATA) {
        throw "LOCALAPPDATA is not available; cannot create a writable Claude copy."
    }

    return Join-Path $env:LOCALAPPDATA "ClaudeChinesePack\MSIXCopy"
}

function Get-ClaudeMsixAppPaths {
    $paths = @()

    foreach ($install in Get-ClaudeMsixInstalls) {
        Add-ClaudeAppCandidatePath -Paths ([ref]$paths) -Path $install
        Add-ClaudeAppCandidatePath -Paths ([ref]$paths) -Path (Join-Path $install "app")
    }

    return $paths | Where-Object { $_ } | Select-Object -Unique
}

function Add-ClaudeAppCandidatePath {
    param(
        [ref]$Paths,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Path "resources"))) {
        return
    }

    $Paths.Value += (Resolve-Path -LiteralPath $Path).Path
}

function Copy-ClaudeMsixAppToWritablePath {
    param([string]$SourceAppPath)

    if (-not (Test-Path -LiteralPath (Join-Path $SourceAppPath "resources"))) {
        throw "MSIX Claude app resources directory was not found: $SourceAppPath"
    }

    $version = Get-ClaudeAppVersion -Path $SourceAppPath
    $copyRoot = Get-ClaudeWritableCopyRoot
    $targetAppPath = Join-Path $copyRoot "app-$version"
    $targetResources = Join-Path $targetAppPath "resources"
    $targetEnglish = Join-Path $targetResources "en-US.json"

    if (Test-Path -LiteralPath $targetEnglish) {
        Write-Info "Using existing writable Claude copy: $targetAppPath"
        $script:ClaudeWritableCopyPath = $targetAppPath
        return $targetAppPath
    }

    if (Test-Path -LiteralPath $targetAppPath) {
        $resolvedTarget = (Resolve-Path -LiteralPath $targetAppPath).Path
        $resolvedRoot = if (Test-Path -LiteralPath $copyRoot) { (Resolve-Path -LiteralPath $copyRoot).Path } else { $copyRoot }
        if (-not $resolvedTarget.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected copy target: $resolvedTarget"
        }
        Remove-Item -LiteralPath $targetAppPath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $targetAppPath -Force | Out-Null
    Write-Info "Copying protected MSIX Claude app to writable path: $targetAppPath"

    $robocopy = Join-Path $env:SystemRoot "System32\robocopy.exe"
    if (Test-Path -LiteralPath $robocopy) {
        & $robocopy $SourceAppPath $targetAppPath /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "Failed to copy MSIX Claude app with robocopy. Exit code: $LASTEXITCODE"
        }
    } else {
        Copy-Item -Path (Join-Path $SourceAppPath "*") -Destination $targetAppPath -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath $targetEnglish)) {
        throw "Writable Claude copy was created, but resources\en-US.json was not found: $targetAppPath"
    }

    [System.IO.File]::WriteAllText((Join-Path $copyRoot "source.txt"), $SourceAppPath + [Environment]::NewLine, $Utf8NoBom)
    $script:ClaudeWritableCopyPath = $targetAppPath
    return $targetAppPath
}

function Find-ClaudeLauncher {
    param([string]$AppPath)

    $launcherCandidates = @(
        (Join-Path (Split-Path -Parent $AppPath) "claude.exe"),
        (Join-Path $AppPath "claude.exe"),
        (Join-Path $AppPath "Claude.exe")
    )

    foreach ($launcher in $launcherCandidates) {
        if (Test-Path -LiteralPath $launcher) {
            return $launcher
        }
    }

    return $null
}

function Install-ClaudeWritableCopyShortcut {
    param([string]$AppPath)

    $launcher = Find-ClaudeLauncher -AppPath $AppPath
    if (-not $launcher) {
        Write-Info "Writable copy launcher was not found. Please start Claude manually from: $AppPath"
        return
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $desktop = [Environment]::GetFolderPath("Desktop")
        if ($desktop) {
            $shortcutPath = Join-Path $desktop "Claude Chinese.lnk"
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $launcher
            $shortcut.WorkingDirectory = Split-Path -Parent $launcher
            $shortcut.IconLocation = "$launcher,0"
            $shortcut.Save()
            Write-Info "Desktop shortcut created: $shortcutPath"
        }

        $startMenu = [Environment]::GetFolderPath("StartMenu")
        if ($startMenu) {
            $programs = Join-Path $startMenu "Programs"
            $shortcutPath = Join-Path $programs "Claude Chinese.lnk"
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $launcher
            $shortcut.WorkingDirectory = Split-Path -Parent $launcher
            $shortcut.IconLocation = "$launcher,0"
            $shortcut.Save()
            Write-Info "Start menu shortcut created: $shortcutPath"
        }
    } catch {
        Write-Info "Shortcut creation failed. You can start Claude from: $launcher"
    }
}

function Search-ClaudeAppsInRoot {
    param(
        [System.Collections.ArrayList]$Candidates,
        [string]$Root,
        [int]$MaxDepth = 4
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $rootPath; Depth = 0 })

    while ($queue.Count -gt 0) {
        $entry = $queue.Dequeue()
        if ($entry.Depth -gt $MaxDepth) {
            continue
        }

        if ((Split-Path -Leaf $entry.Path) -eq "resources") {
            Add-ClaudeAppCandidate -Candidates $Candidates -Path (Split-Path -Parent $entry.Path)
            continue
        }

        if ($entry.Depth -eq $MaxDepth) {
            continue
        }

        $children = Get-ChildItem -LiteralPath $entry.Path -Directory -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            $childName = $child.Name
            if ($childName -like "*Claude*" -or $childName -like "app-*" -or $childName -eq "resources" -or $entry.Path -like "*Claude*") {
                $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $entry.Depth + 1 })
            }
        }
    }
}

function Get-ClaudeMsixInstalls {
    $installs = @()

    try {
        $packages = Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq "Claude" -or
                $_.Name -like "Anthropic.Claude*" -or
                $_.PackageFamilyName -like "Claude_*"
            }

        foreach ($package in $packages) {
            if ($package.InstallLocation) {
                $installs += $package.InstallLocation
            }
        }
    } catch {}

    if ($env:LOCALAPPDATA) {
        $packageRoot = Join-Path $env:LOCALAPPDATA "Packages\Claude_pzs8sxrjxfjjc"
        if (Test-Path -LiteralPath $packageRoot) {
            $installs += $packageRoot
        }
    }

    return $installs | Where-Object { $_ } | Select-Object -Unique
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
    $candidates = New-Object System.Collections.ArrayList
    $searchedRoots = @()

    $discoveredPaths = @()
    $discoveredPaths += Get-ClaudePathsFromProcess
    $discoveredPaths += Get-ClaudeExecutablePathsFromShortcut
    $discoveredPaths += Get-ClaudePathsFromRegistry
    $discoveredPaths += Get-ClaudePathsFromCommand

    foreach ($path in ($discoveredPaths | Where-Object { $_ } | Select-Object -Unique)) {
        Add-ClaudeAppCandidatesFromPath -Candidates $candidates -Path $path
    }

    foreach ($root in Get-ClaudeInstallRoots) {
        $searchedRoots += $root
        Add-ClaudeAppCandidatesFromPath -Candidates $candidates -Path $root
    }

    if ($candidates.Count -eq 0) {
        foreach ($root in Get-ClaudeSearchRoots) {
            $searchedRoots += "$root (limited search)"
            Search-ClaudeAppsInRoot -Candidates $candidates -Root $root
        }
    }

    if ($candidates.Count -eq 0) {
        $msixAppPaths = Get-ClaudeMsixAppPaths | Where-Object { Test-ClaudeProtectedAppPath -Path $_ }
        if ($msixAppPaths -and $msixAppPaths.Count -gt 0) {
            $copyAppPath = Copy-ClaudeMsixAppToWritablePath -SourceAppPath $msixAppPaths[0]
            Add-ClaudeAppCandidate -Candidates $candidates -Path $copyAppPath
        }
    }

    $apps = $candidates | Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true }

    if (-not $apps -or $apps.Count -eq 0) {
        $msixInstalls = Get-ClaudeMsixInstalls
        if ($msixInstalls -and $msixInstalls.Count -gt 0) {
            $msixText = $msixInstalls -join "; "
            throw "Writable Claude resources directory was not found. Detected MSIX/Store Claude installation: $msixText. This language pack can patch the classic Squirrel install only, because MSIX app resources are protected by Windows. Install the classic Claude Desktop build, or set CLAUDE_INSTALL_DIR to a writable Claude app directory that contains a resources folder."
        }

        $searchedText = $searchedRoots -join "; "
        throw "Claude install directory was not found. Searched: $searchedText. If Claude is installed in a custom location, set CLAUDE_INSTALL_DIR to the Claude app directory that contains resources."
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

    if ($script:ClaudeWritableCopyPath) {
        Install-ClaudeWritableCopyShortcut -AppPath $script:ClaudeWritableCopyPath
    }

    $launcher = Find-ClaudeLauncher -AppPath $app.FullName
    if ($launcher -and (Test-Path -LiteralPath $launcher)) {
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
