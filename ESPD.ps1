# ESPD Proxy Service PowerShell Version - User Login Check Only

param(
    [string]$UserNames = "",
    [string]$Proxy = "10.0.66.52:3128",
    [string]$Override = "192.168.*.*;192.25.*.*;<local>",
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Test,
    [switch]$Service,
    [switch]$Help
)

$ServiceName = "ESPDProxyService"
$ServiceDescription = "ESPD Proxy Configuration Service (User Login Check)"
$LogFileName = "espdproxy.log"
$LogPath = Join-Path $env:TEMP $LogFileName
$MaxLogSize = 15MB
$CheckInterval = 60 # seconds

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Add-Content -Path $LogPath -Value $logMessage -ErrorAction SilentlyContinue
    Write-Host $logMessage
}

function Initialize-Log {
    if (Test-Path $LogPath) {
        $fileSize = (Get-Item $LogPath).Length
        if ($fileSize -gt $MaxLogSize) {
            Remove-Item $LogPath -Force
            Write-Log "Log file exceeded 15MB, created new one"
        }
    }
}

function Get-CurrentUsername {
    return $env:USERNAME
}

function Test-UserCondition {
    $currentUser = Get-CurrentUsername
    Write-Log ("Current username: {0}" -f $currentUser)
    
    if ([string]::IsNullOrEmpty($UserNames)) {
        Write-Log "No usernames specified for checking"
        return $false
    }
    
    $allowedUsers = $UserNames -split ',' | ForEach-Object { $_.Trim() }
    Write-Log ("Allowed usernames: {0}" -f ($allowedUsers -join ', '))
    
    foreach ($allowedUser in $allowedUsers) {
        if ($currentUser -eq $allowedUser) {
            Write-Log ("Username match found: {0} = {1}" -f $currentUser, $allowedUser)
            return $true
        }
    }
    
    Write-Log ("No username match found. Current user: {0}, Allowed: {1}" -f $currentUser, ($allowedUsers -join ', '))
    return $false
}

function Get-CurrentProxySettings {
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $proxyEnable = Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction SilentlyContinue
        $proxyServer = Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue
        
        $enabled = if ($proxyEnable) { $proxyEnable.ProxyEnable -eq 1 } else { $false }
        $server = if ($proxyServer) { $proxyServer.ProxyServer } else { "" }
        
        return $enabled, $server
    }
    catch {
        Write-Log ("Error reading proxy settings: {0}" -f $_.Exception.Message)
        return $false, ""
    }
}

