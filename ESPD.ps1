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
    Write-Log "Current username: $currentUser"
    
    if ([string]::IsNullOrEmpty($UserNames)) {
        Write-Log "No usernames specified for checking"
        return $false
    }
    
    $allowedUsers = $UserNames -split ',' | ForEach-Object { $_.Trim() }
    Write-Log "Allowed usernames: $($allowedUsers -join ', ')"
    
    foreach ($allowedUser in $allowedUsers) {
        if ($currentUser -eq $allowedUser) {
            Write-Log "Username match found: $currentUser = $allowedUser"
            return $true
        }
    }
    
    Write-Log "No username match found. Current user: $currentUser, Allowed: $($allowedUsers -join ', ')"
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
        Write-Log "Error reading proxy settings: $($_.Exception.Message)"
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
            Write-Log "Proxy enabled: $Proxy → USING PROXY CONNECTION"
        }
        else {
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
            Write-Log "Proxy disabled → switched to DIRECT connection"
        }
        
        rundll32 user32.dll,UpdatePerUserSystemParameters
        return $true
    }
    catch {
        Write-Log "Error setting proxy: $($_.Exception.Message)"
        return $false
    }
}

function Test-ProxyHost {
    param(
        [string]$Host = "10.0.66.52",
        [int]$Count = 2,
        [int]$Timeout = 1000
    )

    try {
        $result = Test-Connection -ComputerName $Host -Count $Count -Quiet -ErrorAction SilentlyContinue -TimeoutSeconds ($Timeout/1000)
        if ($result) {
            Write-Log "Proxy host $Host is reachable (ping ok)"
            return $true
        }
        else {
            Write-Log "Proxy host $Host is NOT reachable (ping fail)"
            return $false
        }
    }
    catch {
        Write-Log "Error pinging proxy host $Host $(${_.Exception.Message})"
        return $false
    }
}

function Test-ProxySetting {
    Write-Host "=== ESPD Proxy Service - User Login Check ===" -ForegroundColor Cyan
    Write-Host ""
    
    $proxyParts = $Proxy -split ":"
    $proxyHost = $proxyParts[0]

    $hostAvailable = Test-ProxyHost -Host $proxyHost

    if (-not $hostAvailable) {
        Write-Host "✗ Proxy host $proxyHost is not reachable" -ForegroundColor Red
        Write-Host "Result: WOULD DISABLE PROXY → WOULD SWITCH TO DIRECT CONNECTION" -ForegroundColor Red
        return
    }

    $currentUser = Get-CurrentUsername
    Write-Host "Current username: $currentUser" -ForegroundColor Yellow
    
    if (-not [string]::IsNullOrEmpty($UserNames)) {
        $allowedUsers = $UserNames -split ',' | ForEach-Object { $_.Trim() }
        Write-Host "Allowed usernames: $($allowedUsers -join ', ')" -ForegroundColor Yellow
    }
    else {
        Write-Host "Allowed usernames: NOT SPECIFIED" -ForegroundColor Red
    }
    
    Write-Host "Proxy server: $Proxy"
    Write-Host "Proxy override: $Override"
    Write-Host ""

    Write-Host "Checking user condition..." -ForegroundColor Gray
    
    $result = Test-UserCondition

    if ($result) {
        Write-Host "✓ User condition met: username is in allowed list" -ForegroundColor Green
        Write-Host "Result: WOULD ENABLE PROXY → USING PROXY CONNECTION" -ForegroundColor Green
    }
    else {
        Write-Host "✗ User condition not met: username not in allowed list" -ForegroundColor Red
        Write-Host "Result: WOULD DISABLE PROXY → WOULD SWITCH TO DIRECT CONNECTION" -ForegroundColor Red
    }

    Write-Host ""
    
    $enabled, $server = Get-CurrentProxySettings
    $status = if ($enabled) { "ENABLED" } else { "DISABLED" }
    Write-Host "Current proxy settings: $status ($server)"
    
    Write-Host ""
    Write-Host "Note: This is a test. No changes were made to system settings."
    Write-Host "Use -Install to install the service for actual operation."
}

