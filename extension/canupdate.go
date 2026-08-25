package extension

// CanUpdateInPlace is the CAPI in-place gate: same Nutanix disk image,
// Kubernetes version (and thus sysext + image tags) is the only diff.
func CanUpdateInPlace(currentImage, desiredImage, currentVer, desiredVer string) bool {
	if currentImage == "" || desiredImage == "" {
		return false
	}
	if currentImage != desiredImage {
		return false
	}
	if desiredVer == "" || currentVer == desiredVer {
		return false
	}
	return true
}
