apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - https://github.com/kairos-io/kairos-operator/config/default?ref=${KAIROS_OPERATOR_REF}
  - https://github.com/kairos-io/kairos-operator/config/nginx?ref=${KAIROS_OPERATOR_REF}

patches:
  - path: operator-deployment-patch.yaml
