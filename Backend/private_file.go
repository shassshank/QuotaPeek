package main

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
)

// CreateTemp uses a unique name and mode 0600; rename publishes a complete file.
func atomicPrivateWrite(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+"-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

// Rotate at startup. Clients read the file for each request, including hooks.
func createAuthToken(path string) (string, error) {
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	token := hex.EncodeToString(random[:])
	if err := atomicPrivateWrite(path, []byte(token)); err != nil {
		return "", err
	}
	return token, nil
}
