//go:build darwin && cgo

package main

import (
  "bufio"
  "encoding/json"
  "errors"
  "fmt"
  "io"
  "net"
  "os"
  "path/filepath"
  "strings"
  "time"

  "github.com/ssnanda/taptether.com/agent/internal/screencap"
)

// One approved Screen Core survives routine binary updates to the HTTP agent.
// Retain the 0.7 legacy path only until a Screen Core is installed; after
// installation all capture permission errors come from the stable Core.
func captureScreenFrame() (screencap.Frame, error) {
  home, err := os.UserHomeDir()
  if err != nil { return screencap.Frame{}, err }
  core := filepath.Join(home, ".local", "bin", "taptether-screen-core")
  if _, err := os.Stat(core); os.IsNotExist(err) {
    return screencap.Capture()
  } else if err != nil {
    return screencap.Frame{}, err
  }
  config, err := os.UserConfigDir()
  if err != nil { return screencap.Frame{}, err }
  dir := filepath.Join(config, "taptether", "screen-core")
  token, err := os.ReadFile(filepath.Join(dir, "ipc.token"))
  if err != nil {
    return screencap.Frame{}, errors.New("TapTether Screen Core needs repair; authorization token missing")
  }
  key := strings.TrimSpace(string(token))
  if len(key) != 64 {
    return screencap.Frame{}, errors.New("TapTether Screen Core authorization is invalid")
  }
  conn, err := net.DialTimeout("unix", filepath.Join(dir, "screen.sock"), time.Second)
  if err != nil {
    return screencap.Frame{}, fmt.Errorf("TapTether Screen Core is unavailable; start or repair it: %w", err)
  }
  defer conn.Close()
  _ = conn.SetDeadline(time.Now().Add(7 * time.Second))
  request := struct {
    Protocol int    `json:"protocol"`
    Token    string `json:"token"`
    Action   string `json:"action"`
  }{1, key, "capture"}
  if err := json.NewEncoder(conn).Encode(request); err != nil {
    return screencap.Frame{}, err
  }
  reader := bufio.NewReaderSize(conn, 1024)
  header, err := reader.ReadSlice('\n')
  if err != nil || len(header) > 1024 {
    return screencap.Frame{}, errors.New("Screen Core sent an invalid response")
  }
  var info struct {
    Width int `json:"width"`
    Height int `json:"height"`
    Length int `json:"length"`
    Error string `json:"error"`
  }
  decoder := json.NewDecoder(strings.NewReader(string(header)))
  decoder.DisallowUnknownFields()
  if decoder.Decode(&info) != nil || decoder.Decode(new(any)) != io.EOF {
    return screencap.Frame{}, errors.New("Screen Core sent malformed metadata")
  }
  if info.Error != "" {
    return screencap.Frame{}, errors.New(info.Error)
  }
  if info.Length < 1 || info.Length > (2<<20) ||
      info.Width < 1 || info.Width > 1280 ||
      info.Height < 1 || info.Height > 720 {
    return screencap.Frame{}, errors.New("Screen Core frame outside capture limits")
  }
  data := make([]byte, info.Length)
  if _, err := io.ReadFull(reader, data); err != nil {
    return screencap.Frame{}, fmt.Errorf("Screen Core frame incomplete: %w", err)
  }
  return screencap.Frame{JPEG:data, Width:info.Width, Height:info.Height}, nil
}