function Set-Proxy {
    param([bool]$Enable)
    
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        
        if ($Enable) {
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1
            Set-ItemProperty -Path $regPath -Name ProxyServer -Value $Proxy
            Set-ItemProperty -Path $regPath -Name ProxyOverride -Value $Override
            Write-Log ("Proxy enabled: {0} → USING PROXY CONNECTION" -f $Proxy)
        }
        else {
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
            Write-Log "Proxy disabled → switched to DIRECT connection"
        }
        
        rundll32 user32.dll,UpdatePerUserSystemParameters
        return $true
    }
    catch {
        Write-Log ("Error setting proxy: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Test-ProxyHost {
    param(
        [string]$ProxyHost = "10.0.66.52",
        [int]$Count = 2,
        [int]$Timeout = 1000
    )

    try {
        $result = Test-Connection -ComputerName $ProxyHost -Count $Count -Quiet -ErrorAction SilentlyContinue -TimeoutSeconds ($Timeout/1000)
        if ($result) {
            Write-Log ("Proxy host {0} is reachable (ping ok)" -f $ProxyHost)
            return $true
        }
        else {
            Write-Log ("Proxy host {0} is NOT reachable (ping fail)" -f $ProxyHost)
            return $false
        }
    }
    catch {
        Write-Log ("Error pinging proxy host {0}: {1}" -f $ProxyHost, $_.Exception.Message)
        return $false
    }
}

function Test-ProxySetting {
    Write-Host "=== ESPD Proxy Service - User Login Check ===" -ForegroundColor Cyan
    Write-Host ""
    
    $proxyParts = $Proxy -split ":"
    $proxyHost = $proxyParts[0]

    $hostAvailable = Test-ProxyHost -ProxyHost $proxyHost

    if (-not $hostAvailable) {
        Write-Host ("✗ Proxy host {0} is not reachable" -f $proxyHost) -ForegroundColor Red
        Write-Host "Result: WOULD DISABLE PROXY → WOULD SWITCH TO DIRECT CONNECTION" -ForegroundColor Red
        Write-Log "Final decision: Proxy DISABLED (host unreachable)"
        return
    }

    $currentUser = Get-CurrentUsername
    Write-Host ("Current username: {0}" -f $currentUser) -ForegroundColor Yellow
    
    if (-not [string]::IsNullOrEmpty($UserNames)) {
        $allowedUsers = $UserNames -split ',' | ForEach-Object { $_.Trim() }
        Write-Host ("Allowed usernames: {0}" -f ($allowedUsers -join ', ')) -ForegroundColor Yellow
    }
    else {
        Write-Host "Allowed usernames: NOT SPECIFIED" -ForegroundColor Red
    }
    
    Write-Host ("Proxy server: {0}" -f $Proxy)
    Write-Host ("Proxy override: {0}" -f $Override)
    Write-Host ""

    Write-Host "Checking user condition..." -ForegroundColor Gray
    
    $result = Test-UserCondition

    if ($result) {
        Write-Host "✓ User condition met: username is in allowed list" -ForegroundColor Green
        Write-Host "Result: WOULD ENABLE PROXY → USING PROXY CONNECTION" -ForegroundColor Green
        Write-Log "Final decision: Proxy ENABLED"
    }
    else {
        Write-Host "✗ User condition not met: username not in allowed list" -ForegroundColor Red
        Write-Host "Result: WOULD DISABLE PROXY → WOULD SWITCH TO DIRECT CONNECTION" -ForegroundColor Red
        Write-Log "Final decision: Proxy DISABLED (user not allowed)"
    }

    Write-Host ""
    
    $enabled, $server = Get-CurrentProxySettings
    $status = if ($enabled) { "ENABLED" } else { "DISABLED" }
    Write-Host ("Current proxy settings: {0} ({1})" -f $status, $server)
    
    Write-Host ""
    Write-Host "Note: This is a test. No changes were made to system settings."
    Write-Host "Use -Install to install the service for actual operation."
}

function Check-AndSetProxy {
    Initialize-Log
    Write-Log ("Configuration: usernames={0}, proxy={1}" -f $UserNames, $Proxy)
    
    $proxyParts = $Proxy -split ":"
    $proxyHost = $proxyParts[0]

    $hostAvailable = Test-ProxyHost -ProxyHost $proxyHost

    if (-not $hostAvailable) {
        Write-Log ("Proxy host {0} is not reachable, disabling proxy" -f $proxyHost)
        $success = Set-Proxy -Enable $false
        if ($success) { Write-Log "Proxy disabled successfully → switched to DIRECT connection" }
        return
    }

    $shouldEnable = Test-UserCondition
    if ($shouldEnable) {
        Write-Log "User condition met, enabling proxy"
        $success = Set-Proxy -Enable $true
        if ($success) { Write-Log "Proxy enabled successfully → USING PROXY CONNECTION" }
    }
    else {
        Write-Log "User condition not met, disabling proxy"
        $success = Set-Proxy -Enable $false
        if ($success) { Write-Log "Proxy disabled successfully → switched to DIRECT connection" }
    }
}

# --- Install / Uninstall / Run / Help functions ---
function Install-Service { ... }    # сохраняем как есть
function Uninstall-Service { ... }  # сохраняем как есть
function Run-Service { ... }        # сохраняем как есть
function Show-Help { ... }          # сохраняем как есть

# --- Main execution ---
if ($Help) { Show-Help; exit }
if ($Uninstall) { Uninstall-Service; exit }
if ($Install) { Install-Service; exit }
if ($Service) { Run-Service; exit }
if ($Test) { Test-ProxySetting; exit }

# Default: test mode
Test-ProxySetting
