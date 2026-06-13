# ---------------------------------------------------------------------------
# Kafka ZooKeeper -> KRaft migration agent
#
# Red Hat UBI9 Python 3.12 base. OpenShift-compatible: runs as an arbitrary
# non-root UID in group 0, no fixed username, all app files group-writable.
#
# Build:
#   podman build -t kafka-migration-agent:latest .
# Run (help):
#   podman run --rm kafka-migration-agent:latest --help
# ---------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/python-312:latest

# OpenShift mirror channel for the `oc` client. Override at build time to pin a
# specific OCP version, e.g. --build-arg OC_VERSION=4.16.0
ARG OC_VERSION=stable
# Populated automatically by the builder from the target platform (amd64/arm64).
ARG TARGETARCH=amd64

# The UBI Python images default to USER 1001; become root only to install the
# `oc`/`kubectl` clients into a system path.
USER 0

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) OC_ARCH="" ;;        \
        arm64) OC_ARCH="-arm64" ;;  \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    OC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux${OC_ARCH}.tar.gz"; \
    curl -fsSL "${OC_URL}" -o /tmp/oc.tar.gz; \
    tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc kubectl; \
    chmod 0755 /usr/local/bin/oc /usr/local/bin/kubectl; \
    rm -f /tmp/oc.tar.gz; \
    /usr/local/bin/oc version --client

# Application lives under the UBI app-root (already owned by group 0, writable).
WORKDIR /opt/app-root/src

# Install uv (used to build the virtualenv from the committed lockfile).
RUN pip install --no-cache-dir uv

# Resolve dependencies first for better layer caching. uv creates the venv at
# /opt/app-root/src/.venv from the frozen lockfile (no dev deps).
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# Application source.
COPY src ./src

# Make the project importable and put the venv on PATH so `python` is the venv's.
ENV PATH="/opt/app-root/src/.venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Ensure an arbitrary OpenShift UID (member of group 0) can read/execute
# everything and write where uv/python may need to.
RUN chgrp -R 0 /opt/app-root/src /usr/local/bin/oc /usr/local/bin/kubectl && \
    chmod -R g=u /opt/app-root/src

# Drop back to the non-root numeric UID expected by the restricted-v2 SCC.
USER 1001

# Args (namespace, kafka-instance, options) are supplied via CMD / Job args / rsh.
ENTRYPOINT ["python", "-m", "src.main"]
CMD ["--help"]
