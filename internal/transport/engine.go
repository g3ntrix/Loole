package transport

import (
	"context"
	"fmt"
	"io"
	"log"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/NullLatency/flow-driver/internal/storage"
)

// Engine manages the local sessions, periodically flushes Tx buffers to files,
// and polls for new Rx files.
type Engine struct {
	backend storage.Backend
	myDir   Direction // DirReq for client, DirRes for server
	peerDir Direction // DirRes for client, DirReq for server
	id      string    // ClientID for client, empty for server

	sessions  map[string]*Session
	sessionMu sync.RWMutex

	// Tombstones for recently closed sessions to prevent re-triggering on delayed packets
	closedSessions   map[string]time.Time
	closedSessionsMu sync.Mutex

	pollTicker  time.Duration
	flushTicker time.Duration

	// Server mode handler: called when a new session is discovered
	OnNewSession func(sessionID, targetAddr string, s *Session)

	// Concurrency control for storage operations (Upload/Download)
	sem chan struct{}

	// Track processed files to avoid duplicates
	processed   map[string]bool
	processedMu sync.Mutex

	// Traffic stats
	bytesTx uint64
	bytesRx uint64
}

func NewEngine(backend storage.Backend, isClient bool, clientID string) *Engine {
	e := &Engine{
		backend:        backend,
		id:             clientID,
		sessions:       make(map[string]*Session),
		closedSessions: make(map[string]time.Time),
		processed:      make(map[string]bool),
		// Default intervals: Poll (RX) fast for responsiveness, Flush (TX) slower for gathering
		pollTicker:  500 * time.Millisecond,
		flushTicker: 300 * time.Millisecond,
	}
	if isClient {
		e.myDir = DirReq
		e.peerDir = DirRes
	} else {
		e.myDir = DirRes
		e.peerDir = DirReq
	}
	// Limit to 8 concurrent upload/download operations to avoid OOM and FD exhaustion
	e.sem = make(chan struct{}, 8)
	return e
}

func (e *Engine) SetRefreshRate(ms int) {
	if ms > 0 {
		e.pollTicker = time.Duration(ms) * time.Millisecond
		// Legacy behavior: sets both if FlushTicker was still at default
		if e.flushTicker == 300*time.Millisecond {
			e.flushTicker = time.Duration(ms) * time.Millisecond
		}
	}
}

func (e *Engine) SetPollRate(ms int) {
	if ms > 0 {
		e.pollTicker = time.Duration(ms) * time.Millisecond
	}
}

func (e *Engine) SetFlushRate(ms int) {
	if ms > 0 {
		e.flushTicker = time.Duration(ms) * time.Millisecond
	}
}

func (e *Engine) Start(ctx context.Context) {
	go e.flushLoop(ctx)
	go e.pollLoop(ctx)
	go e.cleanupLoop(ctx) // Delete files older than 10s
}

func (e *Engine) GetSession(id string) *Session {
	e.sessionMu.RLock()
	defer e.sessionMu.RUnlock()
	return e.sessions[id]
}

func (e *Engine) AddSession(s *Session) {
	e.sessionMu.Lock()
	defer e.sessionMu.Unlock()
	e.sessions[s.ID] = s
	log.Printf("Engine.AddSession: Added session %s (Total now: %d)", s.ID, len(e.sessions))
}

func (e *Engine) flushLoop(ctx context.Context) {
	ticker := time.NewTicker(e.flushTicker)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			e.flushAll(ctx)
		}
	}
}

