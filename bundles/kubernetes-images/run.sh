#!/bin/bash

mkdir -p /usr/local/.state/var-lib-containerd.bind/

cp -rfv ./var/lib/containerd/* /usr/local/.state/var-lib-containerd.bind/
