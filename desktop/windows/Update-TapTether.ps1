# User-scoped TapTether Windows updater, launched only after an authenticated
# and explicitly confirmed request. Downloads the fixed GitHub release asset
# and checks its published SHA-256 before replacing a user-owned executable.
$ErrorActionPreference = 'Stop'
$agentDir = Join-Path $env:LOCALAPPDATA 'TapTether'
$currentExe = Join-Path $agentDir 'TapTetherAgent.exe'
$currentVersionFile = Join-Path $agentDir 'version.txt'
if (!(Test-Path $currentExe -PathType Leaf)) { throw 'TapTether is not installed.' }

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
switch ($architecture.ToLowerInvariant()) {
    'x64' {$arch='amd64'}
    'arm64' {$arch='arm64'}
    default {throw 'Unsupported Windows architecture.'}
}
$assetName = 'TapTetherAgent-Windows-' + $arch + '.zip'
$repo = 'ssnanda/taptether.com'
$installed = if (Test-Path $currentVersionFile) { (Get-Content $currentVersionFile -Raw).Trim() } else { '0.0.0+0' }
function VersionParts([string]$value) {
    if ($value -cnotmatch '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') {throw 'Invalid agent version.'}
    return @([int]$Matches[1],[int]$Matches[2],[int]$Matches[3],[int]$Matches[4])
}
function CompareVersions([string]$a, [string]$b) {
    $left = VersionParts $a
    $right = VersionParts $b
    for ($i=0; $i -lt 4; $i++) {
        if ($left[$i] -gt $right[$i]) {return 1}
        if ($left[$i] -lt $right[$i]) {return -1}
    }
    return 0
}
function ValidatedRelease([string]$tag) {
    $uri = 'https://api.github.com/repos/' + $repo + '/releases/tags/' + $tag
    $release = Invoke-RestMethod -Uri $uri -TimeoutSec 20 -Headers @{ 'User-Agent'='TapTether-Windows-Updater'; 'Accept'='application/vnd.github+json' }
    if ($release.tag_name -cne $tag) {throw 'GitHub release tag mismatch.'}
    if ($release.name -cnotmatch '^TapTether(?: Windows)? (\d+\.\d+\.\d+\+\d+)(?:\s|$)') {
        throw ('Invalid ' + $tag + ' release title.')
    }
    $version = $Matches[1]
    $files = @($release.assets | Where-Object { $_.name -ceq $assetName })
    if ($files.Count -ne 1) {throw ('Missing Windows asset in ' + $tag)}
    if ($files[0].digest -cnotmatch '^sha256:([a-fA-F0-9]{64})$') {throw 'SHA-256 digest missing.'}
    $digest = $Matches[1].ToUpperInvariant()
    $url = 'https://github.com/' + $repo + '/releases/download/' + $tag + '/' + $assetName
    if ($files[0].browser_download_url -cne $url) {throw 'Unexpected agent release URL.'}
    return [pscustomobject]@{ Version=$version; Digest=$digest; Url=$url; Tag=$tag }
}
$candidates = [System.Collections.Generic.List[object]]::new()
$candidates.Add((ValidatedRelease 'current'))
try {
    $candidates.Add((ValidatedRelease 'windows-current'))
} catch {
    # Only 404 is an optional missing rolling feed. Anything else is a
    # validation/network error and must not cause an unverified fallback.
    $response = $_.Exception.Response
    if ($null -eq $response -or [int]$response.StatusCode -ne 404) {throw}
}
$selected = $candidates[0]
foreach ($candidate in $candidates) {
    if ((CompareVersions $candidate.Version $selected.Version) -gt 0) {
        $selected = $candidate
    }
}
if ((CompareVersions $selected.Version $installed) -le 0) {exit 0}
$latest = $selected.Version
$expected = $selected.Digest
$url = $selected.Url
$work = Join-Path $env:TEMP ('TapTetherUpdate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $archive = Join-Path $work 'agent.zip'
    Invoke-WebRequest -Uri $url -OutFile $archive -TimeoutSec 180
    if ((Get-FileHash -Path $archive -Algorithm SHA256).Hash -cne $expected) {
        throw 'Release checksum mismatch. Aborting update.'
    }
    $unpacked = Join-Path $work 'verified'
    Expand-Archive -Path $archive -DestinationPath $unpacked
    $payloadVersion = (Get-Content (Join-Path $unpacked 'version.txt') -Raw).Trim()
    if ($payloadVersion -cne $latest) { throw 'Archive version does not match release.' }
    foreach ($name in @('TapTetherAgent.exe','Install-TapTether.ps1',
            'Allow-TapTether.ps1','Show-Pairing.ps1','Update-TapTether.ps1',
            'Install-TapTether.cmd','Show-Pairing.cmd',
            'Configure-Shutdown.ps1','Configure-Shutdown.cmd',
            'TapTetherTray.ps1','TapTether.ico','README-Windows.txt',
            'version.txt')) {
        if (!(Test-Path (Join-Path $unpacked $name) -PathType Leaf)) {
            throw ('Required ZIP file missing: ' + $name)
        }
    }
    # The updater is a separate PowerShell process, so it survives stopping
    # its own Go agent. Never touch another executable or pairing identity.
    Get-CimInstance Win32_Process -Filter "Name='TapTetherAgent.exe'" |
        Where-Object { $_.ExecutablePath -eq $currentExe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
    Copy-Item (Join-Path $unpacked 'TapTetherAgent.exe') $currentExe -Force
    foreach ($name in @('Install-TapTether.ps1','Allow-TapTether.ps1',
            'Show-Pairing.ps1','Update-TapTether.ps1',
            'Install-TapTether.cmd','Show-Pairing.cmd',
            'Configure-Shutdown.ps1','Configure-Shutdown.cmd',
            'TapTetherTray.ps1','TapTether.ico','README-Windows.txt','version.txt')) {
        Copy-Item (Join-Path $unpacked $name) (Join-Path $agentDir $name) -Force
    }
    Start-Process -FilePath $currentExe -WindowStyle Hidden
    $trayPath = Join-Path $agentDir 'TapTetherTray.ps1'
    $trayArgs = '-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $trayPath + '"'
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-ItemProperty -Path $runKey -Name 'TapTetherTray' -Value ('"powershell.exe" ' + $trayArgs) -PropertyType String -Force | Out-Null
    Start-Process -FilePath 'powershell.exe' -ArgumentList $trayArgs -WindowStyle Hidden
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
