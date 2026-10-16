//go:build !darwin || !cgo

package main

import "github.com/ssnanda/taptether.com/agent/internal/screencap"

// Other desktop agents continue to use their existing capture backends.
func captureScreenFrame() (screencap.Frame, error) {
  return screencap.Capture()
}
