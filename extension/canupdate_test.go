package extension

import (
	"strings"
	"testing"
)

func TestCanUpdateInPlace(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name                             string
		curImg, wantImg, curVer, wantVer string
		ok                               bool
	}{
		{"version only", "ubuntu-24.04-amd64", "ubuntu-24.04-amd64", "v1.35.8", "v1.36.4", true},
		{"same version", "ubuntu-24.04-amd64", "ubuntu-24.04-amd64", "v1.36.4", "v1.36.4", false},
		{"image changed", "ubuntu-24.04-amd64", "ubuntu-22.04-amd64", "v1.35.8", "v1.36.4", false},
		{"empty image", "", "ubuntu-24.04-amd64", "v1.35.8", "v1.36.4", false},
		{"empty desired ver", "ubuntu-24.04-amd64", "ubuntu-24.04-amd64", "v1.35.8", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := CanUpdateInPlace(tc.curImg, tc.wantImg, tc.curVer, tc.wantVer)
			if got != tc.ok {
				t.Fatalf("got %v want %v", got, tc.ok)
			}
		})
	}
}

func obj(spec string) []byte {
	return []byte(`{"apiVersion":"v1","kind":"X","spec":` + spec + `}`)
}

func TestPlanInPlaceVersionOnly(t *testing.T) {
	t.Parallel()
	infra := obj(`{"image":{"name":"kairos-ubuntu-24.04-amd64"},"vcpuSockets":1}`)
	cur := obj(`{"version":"v1.35.8"}`)
	des := obj(`{"version":"v1.36.4"}`)
	bootC := obj(`{"preKubeadmCommands":["prepare-capi-node --registry h.example/p --kubernetes-version v1.35.8"]}`)
	bootD := obj(`{"preKubeadmCommands":["prepare-capi-node --registry h.example/p --kubernetes-version v1.36.4"]}`)
	plan, err := PlanInPlace("v1.35.8", "v1.36.4",
		Doc{infra, infra}, Doc{cur, des}, Doc{bootC, bootD})
	if err != nil {
		t.Fatal(err)
	}
	if !plan.Cover {
		t.Fatal("expected cover")
	}
	if plan.InfraPatch != nil {
		t.Fatalf("infra patch = %s", plan.InfraPatch)
	}
	if !strings.Contains(string(plan.MachinePatch), "v1.36.4") {
		t.Fatalf("machine patch = %s", plan.MachinePatch)
	}
	if !strings.Contains(string(plan.BootstrapPatch), "v1.36.4") {
		t.Fatalf("bootstrap patch = %s", plan.BootstrapPatch)
	}
}

func TestPlanInPlaceRejects(t *testing.T) {
	t.Parallel()
	baseInfra := obj(`{"image":{"name":"kairos"},"vcpuSockets":1}`)
	cur := obj(`{"version":"v1.35.8"}`)
	des := obj(`{"version":"v1.36.4"}`)
	boot := obj(`{"preKubeadmCommands":["prepare-capi-node --kubernetes-version v1.35.8"]}`)
	bootNew := obj(`{"preKubeadmCommands":["prepare-capi-node --kubernetes-version v1.36.4"]}`)
	cases := []struct {
		name          string
		infraD, bootD []byte
	}{
		{"image changed", obj(`{"image":{"name":"other"},"vcpuSockets":1}`), bootNew},
		{"cpu changed", obj(`{"image":{"name":"kairos"},"vcpuSockets":4}`), bootNew},
		{"empty image", obj(`{"vcpuSockets":1}`), bootNew},
		{"command flag", baseInfra, obj(`{"preKubeadmCommands":["prepare-capi-node --kubernetes-version v1.36.4 --extra"]}`)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			infraD := tc.infraD
			if infraD == nil {
				infraD = baseInfra
			}
			plan, err := PlanInPlace("v1.35.8", "v1.36.4",
				Doc{baseInfra, infraD}, Doc{cur, des}, Doc{boot, tc.bootD})
			if err != nil {
				t.Fatal(err)
			}
			if plan.Cover {
				t.Fatal("expected rollout")
			}
		})
	}
}

func TestPlanInPlaceTemplateImage(t *testing.T) {
	t.Parallel()
	infra := obj(`{"template":{"spec":{"image":{"uuid":"abc"}}}}`)
	cur := obj(`{"template":{"spec":{"version":"v1.35.8"}}}`)
	des := obj(`{"template":{"spec":{"version":"v1.36.4"}}}`)
	plan, err := PlanInPlace("v1.35.8", "v1.36.4", Doc{infra, infra}, Doc{cur, des}, Doc{})
	if err != nil {
		t.Fatal(err)
	}
	if !plan.Cover {
		t.Fatal("expected cover")
	}
	if SpecVersion(des) != "v1.36.4" {
		t.Fatalf("version %s", SpecVersion(des))
	}
}

func TestRegistryFromCommands(t *testing.T) {
	t.Parallel()
	raw := obj(`{"preKubeadmCommands":["prepare-capi-node --registry harbor.example/proj --kubernetes-version v1.35.8"]}`)
	if got := RegistryFromCommands(raw); got != "harbor.example/proj" {
		t.Fatalf("got %q", got)
	}
}

func TestRemoteUpgradeScript(t *testing.T) {
	t.Parallel()
	cp, err := RemoteUpgradeScript("harbor.example/proj", "v1.36.4", true)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(cp, "kubeadm upgrade apply 'v1.36.4' --yes") {
		t.Fatalf("control plane script:\n%s", cp)
	}
	worker, err := RemoteUpgradeScript("harbor.example/proj", "v1.36.4", false)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(worker, "kubeadm upgrade node") || strings.Contains(worker, "upgrade apply") {
		t.Fatalf("worker script:\n%s", worker)
	}
	if _, err := RemoteUpgradeScript("bad prefix", "v1.36.4", false); err == nil {
		t.Fatal("expected invalid registry")
	}
	if _, err := RemoteUpgradeScript("harbor.example/proj", "latest", true); err == nil {
		t.Fatal("expected invalid version")
	}
}
