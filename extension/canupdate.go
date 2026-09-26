package extension

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

var (
	versionPattern  = regexp.MustCompile(`^v\d+\.\d+\.\d+$`)
	registryPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.:/-]*$`)
)

// CanUpdateInPlace is true when the Nutanix disk image is unchanged and the
// Kubernetes version is changing. Callers that have the full object specs
// should use PlanInPlace, which also rejects diffs outside the version.
func CanUpdateInPlace(currentImage, desiredImage, currentVer, desiredVer string) bool {
	if currentImage == "" || desiredImage == "" || currentImage != desiredImage {
		return false
	}
	if desiredVer == "" || currentVer == desiredVer {
		return false
	}
	return true
}

// Doc is a current/desired Kubernetes object JSON pair.
type Doc struct {
	Current []byte
	Desired []byte
}

// Plan is the in-place decision for one machine or machine set.
// Cover is false when CAPI must roll a new VM. Patches are JSON patches
// (RFC 6902) that replace /spec, and are nil when that spec is unchanged.
type Plan struct {
	Cover          bool
	InfraPatch     []byte
	MachinePatch   []byte
	BootstrapPatch []byte
}

// PlanInPlace allows an in-place update only when the infrastructure image
// identity is non-empty and unchanged, and every spec differs only by the
// Kubernetes version string (including inside preKubeadmCommands).
func PlanInPlace(curVer, desVer string, infra, machine, bootstrap Doc) (Plan, error) {
	var p Plan
	imgC, err := imageIdentity(infra.Current)
	if err != nil {
		return p, err
	}
	imgD, err := imageIdentity(infra.Desired)
	if err != nil {
		return p, err
	}
	if imgC == "" || imgD == "" || imgC != imgD || curVer == "" || desVer == "" {
		return p, nil
	}
	for _, d := range []Doc{infra, machine, bootstrap} {
		ok, err := versionOnly(d.Current, d.Desired, curVer, desVer)
		if err != nil {
			return Plan{}, err
		}
		if !ok {
			return Plan{}, nil
		}
	}
	p.Cover = true
	p.InfraPatch, err = specPatchIfChanged(infra.Current, infra.Desired)
	if err != nil {
		return Plan{}, err
	}
	p.MachinePatch, err = specPatchIfChanged(machine.Current, machine.Desired)
	if err != nil {
		return Plan{}, err
	}
	p.BootstrapPatch, err = specPatchIfChanged(bootstrap.Current, bootstrap.Desired)
	if err != nil {
		return Plan{}, err
	}
	return p, nil
}

// SpecVersion reads spec.version, or spec.template.spec.version on a template.
func SpecVersion(raw []byte) string {
	obj, err := unmarshalObj(raw)
	if err != nil {
		return ""
	}
	spec := asMap(obj["spec"])
	if s, _ := spec["version"].(string); s != "" {
		return s
	}
	tmpl := asMap(spec["template"])
	s, _ := asMap(tmpl["spec"])["version"].(string)
	return s
}

// RegistryFromCommands returns the --registry value from preKubeadmCommands.
func RegistryFromCommands(raw []byte) string {
	obj, err := unmarshalObj(raw)
	if err != nil {
		return ""
	}
	spec := asMap(obj["spec"])
	cmds := commandList(spec["preKubeadmCommands"])
	if len(cmds) == 0 {
		tmpl := asMap(spec["template"])
		cmds = commandList(asMap(tmpl["spec"])["preKubeadmCommands"])
	}
	for _, c := range cmds {
		fields := strings.Fields(c)
		for i, f := range fields {
			if f == "--registry" && i+1 < len(fields) {
				return fields[i+1]
			}
		}
	}
	return ""
}

// RemoteUpgradeScript is the node-local upgrade. The version and registry are
// shell-quoted. A marker makes a repeat call skip kubeadm once it has succeeded.
func RemoteUpgradeScript(registry, version string, controlPlane bool) (string, error) {
	if !versionPattern.MatchString(version) {
		return "", fmt.Errorf("invalid kubernetes version %q", version)
	}
	if !registryPattern.MatchString(registry) {
		return "", fmt.Errorf("invalid registry %q", registry)
	}
	qreg, qver := shellQuote(registry), shellQuote(version)
	upgrade := "sudo kubeadm upgrade node"
	if controlPlane {
		upgrade = "sudo kubeadm upgrade apply " + qver + " --yes"
	}
	return fmt.Sprintf(`set -euo pipefail
