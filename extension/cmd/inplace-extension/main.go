package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/jimmidyson/kairos-demo/extension"
)

func updateMachineSSH(user, host, keyPath, registry, version string, controlPlane bool) error {
	script, err := extension.RemoteUpgradeScript(registry, version, controlPlane)
	if err != nil {
		return err
	}
	key, err := privateKeyFile(keyPath)
	if err != nil {
		return err
	}
	defer os.Remove(key)
	return sshRun(user, host, key, script)
}

func privateKeyFile(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	f, err := os.CreateTemp("", "inplace-ssh-*")
	if err != nil {
		return "", err
	}
	name := f.Name()
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		os.Remove(name)
		return "", err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		os.Remove(name)
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(name)
		return "", err
	}
	return name, nil
}

func sshRun(user, host, keyPath, remote string) error {
	args := []string{
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "UserKnownHostsFile=/tmp/known_hosts",
		"-o", "BatchMode=yes",
		"-i", keyPath,
		user + "@" + host,
		"bash", "-s",
	}
	cmd := exec.Command("ssh", args...)
	cmd.Stdin = strings.NewReader(remote)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "serve":
		if err := serve(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "can-update":
		// usage: inplace-extension can-update curImg wantImg curVer wantVer
		if len(os.Args) != 6 {
			fmt.Fprintln(os.Stderr, "usage: inplace-extension can-update currentImage desiredImage currentVer desiredVer")
			os.Exit(2)
		}
		if !extension.CanUpdateInPlace(os.Args[2], os.Args[3], os.Args[4], os.Args[5]) {
			os.Exit(1)
		}
	case "update-machine":
		// usage: inplace-extension update-machine user host key registry version cp|worker
		if len(os.Args) != 8 {
			fmt.Fprintln(os.Stderr, "usage: inplace-extension update-machine user host keyPath registry version cp|worker")
			os.Exit(2)
		}
		cp := os.Args[7] == "cp"
		if err := updateMachineSSH(os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6], cp); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: inplace-extension serve|can-update|update-machine ...")
	os.Exit(2)
}
