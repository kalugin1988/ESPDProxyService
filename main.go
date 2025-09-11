package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/user"
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
)

var (
	logFile       *os.File
	logger        *log.Logger
	targetGateway string
	proxyServer   string
	proxyOverride string
	fullUserName  string
	findUserName  string
	checkMode     string
)

func main() {
	// Парсим флаги
	installFlag := flag.Bool("install", false, "Install as Windows service")
	uninstallFlag := flag.Bool("uninstall", false, "Remove Windows service")
	serviceFlag := flag.Bool("service", false, "Run as service (for internal use)")
	testFlag := flag.Bool("test", false, "Test mode")
	helpFlag := flag.Bool("help", false, "Show help")
	hFlag := flag.Bool("h", false, "Show help")

	// Параметры конфигурации
	flag.StringVar(&targetGateway, "gateway", "192.168.1.1", "Target gateway IP address")
	flag.StringVar(&proxyServer, "proxy", "10.0.66.52:3128", "Proxy server address:port")
	flag.StringVar(&proxyOverride, "override", "192.168.*.*;192.25.*.*;<local>", "Proxy override list")
	flag.StringVar(&fullUserName, "fullname", "", "Exact username match (requires full match)")
	flag.StringVar(&findUserName, "findname", "", "Partial username match (contains text)")
	flag.StringVar(&checkMode, "mode", "gateway", "Check mode: gateway, user, or both")

	flag.Parse()

	if *helpFlag || *hFlag {
		printHelp()
		return
	}

	if *installFlag {
		installService()
		return
	}

	if *uninstallFlag {
		uninstallService()
		return
	}

	if *serviceFlag {
		runService()
		return
	}

	if *testFlag {
		testProxySetting()
		return
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

func getCurrentUsername() (string, error) {
	currentUser, err := user.Current()
	if err != nil {
		return "", err
	}
	return currentUser.Username, nil
}

func checkUserCondition() (bool, error) {
	currentUser, err := getCurrentUsername()
	if err != nil {
		return false, err
	}

	logToFile(fmt.Sprintf("Current username: %s", currentUser))

	// Проверяем полное совпадение
	if fullUserName != "" {
		if currentUser == fullUserName {
			logToFile(fmt.Sprintf("Full username match: %s", fullUserName))
			return true, nil
		}
		logToFile(fmt.Sprintf("Full username does not match: expected %s, got %s", fullUserName, currentUser))
	}

	// Проверяем частичное совпадение
	if findUserName != "" {
		if strings.Contains(currentUser, findUserName) {
			logToFile(fmt.Sprintf("Partial username match: %s contains %s", currentUser, findUserName))
			return true, nil
		}
		logToFile(fmt.Sprintf("Partial username not found: %s does not contain %s", currentUser, findUserName))
	}

	return false, nil
}

func getDefaultGateway() (string, error) {
	cmd := exec.Command("route", "print", "-4")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("route print failed: %v", err)
	}

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

	ipPattern := regexp.MustCompile(`^\d+\.\d+\.\d+\.\d+$`)
	if !ipPattern.MatchString(gateway) {
		return "", fmt.Errorf("invalid gateway IP: %s", gateway)
	}

	return gateway, nil
}

func getActiveGateways() ([]string, error) {
	cmd := exec.Command("netsh", "interface", "ip", "show", "config")
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("netsh failed: %v", err)
	}

	var gateways []string
	scanner := bufio.NewScanner(strings.NewReader(string(output)))

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
	defaultGateway, err := getDefaultGateway()
	if err != nil {
		gateways, err := getActiveGateways()
		if err != nil {
			return false, err
		}

		for _, gw := range gateways {
			if gw == targetGateway {
				return true, nil
			}
		}

		return false, nil
	}

	return defaultGateway == targetGateway, nil
}

