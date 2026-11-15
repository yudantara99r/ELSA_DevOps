FROM debian:bookworm-slim

# BuildKit sets TARGETARCH to amd64 or arm64.
ARG TARGETARCH
ENV TARGETARCH=${TARGETARCH} \
    K3D_VERSION=5.9.0 \
    KUBECTL_VERSION=1.37.2 \
    HELM_VERSION=4.3.2 \
    TERRAFORM_VERSION=1.17.2 \
    K6_VERSION=2.4.0 \
    IN_TOOLBOX=1 \
    KUBECONFIG=/root/.kube/config \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=safe.directory \
    GIT_CONFIG_VALUE_0=/workspace

# Operator toolbox. It needs the Docker socket so k3d can create the cluster.
# The application image added later runs as non-root.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        tar \
        gzip \
        unzip \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# Signed Docker CLI. k3d uses it through the mounted socket; the daemon stays on the host.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable\n' \
        "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli=5:29.9.3-1~debian.12~bookworm \
    && rm -rf /var/lib/apt/lists/* \
    && docker --version

COPY install-tools.sh /tmp/install-tools.sh
RUN sh /tmp/install-tools.sh && rm /tmp/install-tools.sh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