function Check-AndSetProxy {
    Initialize-Log
    
    Write-Log "Configuration: usernames=$UserNames, proxy=$Proxy"
    
    $proxyParts = $Proxy -split ":"
    $proxyHost = $proxyParts[0]

    $hostAvailable = Test-ProxyHost -Host $proxyHost

    if (-not $hostAvailable) {
        Write-Log "Proxy host $proxyHost is not reachable, disabling proxy"
        $success = Set-Proxy -Enable $false
        if ($success) {
            Write-Log "Proxy disabled successfully → switched to DIRECT connection"
        }
        else {
            Write-Log "Error disabling proxy"
        }
        return
    }

    $shouldEnable = Test-UserCondition
    if ($shouldEnable) {
        Write-Log "User condition met, enabling proxy"
        $success = Set-Proxy -Enable $true
        if ($success) {
            Write-Log "Proxy enabled successfully → USING PROXY CONNECTION"
        }
        else {
            Write-Log "Error enabling proxy"
        }
    }
    else {
        Write-Log "User condition not met, disabling proxy"
        $success = Set-Proxy -Enable $false
        if ($success) {
            Write-Log "Proxy disabled successfully → switched to DIRECT connection"
        }
        else {
            Write-Log "Error disabling proxy"
        }
    }
}

function Install-Service {
    if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "Error: Please run as Administrator!" -ForegroundColor Red
        return
    }

    $scriptPath = $MyInvocation.MyCommand.Path
    $serviceArgs = "-Service -Proxy $Proxy -Override `"$Override`""
    
    if (-not [string]::IsNullOrEmpty($UserNames)) {
        $serviceArgs += " -UserNames `"$UserNames`""
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`" $serviceArgs"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    
    try {
        Register-ScheduledTask -TaskName $ServiceName -Description $ServiceDescription `
            -Action $action -Trigger $trigger -Settings $settings -User $env:USERNAME -RunLevel Highest -Force
        
        Start-ScheduledTask -TaskName $ServiceName
        Write-Host "Service '$ServiceName' installed successfully!" -ForegroundColor Green
        
        Write-Host "Configuration:"
        if (-not [string]::IsNullOrEmpty($UserNames)) {
            $users = $UserNames -split ',' | ForEach-Object { $_.Trim() }
            Write-Host "  Allowed usernames: $($users -join ', ')"
        } else {
            Write-Host "  Allowed usernames: NONE (proxy will always be disabled)"
        }
        Write-Host "  Proxy: $Proxy"
        Write-Host "  Override: $Override"
    }
    catch {
        Write-Host "Error installing service: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Uninstall-Service {
    if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "Error: Please run as Administrator!" -ForegroundColor Red
        return
    }

    try {
        Stop-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host ("Service '{0}' uninstalled successfully!" -f $ServiceName) -ForegroundColor Green
    }
    catch {
        Write-Host "Error uninstalling service: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Run-Service {
    Initialize-Log
    Write-Log "ESPD Proxy Service started (User Login Check)"
    Write-Log "Configuration: usernames=$UserNames, proxy=$Proxy"

    Check-AndSetProxy
    
    while ($true) {
        Start-Sleep -Seconds $CheckInterval
        Check-AndSetProxy
    }
}

function Show-Help {
    Write-Host "ESPD Proxy Service - User Login Check" -ForegroundColor Cyan
    Write-Host "Usage: .\espd-proxy-service.ps1 [options]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -UserNames string        Comma-separated list of usernames (without domain)"
    Write-Host "  -Proxy string            Proxy server address:port (default: 10.0.66.52:3128)"
    Write-Host "  -Override string         Proxy override list (default: 192.168.*.*;192.25.*.*;<local>)"
    Write-Host "  -Install                 Install as scheduled task"
    Write-Host "  -Uninstall               Remove scheduled task"
    Write-Host "  -Test                    Test mode"
    Write-Host "  -Help                    Show this help"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\espd-proxy-service.ps1 -Test -UserNames ""admin,user1,user2"""
    Write-Host "  .\espd-proxy-service.ps1 -Install -UserNames ""admin,user1,user2"" -Proxy ""10.0.66.52:3128"""
    Write-Host "  .\espd-proxy-service.ps1 -Install -UserNames ""admin"""
    Write-Host "  .\espd-proxy-service.ps1 -Uninstall"
}

# Main execution
if ($Help) { Show-Help; exit }
if ($Uninstall) { Uninstall-Service; exit }
if ($Install) { Install-Service; exit }
if ($Service) { Run-Service; exit }
if ($Test) { Test-ProxySetting; exit }

# Default: test mode
Test-ProxySetting
