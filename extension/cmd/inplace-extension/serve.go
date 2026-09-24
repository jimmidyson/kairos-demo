package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sync"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"

	runtimehooksv1 "sigs.k8s.io/cluster-api/api/runtime/hooks/v1alpha1"
	runtimecatalog "sigs.k8s.io/cluster-api/exp/runtime/catalog"
	"sigs.k8s.io/cluster-api/exp/runtime/server"

	"github.com/jimmidyson/kairos-demo/extension"
)

type updateJob struct {
	mu   sync.Mutex
	done bool
	err  error
}

type updater struct {
	dyn              dynamic.Interface
	keyPath          string
	user             string
	registryFallback string
	jobs             sync.Map
}

func serve() error {
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return fmt.Errorf("in-cluster config: %w", err)
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return err
	}
	catalog := runtimecatalog.New()
	if err := runtimehooksv1.AddToCatalog(catalog); err != nil {
		return err
	}
	certDir := os.Getenv("WEBHOOK_CERT_DIR")
	if certDir == "" {
		certDir = "/certs"
	}
	srv, err := server.New(server.Options{
		Catalog: catalog,
		Port:    9443,
		CertDir: certDir,
	})
	if err != nil {
		return err
	}
	u := &updater{
		dyn:              dyn,
		keyPath:          getenv("SSH_KEY_PATH", "/etc/ssh-key/id"),
		user:             getenv("SSH_USER", "nkpadmin"),
		registryFallback: os.Getenv("IMAGE_PREFIX"),
	}
	timeout := int32(30)
	handlers := []server.ExtensionHandler{
		{Hook: runtimehooksv1.CanUpdateMachine, Name: "can-update-machine", HandlerFunc: u.CanUpdateMachine, TimeoutSeconds: &timeout},
		{Hook: runtimehooksv1.CanUpdateMachineSet, Name: "can-update-machineset", HandlerFunc: u.CanUpdateMachineSet, TimeoutSeconds: &timeout},
		{Hook: runtimehooksv1.UpdateMachine, Name: "update-machine", HandlerFunc: u.UpdateMachine, TimeoutSeconds: &timeout},
	}
	for _, h := range handlers {
		if err := srv.AddExtensionHandler(h); err != nil {
			return err
		}
	}
	return srv.Start(ctrl.SetupSignalHandler())
}

func (u *updater) CanUpdateMachine(_ context.Context, req *runtimehooksv1.CanUpdateMachineRequest, resp *runtimehooksv1.CanUpdateMachineResponse) {
	plan, err := planPair(
		mustJSON(req.Current.Machine), mustJSON(req.Desired.Machine),
		req.Current.InfrastructureMachine.Raw, req.Desired.InfrastructureMachine.Raw,
		req.Current.BootstrapConfig.Raw, req.Desired.BootstrapConfig.Raw,
	)
	if err != nil {
		resp.SetStatus(runtimehooksv1.ResponseStatusFailure)
		resp.SetMessage(err.Error())
		return
	}
	resp.SetStatus(runtimehooksv1.ResponseStatusSuccess)
	if !plan.Cover {
		resp.SetMessage("not an in-place kubernetes version change")
		return
	}
	resp.SetMessage("in-place")
	setPatch(&resp.InfrastructureMachinePatch, plan.InfraPatch)
	setPatch(&resp.MachinePatch, plan.MachinePatch)
	setPatch(&resp.BootstrapConfigPatch, plan.BootstrapPatch)
}

func (u *updater) CanUpdateMachineSet(_ context.Context, req *runtimehooksv1.CanUpdateMachineSetRequest, resp *runtimehooksv1.CanUpdateMachineSetResponse) {
	plan, err := planPair(
		mustJSON(req.Current.MachineSet), mustJSON(req.Desired.MachineSet),
		req.Current.InfrastructureMachineTemplate.Raw, req.Desired.InfrastructureMachineTemplate.Raw,
		req.Current.BootstrapConfigTemplate.Raw, req.Desired.BootstrapConfigTemplate.Raw,
	)
	if err != nil {
		resp.SetStatus(runtimehooksv1.ResponseStatusFailure)
		resp.SetMessage(err.Error())
		return
	}
	resp.SetStatus(runtimehooksv1.ResponseStatusSuccess)
	if !plan.Cover {
		resp.SetMessage("not an in-place kubernetes version change")
		return
	}
	resp.SetMessage("in-place")
	setPatch(&resp.InfrastructureMachineTemplatePatch, plan.InfraPatch)
	setPatch(&resp.MachineSetPatch, plan.MachinePatch)
	setPatch(&resp.BootstrapConfigTemplatePatch, plan.BootstrapPatch)
}

