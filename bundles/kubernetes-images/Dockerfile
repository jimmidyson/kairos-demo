FROM docker.io/mesosphere/nkp-image-builder:v2.17.0-rc.1 AS nib


FROM scratch
COPY run.sh /
COPY --from=nib /opt/container-images/ /opt/container-images/