func (e *Engine) flushAll(ctx context.Context) {
	e.sessionMu.Lock()
	sessions := make([]*Session, 0, len(e.sessions))
	for _, s := range e.sessions {
		sessions = append(sessions, s)
	}
	e.sessionMu.Unlock()

	muxes := make(map[string][]Envelope)
	var closedSessionIDs []string

	for _, s := range sessions {
		s.mu.Lock()

		// Idle Timeout check
		if time.Since(s.lastActivity) > 10*time.Second {
			s.closed = true
		}

		shouldSend := len(s.txBuf) > 0 || (s.txSeq == 0 && e.myDir == DirReq) || s.closed

		if !shouldSend {
			s.mu.Unlock()
			continue
		}

		payload := s.txBuf
		s.txBuf = nil
		s.txCond.Broadcast() // Release any blocked writers

		env := Envelope{
			SessionID:  s.ID,
			Seq:        s.txSeq,
			Payload:    payload,
			Close:      s.closed,
			TargetAddr: s.TargetAddr,
		}

		atomic.AddUint64(&e.bytesTx, uint64(len(payload)))

		s.txSeq++
		if s.closed {
			closedSessionIDs = append(closedSessionIDs, s.ID)
		}

		cid := s.ClientID
		if cid == "" && e.myDir == DirReq {
			cid = e.id // For client requests, use our own ID
		}

		muxes[cid] = append(muxes[cid], env)
		s.mu.Unlock()
	}

	if len(muxes) > 0 {
		// log.Printf("Engine.flushAll: Prepared muxes for %d clients", len(muxes))
	}

	for cid, mux := range muxes {
		// Filename format: {dir}-{clientID}-mux-{timestamp}.bin
		fnameCID := cid
		if fnameCID == "" {
			fnameCID = "unknown"
		}
		filename := fmt.Sprintf("%s-%s-mux-%d.bin", e.myDir, fnameCID, time.Now().UnixNano())

		// Upload asynchronously with backpressure/limit
		go func(fname string, m []Envelope) {
			e.sem <- struct{}{}        // Acquire
			defer func() { <-e.sem }() // Release

			pr, pw := io.Pipe()
			go func() {
				defer pw.Close()
				for _, env := range m {
					if err := env.Encode(pw); err != nil {
						log.Printf("mux encode error: %v", err)
						break
					}
				}
			}()

			if err := e.backend.Upload(ctx, fname, pr); err != nil {
				log.Printf("upload error %s: %v", fname, err)
			}
		}(filename, mux)
	}

	for _, id := range closedSessionIDs {
		e.RemoveSession(id)
	}
}

func (e *Engine) pollLoop(ctx context.Context) {
	currentPollInterval := e.pollTicker
	maxPollInterval := 5 * time.Second
	timer := time.NewTimer(currentPollInterval)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		pollAgain:
			// ZERO-TRAFFIC CLIENT OPTIMIZATION:
			// SOCKS5 only initiates from the Client. If the Client has 0 active sessions,
			// it mathematically never needs to poll Google Drive! Go entirely to sleep!
			if e.myDir == DirReq {
				e.sessionMu.RLock()
				count := len(e.sessions)
				e.sessionMu.RUnlock()
				if count == 0 {
					timer.Reset(currentPollInterval)
					continue
				}
			}

			// Fetch multiplexed files
			prefix := string(e.peerDir) + "-"
			if e.myDir == DirReq {
				// Client only polls for its own responses
				prefix += e.id + "-mux-"
			} else {
				// Server polls for ALL client requests
				prefix += ""
			}
			files, err := e.backend.ListQuery(ctx, prefix)
			if err != nil {
				log.Printf("poll list error: %v", err)
				timer.Reset(currentPollInterval)
				continue
			}

			if len(files) == 0 {
				if e.myDir == DirRes { // SERVER OPTIMIZATION
					e.sessionMu.RLock()
					activeSessions := len(e.sessions)
					e.sessionMu.RUnlock()

					if activeSessions == 0 {
						// Increase polling delay step-by-step to save API calls
						currentPollInterval += 500 * time.Millisecond
						if currentPollInterval > maxPollInterval {
							currentPollInterval = maxPollInterval
						}
					} else {
						// A session is currently active, so loop fast!
						currentPollInterval = e.pollTicker
					}
				}
				// Client optimization doesn't change intervals, but needs its timer reset
				timer.Reset(currentPollInterval)
				continue
			}

			// We found data! Reset polling back to maximum speed
			currentPollInterval = e.pollTicker

			// We found files! Let's download them in parallel to boost speed massively
			var wg sync.WaitGroup
			for _, f := range files {
				// STARTUP OPTIMIZATION: Ignore files older than 5 minutes to avoid memory spikes on restart
				parts := strings.Split(f, "-")
				if len(parts) >= 3 {
					tsStr := parts[len(parts)-1]
					tsStr = strings.TrimSuffix(tsStr, ".bin")
					ts, _ := strconv.ParseInt(tsStr, 10, 64)
					if ts > 0 && time.Since(time.Unix(0, ts)) > 5*time.Minute {
						e.backend.Delete(ctx, f) // Silent cleanup
						continue
					}
				}

				e.processedMu.Lock()
				already := e.processed[f]
				if !already {
					e.processed[f] = true
				}
				e.processedMu.Unlock()

				if already {
					continue
				}

				wg.Add(1)
				go func(fname string) {
					defer wg.Done()

					e.sem <- struct{}{}        // Acquire
					defer func() { <-e.sem }() // Release

					// log.Printf("Engine.pollLoop: Downloading %s", fname)
					rc, err := e.backend.Download(ctx, fname)
					if err != nil {
						log.Printf("download error %s: %v", fname, err)
						e.processedMu.Lock()
						delete(e.processed, fname) // failed to download, retry next poll
						e.processedMu.Unlock()
						return
					}
					defer rc.Close()

					// Extract ClientID from filename for server-side session initialization.
					// Format: {dir}-{clientID}-mux-{timestamp}.bin
					// clientID may itself contain dashes, so split on the first "-"
					// and locate "-mux-" to find the boundary.
					var fileClientID string
					if dashIdx := strings.Index(fname, "-"); dashIdx >= 0 {
						rest := fname[dashIdx+1:]
						if muxIdx := strings.Index(rest, "-mux-"); muxIdx >= 0 {
							fileClientID = rest[:muxIdx]
						}
					}

					// STREAMING DECODE
					count := 0
					for {
						var env Envelope
						if err := env.Decode(rc); err != nil {
							if err != io.EOF && err != io.ErrUnexpectedEOF {
								log.Printf("mux decode error %s: %v", fname, err)
							}
							break
						}
						count++
						atomic.AddUint64(&e.bytesRx, uint64(len(env.Payload)))

						// Process envelope immediately
						e.closedSessionsMu.Lock()
						if _, exists := e.closedSessions[env.SessionID]; exists {
							e.closedSessionsMu.Unlock()
							continue
						}
						e.closedSessionsMu.Unlock()

						e.sessionMu.Lock()
						s, exists := e.sessions[env.SessionID]
						if !exists && e.myDir == DirRes && e.OnNewSession != nil {
							s = NewSession(env.SessionID)
							s.ClientID = fileClientID
							e.sessions[env.SessionID] = s
							e.sessionMu.Unlock()
							log.Printf("Engine: Triggering new session %s for Client %s", env.SessionID, fileClientID)
							e.OnNewSession(env.SessionID, env.TargetAddr, s)
						} else {
							e.sessionMu.Unlock()
						}

						if s != nil {
							s.ProcessRx(&env)
						}
					}

					e.backend.Delete(ctx, fname)
				}(f)
			}

			// Wait for parallel batch to finish
			wg.Wait()

			// Adaptive Polling: Because we just received data, the connection is active.
			// Instead of jumping back to the select, immediately poll again after a tiny 100ms break to drain queues.
			time.Sleep(100 * time.Millisecond)
			goto pollAgain
		}
	}
}

