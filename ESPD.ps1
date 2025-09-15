# ESPD Proxy PowerShell - Проверка логина пользователя и настройка прокси
# Кодировка: UTF-8 с BOM

param(
    [string]$UserNames = "",
    [string]$Proxy = "10.0.66.52:3128",
    [string]$Override = "192.168.*.*;192.25.*.*;<local>",
    [switch]$Test,     # тестовый режим
    [switch]$Apply     # рабочий режим
)

$LogFileName = "espdproxy.log"
$LogPath = Join-Path $env:TEMP $LogFileName
$MaxLogSize = 15MB

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
            Write-Log "Размер лог-файла превысил 15 МБ, создан новый файл"
        }
    }
}

function Get-CurrentUsername {
    return $env:USERNAME
}

function Test-UserCondition {
    $currentUser = Get-CurrentUsername
    Write-Log ("Текущий пользователь: {0}" -f $currentUser)
    
    if ([string]::IsNullOrEmpty($UserNames)) {
        Write-Log "Список разрешённых пользователей не указан"
        return $false
    }
    
    $allowedUsers = $UserNames -split ',' | ForEach-Object { $_.Trim() }
    Write-Log ("Разрешённые пользователи: {0}" -f ($allowedUsers -join ', '))

    foreach ($allowedUser in $allowedUsers) {
        if ($currentUser -eq $allowedUser) {
            Write-Log ("Совпадение пользователя найдено: {0} = {1}" -f $currentUser, $allowedUser)
            return $true
        }
    }

    Write-Log ("Совпадение пользователя не найдено. Текущий пользователь: {0}, Разрешённые: {1}" -f $currentUser, ($allowedUsers -join ', '))
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
        Write-Log ("Ошибка чтения настроек прокси: {0}" -f $_.Exception.Message)
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
            Write-Log ("Прокси включён: {0}" -f $Proxy)
        }
        else {
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
            Write-Log "Прокси отключён → прямое соединение"
        }
        
        rundll32 user32.dll,UpdatePerUserSystemParameters
        return $true
    }
    catch {
        Write-Log ("Ошибка при установке прокси: {0}" -f $_.Exception.Message)
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
        # Используем ping.exe для совместимости с Windows PowerShell 5.1
        $pingResult = ping.exe $ProxyHost -n $Count -w $Timeout | Select-String "TTL="
        if ($pingResult) {
            Write-Log ("Хост прокси {0} доступен" -f $ProxyHost)
            return $true
        } else {
            Write-Log ("Хост прокси {0} недоступен" -f $ProxyHost)
            return $false
        }
    }
    catch {
        Write-Log ("Ошибка при пинге хоста {0}: {1}" -f $ProxyHost, $_.Exception.Message)
        return $false
    }
}


function Test-ProxySetting {
    Write-Host "=== Тест ESPD Proxy ===" -ForegroundColor Cyan
    $proxyParts = $Proxy -split ":"
    $proxyHost = $proxyParts[0]

    $hostAvailable = Test-ProxyHost -ProxyHost $proxyHost
    $currentUser = Get-CurrentUsername
    
    Write-Host ("Текущий пользователь: {0}" -f $currentUser)
    
    if (-not [string]::IsNullOrEmpty($UserNames)) {
        $allowedUsers = $UserNames -split ',' | ForEach-Object { $_.Trim() }
        Write-Host ("Разрешённые пользователи: {0}" -f ($allowedUsers -join ', '))
    }
    else {
        Write-Host "Разрешённые пользователи: НЕ УКАЗАНЫ"
    }
    
    Write-Host ("Прокси сервер: {0}" -f $Proxy)
    Write-Host ("Список исключений: {0}" -f $Override)
    Write-Host ""

    $result = Test-UserCondition

    if ($hostAvailable -and $result) {
        Write-Host "✓ Прокси мог бы быть включён (хост доступен, пользователь разрешён)" -ForegroundColor Green
    }
    else {
        Write-Host "✗ Прокси не должен включаться" -ForegroundColor Red
    }

    $enabled, $server = Get-CurrentProxySettings
    $status = if ($enabled) { "ВКЛЮЧЁН" } else { "ОТКЛЮЧЁН" }
    Write-Host ("Текущие настройки прокси: {0} ({1})" -f $status, $server)
}

function Apply-ProxySetting {
    Initialize-Log
    Write-Log ("Конфигурация: пользователи={0}, прокси={1}" -f $UserNames, $Proxy)

    $proxyParts = $Proxy -split ":"
    $proxyHost = $proxyParts[0]
    $hostAvailable = Test-ProxyHost -ProxyHost $proxyHost

    if (-not $hostAvailable) {
        Write-Log "Хост недоступен, отключаем прокси"
        Set-Proxy -Enable $false
        return
    }

    $shouldEnable = Test-UserCondition
    if ($shouldEnable) {
        Write-Log "Условие пользователя выполнено, включаем прокси"
        Set-Proxy -Enable $true
    }
    else {
        Write-Log "Условие пользователя не выполнено, отключаем прокси"
        Set-Proxy -Enable $false
    }
}

# --- Основное выполнение ---
if ($Test) { Test-ProxySetting; exit }
if ($Apply) { Apply-ProxySetting; exit }

# По умолчанию запускаем тестовый режим
Test-ProxySetting
