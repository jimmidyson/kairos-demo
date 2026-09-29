apiVersion: apps/v1
kind: Deployment
metadata:
  name: operator-kairos-operator
  namespace: operator-system
spec:
  template:
    spec:
      containers:
        - name: manager
          image: quay.io/kairos/operator:${KAIROS_OPERATOR_REF}
          env:
            - name: OPERATOR_IMAGE
              value: quay.io/kairos/operator:${KAIROS_OPERATOR_REF}
            - name: NODE_LABELER_IMAGE
              value: quay.io/kairos/operator-node-labeler:${KAIROS_OPERATOR_REF}
