//go:build darwin && cgo

// TapTether Screen Core is installed once and not replaced by agent updates.
// macOS Screen Recording consent belongs to this long-lived executable,
// rather than the frequently updated taptether-agent binary.
package main

/*
#cgo LDFLAGS: -lproc
#include <libproc.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
static int tt_screen_peer(int fd, uid_t *uid, pid_t *pid) {
  gid_t gid; socklen_t length = sizeof(*pid);
  if (getpeereid(fd, uid, &gid) != 0) return -1;
  return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, pid, &length);
}
static int tt_screen_pid_path(pid_t pid, char *buffer, uint32_t count) {
  return proc_pidpath(pid, buffer, count);
}
*/
import "C"

import (
  "bufio"
  "bytes"
  "crypto/subtle"
  "encoding/json"
  "errors"
  "flag"
  "fmt"
  "io"
  "log"
  "net"
  "os"
  "os/exec"
  "path/filepath"
  "strings"
  "sync"
  "syscall"
  "time"
  "unsafe"

  "github.com/ssnanda/taptether.com/agent/internal/screencap"
)

var version = "dev"
var captureMu sync.Mutex

type request struct {
  Protocol int    `json:"protocol"`
  Token    string `json:"token"`
  Action   string `json:"action"`
}
type reply struct {
  Width  int    `json:"width,omitempty"`
  Height int    `json:"height,omitempty"`
  Length int    `json:"length,omitempty"`
  Error  string `json:"error,omitempty"`
}

func main() {
  showVersion := flag.Bool("version", false, "show Screen Core version")
  flag.Parse()
  if *showVersion { fmt.Println(version); return }
  if !screencap.Available() { log.Fatal("ScreenCaptureKit requires macOS 14 or newer") }

  dir, err := os.UserConfigDir()
  must(err)
  dir = filepath.Join(dir, "taptether", "screen-core")
  info, err := os.Stat(dir)
  must(err)
  if !info.IsDir() || info.Mode().Perm() != 0700 {
    log.Fatal("Screen Core directory must be mode 0700")
  }
  tokenBytes, err := os.ReadFile(filepath.Join(dir, "ipc.token"))
  must(err)
  token := strings.TrimSpace(string(tokenBytes))
  if len(token) != 64 { log.Fatal("invalid Screen Core token") }
  must(verifySigningPeer())

  socket := filepath.Join(dir, "screen.sock")
  if stat, err := os.Lstat(socket); err == nil {
    if stat.Mode()&os.ModeSocket == 0 {
      log.Fatal("refusing to replace non-socket screen.sock")
    }
    must(os.Remove(socket))
  } else if !os.IsNotExist(err) { must(err) }
  listener, err := net.Listen("unix", socket)
  must(err)
  must(os.Chmod(socket, 0600))
  defer listener.Close()
  for {
    conn, err := listener.Accept()
    if err != nil { log.Printf("screen accept: %v", err); continue }
    go serve(conn, token)
  }
}

func serve(conn net.Conn, token string) {
  defer conn.Close()
  _ = conn.SetDeadline(time.Now().Add(7*time.Second))
  peer, ok := conn.(*net.UnixConn)
  if !ok || authorizePeer(peer) != nil { return }
  reader := bufio.NewReaderSize(conn, 4096)
  line, err := reader.ReadSlice('\n')
  if err != nil || len(line) > 1024 {
    send(conn, reply{Error:"invalid screen request"})
    return
  }
  var req request
  dec := json.NewDecoder(bytes.NewReader(line))
  dec.DisallowUnknownFields()
  if dec.Decode(&req) != nil || dec.Decode(new(any)) != io.EOF ||
      req.Protocol != 1 || req.Action != "capture" ||
      len(req.Token) != len(token) ||
      subtle.ConstantTimeCompare([]byte(req.Token), []byte(token)) != 1 {
    send(conn, reply{Error:"unauthorized screen request"})
    return
  }
  captureMu.Lock()
  frame, err := screencap.Capture()
  captureMu.Unlock()
  if err != nil { send(conn, reply{Error:err.Error()}); return }
  if len(frame.JPEG) < 1 || len(frame.JPEG) > 2<<20 ||
      frame.Width < 1 || frame.Width > 1280 ||
      frame.Height < 1 || frame.Height > 720 {
    send(conn, reply{Error:"invalid captured frame"})
    return
  }
  if err := json.NewEncoder(conn).Encode(reply{
      Width:frame.Width, Height:frame.Height, Length:len(frame.JPEG),
  }); err != nil { return }
  _, _ = conn.Write(frame.JPEG)
}
func send(w io.Writer, response reply) {
  _ = json.NewEncoder(w).Encode(response)
}
func must(err error) { if err != nil { log.Fatal(err) } }

func installedAgentPath() string {
  home, err := os.UserHomeDir()
  if err != nil { return "" }
  return filepath.Join(home, ".local", "bin", "taptether-agent")
}

func authorizePeer(conn *net.UnixConn) error {
  raw, err := conn.SyscallConn()
  if err != nil { return err }
  var check error
  err = raw.Control(func(fd uintptr) {
    var uid C.uid_t
    var pid C.pid_t
    if C.tt_screen_peer(C.int(fd), &uid, &pid) != 0 {
      check = errors.New("missing peer credentials"); return
    }
    if int(uid) != os.Getuid() {
      check = errors.New("peer user mismatch"); return
    }
    buf := make([]byte, 4096)
    n := C.tt_screen_pid_path(pid,
      (*C.char)(unsafe.Pointer(&buf[0])), C.uint32_t(len(buf)))
    if n <= 0 {
      check = errors.New("missing peer path"); return
    }
    path := C.GoString((*C.char)(unsafe.Pointer(&buf[0])))
    if path != installedAgentPath() {
      check = errors.New("client is not the installed TapTether agent"); return
    }
    stat, err := os.Lstat(path)
    if err != nil || !stat.Mode().IsRegular() ||
        stat.Mode()&os.ModeSymlink != 0 || stat.Mode().Perm()&0022 != 0 {
      check = errors.New("agent executable is insecure"); return
    }
    owner, ok := stat.Sys().(*syscall.Stat_t)
    if !ok || int(owner.Uid) != os.Getuid() {
      check = errors.New("agent executable owner mismatch")
    }
  })
  if err != nil { return err }
  return check
}

func verifySigningPeer() error {
  own, err := os.Executable()
  if err != nil { return err }
  agent := installedAgentPath()
  for _, binary := range []string{own, agent} {
    output, err := exec.Command("/usr/bin/codesign", "--verify", "--strict", binary).CombinedOutput()
    if err != nil {
      return fmt.Errorf("invalid code signature for %s: %s",
        filepath.Base(binary), strings.TrimSpace(string(output)))
    }
  }
  team := func(path string) string {
    output, _ := exec.Command("/usr/bin/codesign",
      "-dv", "--verbose=4", path).CombinedOutput()
    for _, line := range strings.Split(string(output), "\n") {
      if strings.HasPrefix(line, "TeamIdentifier=") {
        return strings.TrimPrefix(line, "TeamIdentifier=")
      }
    }
    return ""
  }
  if team(own) != team(agent) {
    return errors.New("agent and Screen Core signing teams differ")
  }
  return nil
}
