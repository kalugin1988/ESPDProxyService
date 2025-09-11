package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"golang.org/x/sys/windows/registry"
)

const (
	serviceName        = "ESPDProxyService"
	serviceDescription = "ESPD Proxy Configuration Service"
	logFileName        = "espdproxy.log"
	maxLogSize         = 15 * 1024 * 1024 // 15 MB
	checkInterval      = 1 * time.Minute
	targetGateway      = "192.168.1.1"
	proxyServer        = "10.0.66.52:3128"
	proxyOverride      = "192.168.*.*;192.25.*.*;<local>"
)

var (
	logFile *os.File
	logger  *log.Logger
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--install":
			installService()
			return
		case "--uninstall":
			uninstallService()
			return
		case "--service":
			runService()
			return
		case "--test":
			testProxySetting()
			return
		case "--help", "-h":
			printHelp()
			return
		}
	}

	// Запуск без параметров = тестовый режим
	testProxySetting()
}

func initLogger() error {
	tempDir := os.TempDir()
	logPath := tempDir + "\\" + logFileName

	if info, err := os.Stat(logPath); err == nil {
		if info.Size() > maxLogSize {
			os.Remove(logPath)
			logToFile("Log file exceeded 15MB, created new one")
		}
	}

	var err error
	logFile, err = os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}

	logger = log.New(logFile, "", log.LstdFlags)
	return nil
}

func logToFile(message string) {
	if logger != nil {
		logger.Println(message)
	}
}

func getDefaultGateway() (string, error) {
	// Используем route print для получения таблицы маршрутизации
	cmd := exec.Command("route", "print", "-4")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("route print failed: %v", err)
	}

	// Парсим вывод команды route print
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	networkDestPattern := regexp.MustCompile(`^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)\s+.*$`)

	var gateway string
	foundDefaultRoute := false

	for scanner.Scan() {
		line := scanner.Text()
		if matches := networkDestPattern.FindStringSubmatch(line); matches != nil && len(matches) > 1 {
			gateway = matches[1]
			foundDefaultRoute = true
			break
		}
	}

	if !foundDefaultRoute {
		return "", fmt.Errorf("default gateway not found in routing table")
	}

	// Проверяем, что это валидный IP-адрес
	ipPattern := regexp.MustCompile(`^\d+\.\d+\.\d+\.\d+$`)
	if !ipPattern.MatchString(gateway) {
		return "", fmt.Errorf("invalid gateway IP: %s", gateway)
	}

	return gateway, nil
}

func getActiveGateways() ([]string, error) {
	// Альтернативный метод: получаем все активные шлюзы
	cmd := exec.Command("netsh", "interface", "ip", "show", "config")
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("netsh failed: %v", err)
	}

	var gateways []string
	scanner := bufio.NewScanner(strings.NewReader(string(output)))

	// Шаблоны для поиска шлюзов
	gatewayPatterns := []*regexp.Regexp{
		regexp.MustCompile(`Default Gateway[\. ]*: (\d+\.\d+\.\d+\.\d+)`),
		regexp.MustCompile(`Основной шлюз[\. ]*: (\d+\.\d+\.\d+\.\d+)`),
		regexp.MustCompile(`Шлюз, используемый по умолчанию[\. ]*: (\d+\.\d+\.\d+\.\d+)`),
	}

	for scanner.Scan() {
		line := scanner.Text()
		for _, pattern := range gatewayPatterns {
			if matches := pattern.FindStringSubmatch(line); matches != nil && len(matches) > 1 {
				gateway := matches[1]
				if gateway != "0.0.0.0" {
					gateways = append(gateways, gateway)
				}
			}
		}
	}

	if len(gateways) == 0 {
		return nil, fmt.Errorf("no active gateways found")
	}

	return gateways, nil
}

func isTargetGatewayActive() (bool, error) {
	// Основной метод - через таблицу маршрутизации
	defaultGateway, err := getDefaultGateway()
	if err != nil {
		// Альтернативный метод - ищем среди всех активных шлюзов
		gateways, err := getActiveGateways()
		if err != nil {
			return false, err
		}

		// Проверяем, есть ли целевой шлюз среди активных
		for _, gw := range gateways {
			if gw == targetGateway {
				return true, nil
			}
		}

		return false, nil
	}

	return defaultGateway == targetGateway, nil
}

func getCurrentProxySettings() (bool, string, error) {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.READ)
	if err != nil {
		return false, "", err
	}
	defer k.Close()

	enabled, _, err := k.GetIntegerValue("ProxyEnable")
	if err != nil {
		return false, "", err
	}

	server, _, err := k.GetStringValue("ProxyServer")
	if err != nil {
		// Если значение не существует, возвращаем пустую строку
		server = ""
	}

	return enabled == 1, server, nil
}

func setProxy(enable bool) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.ALL_ACCESS)
	if err != nil {
		return err
	}
	defer k.Close()

	var enableValue uint32 = 0
	if enable {
		enableValue = 1
	}

	err = k.SetDWordValue("ProxyEnable", enableValue)
	if err != nil {
		return err
	}

	if enable {
		err = k.SetStringValue("ProxyServer", proxyServer)
		if err != nil {
			return err
		}

		err = k.SetStringValue("ProxyOverride", proxyOverride)
		if err != nil {
			return err
		}
	}

	cmd := exec.Command("rundll32", "user32.dll,UpdatePerUserSystemParameters")
	err = cmd.Run()
	if err != nil {
		return err
	}

	return nil
}

