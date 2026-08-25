apiVersion: v1
kind: Secret
metadata:
  name: cloud-config-${OS}-${ARCH}
type: Opaque
stringData:
  userdata: |
${CLOUD_CONFIG}
---
apiVersion: build.kairos.io/v1alpha2
kind: OSArtifact
metadata:
  name: cloud-${OS}-${ARCH}
spec:
  imageName: ${BASE_IMAGE}
  cloudImage: true
  cloudConfigRef:
    name: cloud-config-${OS}-${ARCH}
    key: userdata
  artifacts:
    arch: ${ARCH}
  imageCredentialsSecretRef:
    name: oci-registry-secret
  exporters:
    - template:
        spec:
          restartPolicy: Never
          containers:
            - name: upload
              image: quay.io/curl/curl:8.17.0
              command: ["sh", "-ec"]
              args:
                - |
                  NGINX_URL="${NGINX_URL:-http://kairos-operator-nginx}"
                  for f in /artifacts/*; do
                    [ -f "$f" ] || continue
                    base=$(basename "$f")
                    echo "Uploading $base"
                    curl -fsSL -T "$f" "$NGINX_URL/$base" || exit 1
                  done
              env:
                - name: NGINX_URL
                  value: http://kairos-operator-nginx
              volumeMounts:
                - name: artifacts
                  mountPath: /artifacts
                  readOnly: true