func (u *updater) UpdateMachine(ctx context.Context, req *runtimehooksv1.UpdateMachineRequest, resp *runtimehooksv1.UpdateMachineResponse) {
	m := req.Desired.Machine
	key := m.Namespace + "/" + m.Name
	if v, ok := u.jobs.Load(key); ok {
		j := v.(*updateJob)
		j.mu.Lock()
		done, err := j.done, j.err
		j.mu.Unlock()
		if !done {
			resp.SetStatus(runtimehooksv1.ResponseStatusSuccess)
			resp.SetRetryAfterSeconds(15)
			resp.SetMessage("update in progress")
			return
		}
		u.jobs.Delete(key)
		if err != nil {
			resp.SetStatus(runtimehooksv1.ResponseStatusFailure)
			resp.SetMessage(err.Error())
			return
		}
		resp.SetStatus(runtimehooksv1.ResponseStatusSuccess)
		resp.SetMessage("updated")
		return
	}

	raw := mustJSON(m)
	version := extension.SpecVersion(raw)
	registry := extension.RegistryFromCommands(req.Desired.BootstrapConfig.Raw)
	if registry == "" {
		registry = u.registryFallback
	}
	addr, labels, err := u.machineStatus(ctx, m.APIVersion, m.Namespace, m.Name)
	if err != nil {
		resp.SetStatus(runtimehooksv1.ResponseStatusFailure)
		resp.SetMessage(err.Error())
		return
	}
	if addr == "" {
		resp.SetStatus(runtimehooksv1.ResponseStatusSuccess)
		resp.SetRetryAfterSeconds(15)
		resp.SetMessage("waiting for a machine address")
		return
	}
	if len(m.Labels) > 0 {
		labels = m.Labels
	}
	cp := controlPlane(labels)
	j := &updateJob{}
	if _, loaded := u.jobs.LoadOrStore(key, j); loaded {
		resp.SetStatus(runtimehooksv1.ResponseStatusSuccess)
		resp.SetRetryAfterSeconds(15)
		resp.SetMessage("update in progress")
		return
	}
	go func() {
		err := updateMachineSSH(u.user, addr, u.keyPath, registry, version, cp)
		j.mu.Lock()
		j.err = err
		j.done = true
		j.mu.Unlock()
	}()
	resp.SetStatus(runtimehooksv1.ResponseStatusSuccess)
	resp.SetRetryAfterSeconds(15)
	resp.SetMessage("update started")
}

func (u *updater) machineStatus(ctx context.Context, apiVersion, namespace, name string) (string, map[string]string, error) {
	gvr := machineGVR(apiVersion)
	obj, err := u.dyn.Resource(gvr).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil && apiVersion != "cluster.x-k8s.io/v1beta1" {
		obj, err = u.dyn.Resource(machineGVR("cluster.x-k8s.io/v1beta1")).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	}
	if err != nil {
		return "", nil, err
	}
	return pickAddress(obj), obj.GetLabels(), nil
}

func machineGVR(apiVersion string) schema.GroupVersionResource {
	gv, err := schema.ParseGroupVersion(apiVersion)
	if err != nil || gv.Group == "" {
		gv = schema.GroupVersion{Group: "cluster.x-k8s.io", Version: "v1beta2"}
	}
	if gv.Version == "" {
		gv.Version = "v1beta2"
	}
	return schema.GroupVersionResource{Group: gv.Group, Version: gv.Version, Resource: "machines"}
}

func pickAddress(u *unstructured.Unstructured) string {
	addrs, _, _ := unstructured.NestedSlice(u.Object, "status", "addresses")
	var internal, external, other string
	for _, a := range addrs {
		m, ok := a.(map[string]any)
		if !ok {
			continue
		}
		addr, _ := m["address"].(string)
		if addr == "" {
			continue
		}
		switch m["type"] {
		case "InternalIP":
			internal = addr
		case "ExternalIP":
			external = addr
		default:
			if other == "" {
				other = addr
			}
		}
	}
	if internal != "" {
		return internal
	}
	if external != "" {
		return external
	}
	return other
}

func controlPlane(labels map[string]string) bool {
	if labels == nil {
		return false
	}
	_, ok := labels["cluster.x-k8s.io/control-plane"]
	return ok
}

func planPair(curM, desM, curI, desI, curB, desB []byte) (extension.Plan, error) {
	return extension.PlanInPlace(extension.SpecVersion(curM), extension.SpecVersion(desM),
		extension.Doc{Current: curI, Desired: desI},
		extension.Doc{Current: curM, Desired: desM},
		extension.Doc{Current: curB, Desired: desB},
	)
}

func setPatch(dst *runtimehooksv1.Patch, raw []byte) {
	if len(raw) == 0 {
		return
	}
	*dst = runtimehooksv1.Patch{PatchType: runtimehooksv1.JSONPatchType, Patch: raw}
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return b
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
