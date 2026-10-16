package main

import (
    "fmt"
    "net/http"
    "strconv"
    "sync"
    "time"

    "github.com/ssnanda/taptether.com/agent/internal/screencap"
)

var screenCaptureLock sync.Mutex
var liveViewerSlot = make(chan struct{}, 1)

func registerScreenEndpoints(mux *http.ServeMux, access *identityAPI) {
    authorize := func(w http.ResponseWriter, r *http.Request) bool {
        w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
        w.Header().Set("Pragma", "no-cache")
        w.Header().Set("X-Content-Type-Options", "nosniff")
        if r.Method != http.MethodGet {
            http.Error(w, "GET required", http.StatusMethodNotAllowed)
            return false
        }
        if r.TLS == nil || !privateRemote(r.RemoteAddr) {
            http.Error(w, "LAN TLS required", http.StatusForbidden)
            return false
        }
        if !access.authorized(r) {
            http.Error(w, "not paired", http.StatusUnauthorized)
            return false
        }
        if !screencap.Available() {
            http.Error(w, "screen capture not supported on this agent yet", http.StatusNotImplemented)
            return false
        }
        return true
    }
    mux.HandleFunc("/api/snapshot", func(w http.ResponseWriter, r *http.Request) {
        if !authorize(w, r) { return }
        screenCaptureLock.Lock()
        frame, err := captureScreenFrame()
        screenCaptureLock.Unlock()
        if err != nil {
            http.Error(w, err.Error(), http.StatusForbidden)
            return
        }
        w.Header().Set("Content-Type", "image/jpeg")
        w.Header().Set("Content-Length", strconv.Itoa(len(frame.JPEG)))
        w.Header().Set("X-Screen-Width", strconv.Itoa(frame.Width))
        w.Header().Set("X-Screen-Height", strconv.Itoa(frame.Height))
        _, _ = w.Write(frame.JPEG)
    })
    mux.HandleFunc("/api/live", func(w http.ResponseWriter, r *http.Request) {
        if !authorize(w, r) { return }
        select {
        case liveViewerSlot <- struct{}{}:
            defer func() { <-liveViewerSlot }()
        default:
            http.Error(w, "another live viewer is active", http.StatusTooManyRequests)
            return
        }
        flusher, ok := w.(http.Flusher)
        if !ok {
            http.Error(w, "streaming not supported", http.StatusNotImplemented)
            return
        }
        // Keep the regular server write timeout for all other endpoints.
        // Only the authenticated active stream gets a renewed deadline.
        deadlines := http.NewResponseController(w)
        if err := deadlines.SetWriteDeadline(time.Now().Add(5*time.Second)); err != nil {
            http.Error(w, "stream write deadlines unavailable", http.StatusNotImplemented)
            return
        }
        // Capture once before sending the 200 response: an OS permission
        // denial must remain an actionable HTTP error, not a blank stream.
        screenCaptureLock.Lock()
        frame, err := captureScreenFrame()
        screenCaptureLock.Unlock()
        if err != nil {
            http.Error(w, err.Error(), http.StatusForbidden)
            return
        }
        // MJPEG preview targets 720p / 30 fps as an initial local transport.
        // The loop naturally drops FPS if encoding cannot keep up.
        w.Header().Set("Content-Type", "multipart/x-mixed-replace; boundary=ttframe")
        w.Header().Set("Connection", "close")
        ticker := time.NewTicker(time.Second / 30)
        defer ticker.Stop()
        // A long-lived connection must not outlive the paired session indefinitely.
        lifetime := time.NewTimer(14 * time.Minute)
        defer lifetime.Stop()
        for {
            select {
            case <-r.Context().Done(): return
            case <-lifetime.C: return
            default:
            }
            if err := deadlines.SetWriteDeadline(time.Now().Add(5*time.Second)); err != nil { return }
            header := fmt.Sprintf("--ttframe\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\nX-Screen-Width: %d\r\nX-Screen-Height: %d\r\n\r\n", len(frame.JPEG), frame.Width, frame.Height)
            if _, err := w.Write([]byte(header)); err != nil { return }
            if _, err := w.Write(frame.JPEG); err != nil { return }
            if _, err := w.Write([]byte("\r\n")); err != nil { return }
            flusher.Flush()
            select {
            case <-r.Context().Done(): return
            case <-lifetime.C: return
            case <-ticker.C:
            }
            screenCaptureLock.Lock()
            frame, err = captureScreenFrame()
            screenCaptureLock.Unlock()
            if err != nil { return }
        }
    })
}