sudo prepare-capi-node --registry %s --kubernetes-version %s
marker=/var/lib/extensions/kubeadm-upgraded
if [ "$(cat "$marker" 2>/dev/null || true)" = %s ]; then
  exit 0
fi
if ! out=$(%s 2>&1); then
  printf '%%s\n' "$out" >&2
  printf '%%s\n' "$out" | grep -Eqi 'already (at|upgraded)|is the same version' && exit 0
  exit 1
fi
printf '%%s\n' %s | sudo tee "$marker" >/dev/null
`, qreg, qver, qver, upgrade, qver), nil
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func versionOnly(cur, des []byte, curVer, desVer string) (bool, error) {
	c1, err := canonSpec(cur, curVer, desVer)
	if err != nil {
		return false, err
	}
	c2, err := canonSpec(des, curVer, desVer)
	if err != nil {
		return false, err
	}
	return c1 == c2, nil
}

func specPatchIfChanged(cur, des []byte) ([]byte, error) {
	c1, err := canonSpec(cur, "", "")
	if err != nil {
		return nil, err
	}
	c2, err := canonSpec(des, "", "")
	if err != nil {
		return nil, err
	}
	if c1 == c2 {
		return nil, nil
	}
	return jsonPatchReplaceSpec(des)
}

func jsonPatchReplaceSpec(desired []byte) ([]byte, error) {
	obj, err := unmarshalObj(desired)
	if err != nil {
		return nil, err
	}
	spec, ok := obj["spec"]
	if !ok {
		return nil, fmt.Errorf("desired object has no spec")
	}
	patch := []map[string]any{{
		"op":    "replace",
		"path":  "/spec",
		"value": spec,
	}}
	return json.Marshal(patch)
}

func canonSpec(raw []byte, verA, verB string) (string, error) {
	obj, err := unmarshalObj(raw)
	if err != nil {
		return "", err
	}
	if obj == nil {
		return "", nil
	}
	spec, ok := obj["spec"]
	if !ok {
		return "", nil
	}
	b, err := json.Marshal(normAny(spec, verA, verB))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func unmarshalObj(raw []byte) (map[string]any, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) || bytes.Equal(raw, []byte("{}")) {
		return nil, nil
	}
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, err
	}
	return obj, nil
}

func normAny(v any, verA, verB string) any {
	switch t := v.(type) {
	case string:
		return normString(t, verA, verB)
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, child := range t {
			out[k] = normAny(child, verA, verB)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, child := range t {
			out[i] = normAny(child, verA, verB)
		}
		return out
	default:
		return v
	}
}

func normString(s, a, b string) string {
	if a == "" && b == "" {
		return s
	}
	if len(a) < len(b) {
		a, b = b, a
	}
	if a != "" {
		s = strings.ReplaceAll(s, a, "VER")
	}
	if b != "" && b != a {
		s = strings.ReplaceAll(s, b, "VER")
	}
	return s
}

func imageIdentity(raw []byte) (string, error) {
	obj, err := unmarshalObj(raw)
	if err != nil || obj == nil {
		return "", err
	}
	return imageFromSpec(asMap(obj["spec"])), nil
}

func imageFromSpec(spec map[string]any) string {
	if spec == nil {
		return ""
	}
	if id := imageField(spec["image"]); id != "" {
		return id
	}
	tmpl := asMap(spec["template"])
	return imageField(asMap(tmpl["spec"])["image"])
}

func imageField(v any) string {
	switch t := v.(type) {
	case string:
		if t != "" {
			return "name=" + t
		}
	case map[string]any:
		if n, _ := t["name"].(string); n != "" {
			return "name=" + n
		}
		if u, _ := t["uuid"].(string); u != "" {
			return "uuid=" + u
		}
	}
	return ""
}

func commandList(v any) []string {
	raw, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, c := range raw {
		if s, ok := c.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}
