package config

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"

	"github.com/NullLatency/flow-driver/internal/flow"
)

type googleOAuthJSON struct {
	Installed googleOAuthClient `json:"installed"`
	Web       googleOAuthClient `json:"web"`
}

type googleOAuthClient struct {
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
	TokenURI     string `json:"token_uri"`
}

type flowTokenCache struct {
	RefreshToken string `json:"refresh_token"`
}

func BuildFlowConfig(app *AppConfig, credentialsPath, listenAddr string, client bool) (*flow.Config, error) {
	if app == nil {
		return nil, fmt.Errorf("nil app config")
	}
	if strings.TrimSpace(app.GoogleFolderID) == "" {
		return nil, fmt.Errorf("google folder id is required for the high-speed transport")
	}

	auth, err := flowAuthFromCredentials(credentialsPath)
	if err != nil {
		return nil, err
	}

	clientCfg := flow.ClientConfig{}
	if client {
		clientID := strings.TrimSpace(app.ClientID)
		if clientID == "" {
			return nil, fmt.Errorf("client id is required for the high-speed transport")
		}
		runID, err := flow.RandomRunID()
		if err != nil {
			return nil, err
		}
		clientCfg = flow.ClientConfig{ID: clientID, RunID: runID}
	}

	cfg := &flow.Config{
		Secret:    derivedFlowSecret(app.GoogleFolderID),
		SessionID: derivedFlowSessionID(app.GoogleFolderID),
		Client:    clientCfg,
		Auth:      auth,
		Route:     flowRouteFromApp(app),
		Drive:     flow.DriveConfig{FolderID: app.GoogleFolderID},
		Tunnel: flow.TunnelConfig{
			Listen:            listenAddr,
			Profile:           "auto",
			Transport:         "muxv4",
			ExitIPFamily:      "prefer_ipv4",
			BurstPoll:         true,
			BurstPollMS:       50,
			BurstPollWindowMS: 5000,
			ChunkSize:         16 * 1024 * 1024,
			PollIntervalMS:    75,
			Concurrency:       32,
			CleanupProcessed:  true,
		},
	}
	cfg.ApplyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return cfg, nil
}

func flowAuthFromCredentials(credentialsPath string) (flow.AuthConfig, error) {
	data, err := os.ReadFile(credentialsPath)
	if err != nil {
		return flow.AuthConfig{}, fmt.Errorf("read Google credentials: %w", err)
	}
	var oauth googleOAuthJSON
	if err := json.Unmarshal(data, &oauth); err != nil {
		return flow.AuthConfig{}, fmt.Errorf("parse Google credentials: %w", err)
	}
	client := oauth.Installed
	if strings.TrimSpace(client.ClientID) == "" {
		client = oauth.Web
	}
	if strings.TrimSpace(client.ClientID) == "" {
		return flow.AuthConfig{}, fmt.Errorf("Google credentials missing OAuth client id")
	}

	var token flowTokenCache
	tokenData, err := os.ReadFile(credentialsPath + ".token")
	if err != nil {
		return flow.AuthConfig{}, fmt.Errorf("read Google refresh token cache: %w", err)
	}
	if err := json.Unmarshal(tokenData, &token); err != nil {
		return flow.AuthConfig{}, fmt.Errorf("parse Google refresh token cache: %w", err)
	}
	if strings.TrimSpace(token.RefreshToken) == "" {
		return flow.AuthConfig{}, fmt.Errorf("Google refresh token cache is empty")
	}

	tokenURI := strings.TrimSpace(client.TokenURI)
	if tokenURI == "" {
		tokenURI = "https://oauth2.googleapis.com/token"
	}
	return flow.AuthConfig{
		ClientID:     strings.TrimSpace(client.ClientID),
		ClientSecret: strings.TrimSpace(client.ClientSecret),
		RefreshToken: strings.TrimSpace(token.RefreshToken),
		TokenURL:     tokenURI,
	}, nil
}

func flowRouteFromApp(app *AppConfig) flow.RouteConfig {
	route := flow.RouteConfig{
		Mode:           "real_pinned",
		GoogleIP:       "216.239.38.120",
		TimeoutSeconds: 240,
	}
	target := strings.TrimSpace(app.Transport.TargetIP)
	if target == "" {
		return route
	}
	host, _, err := net.SplitHostPort(target)
	if err == nil {
		target = host
	}
	route.GoogleIP = target
	return route
}

func derivedFlowSecret(mailbox string) string {
	sum := sha256.Sum256([]byte("loole-flow-secret:" + strings.TrimSpace(mailbox)))
	return "base64:" + base64.StdEncoding.EncodeToString(sum[:])
}

func derivedFlowSessionID(mailbox string) string {
	sum := sha256.Sum256([]byte("loole-flow-session:" + strings.TrimSpace(mailbox)))
	return hex.EncodeToString(sum[:16])
}
