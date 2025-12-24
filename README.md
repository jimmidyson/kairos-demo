# Kairos Demo

A demonstration project showcasing how to build CIS-hardened Ubuntu-based bootable images using [Kairos](https://kairos.io/) and deploy them to Nutanix infrastructure.

## Overview

This project demonstrates:

- Building CIS Level 1 Server hardened Ubuntu 24.04 base images using Ubuntu Pro
- Creating Kairos-based bootable ISOs with custom configurations
- Using Kairos OSBuilder operator in a Kubernetes cluster
- Deploying the resulting ISO to Nutanix infrastructure using Terraform
- Configuring systemd-sysext for extensible system hierarchies

## Architecture

The project consists of three Docker images built in sequence:

1. **Base Image** (`Dockerfile.base`): CIS-hardened Ubuntu 24.04 with Kairos initialization
2. **Bootstrap Image** (`Dockerfile.bootstrap`): Based on the base image, used for creating bootable ISO
3. **Final Image** (`Dockerfile.final`): Production-ready image based on the base

The demo script automates the entire workflow from building images to creating a bootable ISO that can be deployed to bare metal or virtual machines.

## Prerequisites

### Required Tools

This project uses [Devbox](https://www.jetify.com/devbox) for managing development dependencies. Install Devbox, then run:

```bash
devbox shell
```

This will provide:

- `crane` - Container registry interaction
- `kind` - Kubernetes in Docker
- `kubernetes-helm` - Helm package manager
- `opentofu` - Infrastructure as Code (Terraform alternative)
- `pv` - Pipe viewer for progress monitoring
- `envsubst` - Environment variable substitution

### Additional Requirements

- Docker with BuildKit support
- Ubuntu Pro token (for CIS hardening)
- Access to a Nutanix cluster (for deployment)

### Environment Variables

Set the following environment variables before running the demo:

```bash
export VERSION="v1.0.0"                    # Version tag for images
export OCI_REGISTRY="your-registry.com"    # Your container registry
export UBUNTU_PRO_TOKEN="your-token"       # Ubuntu Pro token for CIS hardening
```

## Quick Start

### 1. Build and Create ISO

Run the demo script to build images and create a bootable ISO:

```bash
./demo.sh
```

This script will:

1. Build the CIS-hardened base image with Ubuntu Pro
2. Build bootstrap and final images
3. Create a KIND cluster
4. Install cert-manager and Kairos CRDs
5. Install Kairos OSBuilder operator
6. Create a bootable ISO from the bootstrap image
7. Download the ISO as `bootstrap.iso`

### 2. Deploy to Nutanix (Optional)

If you have access to a Nutanix cluster, you can deploy the ISO using Terraform:

```bash
cd terraform
export NUTANIX_ENDPOINT="prism-central.example.com:9440"
export NUTANIX_USERNAME="your-username"
export NUTANIX_PASSWORD="your-password"
tofu init
tofu apply \
  -var="cluster_name=your-cluster" \
  -var="subnet_name=your-subnet"
```

This will:

1. Upload the `bootstrap.iso` to Nutanix
2. Create a VM with 4 vCPUs and 8GB RAM
3. Attach the ISO as a CDROM
4. Create a 100GB disk for installation
5. Output the VM's IP address

## Configuration

### Cloud Config

The `cloud-config.yaml` file contains the Kairos configuration, including:

- **User Management**: Creates an `nkpadmin` user with SSH keys from GitHub
- **Auto-Install**: Automatically installs to available disk and reboots
- **systemd-sysext**: Configures extensible system hierarchies for `/opt` and other directories
- **UKI Boot Support**: Special handling for Unified Kernel Image boot mode

### SSH Access

The demo is configured to allow SSH access for users:

- `jimmidyson`
- `dkoshkin`
- `yannickstruyf3`

Modify the `ssh_authorized_keys` section in `cloud-config.yaml` to add your own GitHub username or SSH keys.

## Project Structure

```plain
.
├── demo.sh                      # Main demo automation script
├── cloud-config.yaml            # Kairos cloud-init configuration
├── install-cloud-config.yaml    # Alternative installation config
├── dockerfiles/
│   ├── Dockerfile.base          # CIS-hardened Ubuntu base
│   ├── Dockerfile.bootstrap     # Bootstrap image for ISO
│   ├── Dockerfile.final         # Final production image
│   ├── Dockerfile.cniplugins    # CNI plugins (if needed)
│   ├── Dockerfile.containerd    # Containerd (if needed)
│   └── Dockerfile.runc          # runc (if needed)
└── terraform/
    ├── main.tf                  # Nutanix VM and image resources
    ├── variables.tf             # Input variables
    └── terraform.tf             # Provider configuration
```

## Security Features

### CIS Hardening

The base image is hardened using Ubuntu Security Guide (USG) to meet CIS Level 1 Server benchmarks, including:

- System access controls
- File permissions and ownership
- Network configuration hardening
- Service restrictions
- Audit logging
- User account policies

## Customization

### Modifying the Base Image

Edit `dockerfiles/Dockerfile.base` to:

- Change the base Ubuntu version
- Add additional packages
- Apply different CIS profiles
- Include custom configurations

### Customizing Cloud Config

Edit `cloud-config.yaml` to:

- Add more users
- Configure additional systemd units
- Install packages at first boot
- Set up networking
- Configure storage layouts

### Multi-Architecture Support

All images are built for both `linux/arm64` and `linux/amd64` platforms using Docker BuildKit:

```bash
docker buildx build --platform=linux/arm64,linux/amd64 ...
```

## Troubleshooting

### Build Failures

If image builds fail:

1. Ensure Docker BuildKit is enabled: `export DOCKER_BUILDKIT=1`
2. Verify your Ubuntu Pro token is valid
3. Check network connectivity to package repositories

### KIND Cluster Issues

If the KIND cluster fails to create:

1. Check Docker is running and accessible
2. Ensure ports 80, 443, and 6443 are available
3. Verify you have sufficient resources (4GB+ RAM recommended)

### ISO Generation Timeout

The script waits up to 60 minutes for ISO generation. If this times out:

1. Check the OSBuilder pod logs: `kubectl logs -n kairos-system -l app.kubernetes.io/name=osbuilder`
2. Verify the OSArtifact status: `kubectl describe osartifacts/bootstrap-iso`
3. Ensure sufficient disk space is available

### Nutanix Deployment Issues

If Terraform apply fails:

1. Verify your Nutanix credentials
2. Check the cluster and subnet names exist
3. Ensure you have permissions to create VMs and upload images

## Advanced Usage

### Using Custom OCI Registry

To use a different container registry:

```bash
export OCI_REGISTRY="ghcr.io/your-org"
```

Ensure you're authenticated to the registry:

```bash
docker login ${OCI_REGISTRY}
```

### Building Only Specific Images

You can comment out sections in `demo.sh` to build only specific images:

```bash
# Comment out base image build if it already exists
# print "Building CIS hardened base image..."
# docker buildx build ...
```

### Local Testing with QEMU

Instead of deploying to Nutanix, you can test the ISO locally:

```bash
qemu-system-x86_64 \
  -m 4096 \
  -smp 2 \
  -cdrom bootstrap.iso \
  -drive file=disk.img,format=qcow2,if=virtio \
  -boot d \
  -enable-kvm
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is provided as-is for demonstration purposes.

## Resources

- [Kairos Documentation](https://kairos.io/docs/)
- [Ubuntu Security Guide](https://ubuntu.com/security/certifications/docs/usg)
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks)
- [systemd-sysext](https://www.freedesktop.org/software/systemd/man/systemd-sysext.html)
- [Nutanix Terraform Provider](https://registry.terraform.io/providers/nutanix/nutanix/latest/docs)
