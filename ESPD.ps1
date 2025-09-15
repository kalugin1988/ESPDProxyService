# Сервис ESPD Proxy PowerShell - Проверка логина пользователя

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
$ServiceDescription = "Сервис конфигурации ESPD Proxy (только проверка логина пользователя)"
$LogFileName = "espdproxy.log"
$LogPath = Join-Path $env:TEMP $LogFileName
$MaxLogSize = 15MB
$CheckInterval = 60 # интервал проверки в секундах

# Функция записи логов
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Add-Content -Path $LogPath -Value $logMessage -ErrorAction SilentlyContinue
    Write-Host $logMessage
}

# Инициализация лог-файла
function Initialize-Log {
    if (Test-Path $LogPath) {
        $fileSize = (Get-Item $LogPath).Length
        if ($fileSize -gt $MaxLogSize) {
            Remove-Item $LogPath -Force
            Write-Log "Размер лог-файла превысил 15МБ, создан новый файл"
        }
    }
}

# Получаем имя текущего пользователя
function Get-CurrentUsername {
    return $env:USERNAME
}

# Проверка, входит ли текущий пользователь в список разрешённых
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

# Получаем текущие настройки прокси
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

# Включение/отключение прокси
function Set-Proxy {
    param([bool]$Enable)
    
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        
        if ($Enable) {
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1
            Set-ItemProperty -Path $regPath -Name ProxyServer -Value $Proxy
            Set-ItemProperty -Path $regPath -Name ProxyOverride -Value $Override
            Write-Log ("Прокси включён: {0} → ИСПОЛЬЗУЕТСЯ ПРОКСИ" -f $Proxy)
        }
        else {
            Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
            Write-Log "Прокси отключён → ПЕРЕХОД НА ПРЯМОЕ СОЕДИНЕНИЕ"
        }
        
        rundll32 user32.dll,UpdatePerUserSystemParameters
        return $true
    }
    catch {
        Write-Log ("Ошибка при установке прокси: {0}" -f $_.Exception.Message)
        return $false
    }
}

# Проверка доступности хоста прокси через ping
function Test-ProxyHost {
    param(
        [string]$ProxyHost = "10.0.66.52",
        [int]$Count = 2,
        [int]$Timeout = 1000
    )

    try {
        $result = Test-Connection -ComputerName $ProxyHost -Count $Count -Quiet -ErrorAction SilentlyContinue -TimeoutSeconds ($Timeout/1000)
        if ($result) {
            Write-Log ("Хост прокси {0} доступен (ping успешен)" -f $ProxyHost)
            return $true
        }
        else {
            Write-Log ("Хост прокси {0} недоступен (ping неуспешен)" -f $ProxyHost)
            return $false
        }
    }
    catch {
        Write-Log ("Ошибка при пинге хоста {0}: {1}" -f $ProxyHost, $_.Exception.Message)
        return $false
    }
}

# Тестовое отображение текущих условий
function Test-ProxySetting {
    Write-Host "=== Сервис ESPD Proxy - Проверка логина пользователя ===" -ForegroundColor Cyan
    Write-Host ""
    
    $proxyParts = $Proxy -split ":"
    $proxyHost = $proxyParts[0]

    $hostAvailable = Test-ProxyHost -ProxyHost $proxyHost

    if (-not $hostAvailable) {
        Write-Host ("✗ Хост прокси {0} недоступен" -f $proxyHost) -ForegroundColor Red
        Write-Host "Результат: ПРОКСИ БЫЛО БЫ ОТКЛЮЧЕНО → ПЕРЕХОД НА ПРЯМОЕ СОЕДИНЕНИЕ" -ForegroundColor Red
        Write-Log "Итоговое решение: прокси ВЫКЛ (хост недоступен)"
        return
    }

    $currentUser = Get-CurrentUsername
    Write-Host ("Текущий пользователь: {0}" -f $currentUser) -ForegroundColor Yellow
    
    if (-not [string]::IsNullOrEmpty($UserNames)) {
        $allowedUsers = $UserNames -split ',' | ForEach-Object { $_.Trim() }
        Write-Host ("Разрешённые пользователи: {0}" -f ($allowedUsers -join ', ')) -ForegroundColor Yellow
    }
    else {
        Write-Host "Разрешённые пользователи: НЕ УКАЗАНЫ" -ForegroundColor Red
    }
    
    Write-Host ("Прокси сервер: {0}" -f $Proxy)
    Write-Host ("Список исключений: {0}" -f $Override)
    Write-Host ""

    Write-Host "Проверка условий пользователя..." -ForegroundColor Gray
    
    $result = Test-UserCondition

    if ($result) {
        Write-Host "✓ Условие выполнено: пользователь разрешён" -ForegroundColor Green
        Write-Host "Результат: ПРОКСИ БЫЛО БЫ ВКЛЮЧЕНО → ИСПОЛЬЗУЕТСЯ ПРОКСИ" -ForegroundColor Green
        Write-Log "Итоговое решение: прокси ВКЛ"
    }
    else {
        Write-Host "✗ Условие не выполнено: пользователь не разрешён" -ForegroundColor Red
        Write-Host "Результат: ПРОКСИ БЫЛО БЫ ОТКЛЮЧЕНО → ПЕРЕХОД НА ПРЯМОЕ СОЕДИНЕНИЕ" -ForegroundColor Red
        Write-Log "Итоговое решение: прокси ВЫКЛ (пользователь не разрешён)"
    }

    Write-Host ""
    
    $enabled, $server = Get-CurrentProxySettings
    $status = if ($enabled) { "ВКЛЮЧЁН" } else { "ОТКЛЮЧЁН" }
    Write-Host ("Текущие настройки прокси: {0} ({1})" -f $status, $server)
    
    Write-Host ""
    Write-Host "Примечание: это тестовый режим. Настройки системы не изменялись."
    Write-Host "Используйте -Install для установки сервиса."
}

# Функция проверки и установки прокси в реальном времени
function Check-AndSetProxy {
    Initialize-Log
    Write-Log ("Конфигурация: пользователи={0}, прокси={1}" -f $UserNames, $Proxy)
    
    $proxyParts = $Proxy -split ":"
    $proxyHost = $proxyParts[0]

    $hostAvailable = Test-ProxyHost -ProxyHost $proxyHost

    if (-not $hostAvailable) {
        Write-Log ("Хост прокси {0} недоступен, прокси отключается" -f $proxyHost)
        $success = Set-Proxy -Enable $false
        if ($success) { Write-Log "Прокси успешно отключён → переход на прямое соединение" }
        return
    }

    $shouldEnable = Test-UserCondition
    if ($shouldEnable) {
        Write-Log "Условие пользователя выполнено, включаем прокси"
        $success = Set-Proxy -Enable $true
        if ($success) { Write-Log "Прокси успешно включён → используется прокси" }
    }
    else {
        Write-Log "Условие пользователя не выполнено, отключаем прокси"
        $success = Set-Proxy -Enable $false
        if ($success) { Write-Log "Прокси успешно отключён → переход на прямое соединение" }
    }
}

# --- Остальные функции Install/Uninstall/Run/Help сохраняем как есть, только с русскими логами внутри ---
function Install-Service { ... }
function Uninstall-Service { ... }
function Run-Service { ... }
function Show-Help { ... }

# --- Основное выполнение ---
if ($Help) { Show-Help; exit }
if ($Uninstall) { Uninstall-Service; exit }
if ($Install) { Install-Service; exit }
if ($Service) { Run-Service; exit }
if ($Test) { Test-ProxySetting; exit }

# По умолчанию тестовый режим
Test-ProxySetting
