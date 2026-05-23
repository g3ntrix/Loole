package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/NullLatency/flow-driver/internal/config"
	"github.com/NullLatency/flow-driver/internal/flow"
	"github.com/NullLatency/flow-driver/internal/httpclient"
	"github.com/NullLatency/flow-driver/internal/storage"
	"github.com/NullLatency/flow-driver/internal/transport"
)

func main() {
	var configPath, gcPath, profilesDir string
	flag.StringVar(&configPath, "c", "config.json", "Path to config file (single-profile mode)")
	flag.StringVar(&gcPath, "gc", "credentials.json", "Path to Google Service Account JSON (single-profile mode)")
	flag.StringVar(&profilesDir, "d", "", "Path to a directory containing one subdirectory per client profile")
	flag.Parse()

	log.Println("Starting Loole Server...")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if profilesDir != "" {
		runMultiProfile(ctx, profilesDir)
	} else {
		if err := runProfile(ctx, "default", configPath, gcPath); err != nil {
			log.Fatalf("Profile failed: %v", err)
		}
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
	log.Println("Shutting down server...")
	cancel()
}

// runProfile starts one engine for the given config + credentials paths.
// Returns once startup completes (engine goroutines keep running until ctx cancels).
func runProfile(ctx context.Context, name, configPath, gcPath string) error {
	appCfg, err := config.Load(configPath)
	if err != nil {
		return fmt.Errorf("[%s] load config: %w", name, err)
	}

	if appCfg.StorageType == "google" && appCfg.GoogleFolderID != "" {
		return runFlowProfile(ctx, name, appCfg, gcPath)
	}

	var backend storage.Backend
	if appCfg.StorageType == "google" {
		customHttpClient := httpclient.NewCustomClient(appCfg.Transport)
		backend = storage.NewGoogleBackend(customHttpClient, gcPath, appCfg.GoogleFolderID)
	} else {
		backend, err = storage.NewLocalBackend(appCfg.LocalDir)
		if err != nil {
			return fmt.Errorf("[%s] init local storage: %w", name, err)
		}
	}
	if err := backend.Login(ctx); err != nil {
		return fmt.Errorf("[%s] backend login: %w", name, err)
	}

	if appCfg.StorageType == "google" && appCfg.GoogleFolderID == "" {
		log.Printf("[%s] Searching for Google Drive folder 'Flow-Data'...", name)
		folderID, err := backend.FindFolder(ctx, "Flow-Data")
		if err != nil {
			return fmt.Errorf("[%s] find folder: %w", name, err)
		}
		if folderID == "" {
			log.Printf("[%s] 'Flow-Data' not found. Creating new folder...", name)
			folderID, err = backend.CreateFolder(ctx, "Flow-Data")
			if err != nil {
				return fmt.Errorf("[%s] create folder: %w", name, err)
			}
		} else {
			log.Printf("[%s] Found existing folder %s", name, folderID)
		}
		appCfg.GoogleFolderID = folderID
		if err := appCfg.Save(configPath); err != nil {
			log.Printf("[%s] WARN: failed to save folder ID: %v", name, err)
		}
	}

	if appCfg.StorageType == "google" {
		return runFlowProfile(ctx, name, appCfg, gcPath)
	}

	engine := transport.NewEngine(backend, false, "")
	if appCfg.RefreshRateMs > 0 {
		engine.SetPollRate(appCfg.RefreshRateMs)
	}
	if appCfg.FlushRateMs > 0 {
		engine.SetFlushRate(appCfg.FlushRateMs)
	}

	engine.OnNewSession = func(sessionID, targetAddr string, session *transport.Session) {
		log.Printf("[%s] new session %s -> %s", name, sessionID, targetAddr)
		go handleServerConn(sessionID, targetAddr, session, engine)
	}

	engine.Start(ctx)
	log.Printf("[%s] profile started", name)
	return nil
}

func runFlowProfile(ctx context.Context, name string, appCfg *config.AppConfig, gcPath string) error {
	flowCfg, err := config.BuildFlowConfig(appCfg, gcPath, "", false)
	if err != nil {
		return fmt.Errorf("[%s] high-speed transport config: %w", name, err)
	}
	log.Printf("[%s] initializing high-speed Drive transport", name)
	data, err := flow.StoresFromConfig(ctx, flowCfg)
	if err != nil {
		return fmt.Errorf("[%s] high-speed storage init: %w", name, err)
	}
	tunnel, err := flow.NewTunnel(data, flowCfg)
	if err != nil {
		return fmt.Errorf("[%s] high-speed transport init: %w", name, err)
	}
	go func() {
		if err := tunnel.ServeExit(ctx); err != nil && ctx.Err() == nil {
			log.Printf("[%s] high-speed exit failed: %v", name, err)
		}
	}()
	log.Printf("[%s] high-speed profile started", name)
	return nil
}

// runMultiProfile scans profilesDir for subdirectories, each containing
// server_config.json + credentials.json (+ optional credentials.json.token).
// Each subdir is launched as an isolated engine. The directory is re-scanned
// periodically; new subdirs are started, removed subdirs are cancelled.
func runMultiProfile(rootCtx context.Context, profilesDir string) {
	if err := os.MkdirAll(profilesDir, 0755); err != nil {
		log.Fatalf("Cannot create profiles dir %s: %v", profilesDir, err)
	}
	log.Printf("Multi-profile mode: scanning %s", profilesDir)

	type running struct {
		cancel context.CancelFunc
	}
	active := make(map[string]running)
	var mu sync.Mutex

	scan := func() {
		entries, err := os.ReadDir(profilesDir)
		if err != nil {
			log.Printf("scan error: %v", err)
			return
		}
		seen := make(map[string]bool)
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			name := e.Name()
			seen[name] = true

			mu.Lock()
			_, alreadyRunning := active[name]
			mu.Unlock()
			if alreadyRunning {
				continue
			}

			profileDir := filepath.Join(profilesDir, name)
			cfgPath := filepath.Join(profileDir, "server_config.json")
			credPath := filepath.Join(profileDir, "credentials.json")
			if _, err := os.Stat(cfgPath); err != nil {
				continue
			}
			if _, err := os.Stat(credPath); err != nil {
				continue
			}

			profileCtx, cancel := context.WithCancel(rootCtx)
			if err := runProfile(profileCtx, name, cfgPath, credPath); err != nil {
				log.Printf("[%s] failed to start: %v", name, err)
				cancel()
				continue
			}
			mu.Lock()
			active[name] = running{cancel: cancel}
			mu.Unlock()
		}

		// Cancel engines whose subdir was removed
		mu.Lock()
		for name, r := range active {
			if !seen[name] {
				log.Printf("[%s] profile removed; stopping engine", name)
				r.cancel()
				delete(active, name)
			}
		}
		mu.Unlock()
	}

	scan()
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-rootCtx.Done():
				return
			case <-ticker.C:
				scan()
			}
		}
	}()
}

func handleServerConn(sessionID, targetAddr string, session *transport.Session, engine *transport.Engine) {
	defer engine.RemoveSession(sessionID)

	conn, err := net.Dial("tcp", targetAddr)
	if err != nil {
		log.Printf("Dial error to %s: %v", targetAddr, err)
		return
	}
	defer conn.Close()

	errCh := make(chan error, 2)

	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				session.EnqueueTx(buf[:n])
			}
			if err != nil {
				errCh <- err
				return
			}
		}
	}()

	go func() {
		for {
			data, ok := <-session.RxChan
			if !ok {
				errCh <- fmt.Errorf("session closed by remote")
				return
			}
			if len(data) > 0 {
				if _, err := conn.Write(data); err != nil {
					errCh <- err
					return
				}
			}
		}
	}()

	<-errCh
}
