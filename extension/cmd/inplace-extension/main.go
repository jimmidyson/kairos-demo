package main

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/jimmidyson/kairos-demo/extension"
)

// Tiny SSH-based UpdateMachine helper used by the Runtime Extension.
// Full CAPI Runtime SDK wiring is in main_runtime.go when CAPI_RUNTIME=1.
func updateMachineSSH(user, host, keyPath, registry, version string, controlPlane bool) error {
	cmdLine := fmt.Sprintf("sudo prepare-capi-node --registry %s --kubernetes-version %s", registry, version)
	if err := sshRun(user, host, keyPath, cmdLine); err != nil {
		return err
	}
	if controlPlane {
		return sshRun(user, host, keyPath, fmt.Sprintf("sudo kubeadm upgrade apply %s --yes", version))
	}
	return sshRun(user, host, keyPath, "sudo kubeadm upgrade node")
}

func sshRun(user, host, keyPath, remote string) error {
	args := []string{"-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes"}
	if keyPath != "" {
		args = append(args, "-i", keyPath)
	}
	args = append(args, user+"@"+host, remote)
	cmd := exec.Command("ssh", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func decide(currentImage, desiredImage, currentVer, desiredVer string) bool {
	return extension.CanUpdateInPlace(currentImage, desiredImage, currentVer, desiredVer)
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "can-update" {
		// usage: inplace-extension can-update curImg wantImg curVer wantVer
		if len(os.Args) != 6 {
			fmt.Fprintln(os.Stderr, "usage: inplace-extension can-update currentImage desiredImage currentVer desiredVer")
			os.Exit(2)
		}
		ok := decide(os.Args[2], os.Args[3], os.Args[4], os.Args[5])
		if !ok {
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "update-machine" {
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
		return
	}
	fmt.Fprintln(os.Stderr, "usage: inplace-extension can-update|update-machine ...")
	os.Exit(2)
}