func testProxySetting() {
	fmt.Println("=== ESPD Proxy Service Test Mode ===")
	fmt.Printf("Target gateway: %s\n", targetGateway)
	fmt.Printf("Proxy server: %s\n", proxyServer)
	fmt.Printf("Proxy override: %s\n", proxyOverride)
	fmt.Println("")

	// Получаем текущий шлюз
	fmt.Println("Checking network configuration...")

	defaultGateway, err := getDefaultGateway()
	if err != nil {
		fmt.Printf("Warning: %v\n", err)

		// Пробуем альтернативный метод
		gateways, err := getActiveGateways()
		if err != nil {
			fmt.Printf("Error: Could not determine gateway: %v\n", err)
			fmt.Println("")
			fmt.Println("Result: UNKNOWN (cannot determine gateway)")
			return
		}

		fmt.Printf("Found gateways: %v\n", gateways)

		targetFound := false
		for _, gw := range gateways {
			if gw == targetGateway {
				targetFound = true
				break
			}
		}

		if targetFound {
			fmt.Printf("✓ Target gateway %s found among active gateways\n", targetGateway)
			fmt.Println("Result: WOULD ENABLE PROXY")
		} else {
			fmt.Printf("✗ Target gateway %s not found among active gateways\n", targetGateway)
			fmt.Println("Result: WOULD DISABLE PROXY")
		}
	} else {
		fmt.Printf("Default gateway: %s\n", defaultGateway)

		if defaultGateway == targetGateway {
			fmt.Printf("✓ Target gateway matches: %s\n", targetGateway)
			fmt.Println("Result: WOULD ENABLE PROXY")
		} else {
			fmt.Printf("✗ Target gateway does not match. Expected: %s, Got: %s\n", targetGateway, defaultGateway)
			fmt.Println("Result: WOULD DISABLE PROXY")
		}
	}

	fmt.Println("")

	// Показываем текущие настройки прокси
	enabled, server, err := getCurrentProxySettings()
	if err != nil {
		fmt.Printf("Error reading current proxy settings: %v\n", err)
	} else {
		status := "DISABLED"
		if enabled {
			status = "ENABLED"
		}
		fmt.Printf("Current proxy settings: %s (%s)\n", status, server)
	}

	fmt.Println("")
	fmt.Println("Note: This is a test. No changes were made to system settings.")
	fmt.Println("Use --install to install the service for actual operation.")
}

func checkAndSetProxy() {
	targetActive, err := isTargetGatewayActive()
	if err != nil {
		logToFile(fmt.Sprintf("Error checking gateway: %v", err))
		return
	}

	if targetActive {
		logToFile("Target gateway detected, enabling proxy")
		err := setProxy(true)
		if err != nil {
			logToFile(fmt.Sprintf("Error enabling proxy: %v", err))
		} else {
			logToFile("Proxy enabled successfully")
		}
	} else {
		logToFile("Target gateway not active, disabling proxy")
		err := setProxy(false)
		if err != nil {
			logToFile(fmt.Sprintf("Error disabling proxy: %v", err))
		} else {
			logToFile("Proxy disabled successfully")
		}
	}
}

func runService() {
	err := initLogger()
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}
	defer logFile.Close()

	logToFile("ESPD Proxy Service started")

	ticker := time.NewTicker(checkInterval)
	defer ticker.Stop()

	checkAndSetProxy()

	for range ticker.C {
		checkAndSetProxy()
	}
}

func installService() {
	exePath, err := os.Executable()
	if err != nil {
		fmt.Printf("Error getting executable path: %v\n", err)
		return
	}

	// Устанавливаем службу с параметром --service для запуска в режиме службы
	cmd := exec.Command("sc", "create", serviceName,
		"binPath=", fmt.Sprintf("\"%s --service\"", exePath),
		"displayname=", serviceDescription,
		"start=", "auto")

	output, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Printf("Error creating service: %v\nOutput: %s\n", err, output)
		return
	}

	cmd = exec.Command("sc", "start", serviceName)
	output, err = cmd.CombinedOutput()
	if err != nil {
		fmt.Printf("Error starting service: %v\nOutput: %s\n", err, output)
		return
	}

	fmt.Printf("Service '%s' installed and started successfully\n", serviceName)
	fmt.Println("The service will run with --service parameter in the background")
}

func uninstallService() {
	cmd := exec.Command("sc", "stop", serviceName)
	cmd.Run()

	cmd = exec.Command("sc", "delete", serviceName)
	output, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Printf("Error deleting service: %v\nOutput: %s\n", err, output)
		return
	}

	fmt.Printf("Service '%s' uninstalled successfully\n", serviceName)
}

func printHelp() {
	fmt.Printf("ESPD Proxy Service\n")
	fmt.Printf("Usage: %s [option]\n", os.Args[0])
	fmt.Printf("Options:\n")
	fmt.Printf("  --install     Install as Windows service\n")
	fmt.Printf("  --uninstall   Remove Windows service\n")
	fmt.Printf("  --service     Run as service (for internal use)\n")
	fmt.Printf("  --test        Test mode - check what would happen without making changes\n")
	fmt.Printf("  --help, -h    Show this help message\n")
	fmt.Printf("\nIf no parameters are provided, test mode will run.\n")
	fmt.Printf("Service checks default gateway every minute and sets proxy accordingly.\n")
}

// go mod init espв
// go mod tidy
// go run main.g
// env GOOS=windows GOARCH=amd64 go build -o espd-proxy-service.exe
// set GOOS=windows&& set GOARCH=amd64&& go build -o espd-proxy-service64.exe
// set GOOS=windows&& set GOARCH=amd32&& go build -o espd-proxy-service32.exe