func (e *Engine) RemoveSession(id string) {
	e.sessionMu.Lock()
	delete(e.sessions, id)
	e.sessionMu.Unlock()

	// Add to tombstone list
	e.closedSessionsMu.Lock()
	e.closedSessions[id] = time.Now()
	e.closedSessionsMu.Unlock()
}

func (e *Engine) cleanupLoop(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Cleanup old tombstones (older than 30s)
			e.closedSessionsMu.Lock()
			for id, t := range e.closedSessions {
				if time.Since(t) > 30*time.Second {
					delete(e.closedSessions, id)
				}
			}
			e.closedSessionsMu.Unlock()

			// Periodically clear processed map to prevent infinite growth
			e.processedMu.Lock()
			if len(e.processed) > 5000 {
				e.processed = make(map[string]bool)
			}
			e.processedMu.Unlock()

			// ZERO-TRAFFIC CLIENT OPTIMIZATION:
			if e.myDir == DirReq {
				e.sessionMu.RLock()
				count := len(e.sessions)
				e.sessionMu.RUnlock()
				if count == 0 {
					continue
				}
			}

			files, _ := e.backend.ListQuery(ctx, string(e.myDir)+"-")
			for _, f := range files {
				parts := strings.Split(f, "-")
				// Formats:
				// OLD: "req", "UUID...", "Seq", "Timestamp.json" (len >= 4)
				// MUX: "req", "mux", "Timestamp.json" (len >= 3)
				if len(parts) >= 3 {
					tsStr := parts[len(parts)-1]
					tsStr = strings.TrimSuffix(tsStr, ".json")
					tsStr = strings.TrimSuffix(tsStr, ".bin")
					ts, err := strconv.ParseInt(tsStr, 10, 64)
					if err == nil {
						t := time.Unix(0, ts)
						if time.Since(t) > 10*time.Second {
							e.backend.Delete(ctx, f)
						}
					}
				}
			}
		}
	}
}

func (e *Engine) GetStats() (uint64, uint64) {
	return atomic.LoadUint64(&e.bytesTx), atomic.LoadUint64(&e.bytesRx)
}