func shouldEnableProxy() (bool, error) {
	switch checkMode {
	case "gateway":
		return isTargetGatewayActive()
	case "user":
		return checkUserCondition()
	case "both":
		gatewayOk, err := isTargetGatewayActive()
		if err != nil {
			return false, err
		}
		userOk, err := checkUserCondition()
		if err != nil {
			return false, err
		}
		return gatewayOk && userOk, nil
	default:
		return false, fmt.Errorf("unknown check mode: %s", checkMode)
	}
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
	fmt.Printf("Check mode: %s\n", checkMode)

	if checkMode == "gateway" || checkMode == "both" {
		fmt.Printf("Target gateway: %s\n", targetGateway)
	}
	if checkMode == "user" || checkMode == "both" {
		if fullUserName != "" {
			fmt.Printf("Full username: %s\n", fullUserName)
		}
		if findUserName != "" {
			fmt.Printf("Find username: %s\n", findUserName)
		}
	}
	fmt.Printf("Proxy server: %s\n", proxyServer)
	fmt.Printf("Proxy override: %s\n", proxyOverride)
	fmt.Println("")

	fmt.Println("Checking conditions...")

	currentUser, err := getCurrentUsername()
	if err != nil {
		fmt.Printf("Error getting username: %v\n", err)
	} else {
		fmt.Printf("Current username: %s\n", currentUser)
	}

	var result bool
	var reason string

	switch checkMode {
	case "gateway":
		gatewayActive, err := isTargetGatewayActive()
		if err != nil {
			fmt.Printf("Error checking gateway: %v\n", err)
			return
		}
		result = gatewayActive
		reason = "gateway check"

	case "user":
		userOk, err := checkUserCondition()
		if err != nil {
			fmt.Printf("Error checking user: %v\n", err)
			return
		}
		result = userOk
		reason = "user check"

	case "both":
		gatewayActive, err := isTargetGatewayActive()
		if err != nil {
			fmt.Printf("Error checking gateway: %v\n", err)
			return
		}
		userOk, err := checkUserCondition()
		if err != nil {
			fmt.Printf("Error checking user: %v\n", err)
			return
		}
		result = gatewayActive && userOk
		reason = "both gateway and user check"
	}

	if result {
		fmt.Printf("✓ Conditions met (%s)\n", reason)
		fmt.Println("Result: WOULD ENABLE PROXY")
	} else {
		fmt.Printf("✗ Conditions not met (%s)\n", reason)
		fmt.Println("Result: WOULD DISABLE PROXY")
	}

	fmt.Println("")

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
	shouldEnable, err := shouldEnableProxy()
	if err != nil {
		logToFile(fmt.Sprintf("Error checking conditions: %v", err))
		return
	}

	logToFile(fmt.Sprintf("Configuration: mode=%s, gateway=%s, fullname=%s, findname=%s, proxy=%s",
		checkMode, targetGateway, fullUserName, findUserName, proxyServer))

	if shouldEnable {
		logToFile("Conditions met, enabling proxy")
		err := setProxy(true)
		if err != nil {
			logToFile(fmt.Sprintf("Error enabling proxy: %v", err))
		} else {
			logToFile("Proxy enabled successfully")
		}
	} else {
		logToFile("Conditions not met, disabling proxy")
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
	logToFile(fmt.Sprintf("Service configuration: mode=%s, gateway=%s, fullname=%s, findname=%s, proxy=%s",
		checkMode, targetGateway, fullUserName, findUserName, proxyServer))

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

	// Строим команду с параметрами
	serviceArgs := fmt.Sprintf("\"%s --service --mode=%s --gateway=%s --proxy=%s --override=\"%s\"",
		exePath, checkMode, targetGateway, proxyServer, proxyOverride)

	if fullUserName != "" {
		serviceArgs += fmt.Sprintf(" --fullname=\"%s\"", fullUserName)
	}
	if findUserName != "" {
		serviceArgs += fmt.Sprintf(" --findname=\"%s\"", findUserName)
	}
	serviceArgs += "\""

	cmd := exec.Command("sc", "create", serviceName,
		"binPath=", serviceArgs,
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

	fmt.Printf("Service '%s' installed successfully with configuration:\n", serviceName)
	fmt.Printf("  Mode: %s\n", checkMode)
	if checkMode == "gateway" || checkMode == "both" {
		fmt.Printf("  Gateway: %s\n", targetGateway)
	}
	if checkMode == "user" || checkMode == "both" {
		if fullUserName != "" {
			fmt.Printf("  Full username: %s\n", fullUserName)
		}
		if findUserName != "" {
			fmt.Printf("  Find username: %s\n", findUserName)
		}
	}
	fmt.Printf("  Proxy: %s\n", proxyServer)
	fmt.Printf("  Override: %s\n", proxyOverride)
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
	fmt.Printf("Usage: %s [options]\n", os.Args[0])
	fmt.Printf("\nOptions:\n")
	fmt.Printf("  --install                Install as Windows service\n")
	fmt.Printf("  --uninstall              Remove Windows service\n")
	fmt.Printf("  --service                Run as service (for internal use)\n")
	fmt.Printf("  --test                   Test mode\n")
	fmt.Printf("  --help, -h               Show this help\n")
	fmt.Printf("\nConfiguration options:\n")
	fmt.Printf("  --mode string            Check mode: gateway, user, or both (default: gateway)\n")
	fmt.Printf("  --gateway string         Target gateway IP (default: 192.168.1.1)\n")
	fmt.Printf("  --fullname string        Exact username match (requires full match)\n")
	fmt.Printf("  --findname string        Partial username match (contains text)\n")
	fmt.Printf("  --proxy string           Proxy server address:port (default: 10.0.66.52:3128)\n")
	fmt.Printf("  --override string        Proxy override list (default: 192.168.*.*;192.25.*.*;<local>)\n")
	fmt.Printf("\nExamples:\n")
	fmt.Printf("  # Check by gateway only (default)\n")
	fmt.Printf("  %s --install --gateway=192.168.0.1\n", os.Args[0])
	fmt.Printf("  # Check by exact username\n")
	fmt.Printf("  %s --install --mode=user --fullname=DOMAIN\\username\n", os.Args[0])
	fmt.Printf("  # Check by partial username\n")
	fmt.Printf("  %s --install --mode=user --findname=admin\n", os.Args[0])
	fmt.Printf("  # Check by both gateway and username\n")
	fmt.Printf("  %s --install --mode=both --gateway=192.168.1.1 --findname=user\n", os.Args[0])
	fmt.Printf("  # Test current username\n")
	fmt.Printf("  %s --test --mode=user --fullname=DOMAIN\\username\n", os.Args[0])
}

// go mod init espв
// go mod tidy
// go run main.g
// env GOOS=windows GOARCH=amd64 go build -o espd-proxy-service.exe
// set GOOS=windows&& set GOARCH=amd64&& go build -o espd-proxy-service64.exe
// set GOOS=windows&& set GOARCH=amd32&& go build -o espd-proxy-service32.exe
//
//Проверка по точному имени пользователя:
//--install --mode=user --fullname="DOMAIN\username" --proxy=10.0.66.52:3128
//Проверка по частичному имени:
//--install --mode=user --findname="admin" --proxy=10.0.66.52:3128
//Комбинированная проверка:
//--install --mode=both --gateway=192.168.1.1 --findname="user" --proxy=10.0.66.52:3128
//Тестирование пользователя:
//--test --mode=user --fullname="DOMAIN\username"
//Только шлюз (как раньше):
//--install --mode=gateway --gateway=192.168.1.1
