#!/bin/bash

mkdir -p /usr/local/.state/var-lib-nkp.bind/k8s/images/

cp -rfv /opt/container-images/*.tar /usr/local/.state/var-lib-nkp.bind/k8s/images/
