#!/bin/sh
# Download the operator CLIs and check each one against its publisher checksum.
set -eu

arch=${TARGETARCH:?TARGETARCH is required}
tmp=$(mktemp -d)
cd "$tmp"

curl -fsSL -o "k3d-linux-${arch}" \
  "https://github.com/k3d-io/k3d/releases/download/v${K3D_VERSION}/k3d-linux-${arch}"
curl -fsSL -o k3d.sha256 \
  "https://github.com/k3d-io/k3d/releases/download/v${K3D_VERSION}/checksums.txt"
hash=$(awk -v name="_dist/k3d-linux-${arch}" '$2 == name {print $1}' k3d.sha256)
[ -n "$hash" ]
echo "${hash}  k3d-linux-${arch}" | sha256sum -c -
install -m 0755 "k3d-linux-${arch}" /usr/local/bin/k3d

curl -fsSL -o kubectl \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"
curl -fsSL -o kubectl.sha256 \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl.sha256"
echo "$(tr -d '[:space:]' < kubectl.sha256)  kubectl" | sha256sum -c -
install -m 0755 kubectl /usr/local/bin/kubectl

helm_archive="helm-v${HELM_VERSION}-linux-${arch}.tar.gz"
curl -fsSL -o "$helm_archive" "https://get.helm.sh/${helm_archive}"
curl -fsSL -o helm.sha256 "https://get.helm.sh/${helm_archive}.sha256sum"
sha256sum -c helm.sha256
tar -xzf "$helm_archive"
install -m 0755 "linux-${arch}/helm" /usr/local/bin/helm

tf_zip="terraform_${TERRAFORM_VERSION}_linux_${arch}.zip"
curl -fsSL -o "$tf_zip" \
  "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${tf_zip}"
curl -fsSL -o terraform.sha256 \
  "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
awk -v name="$tf_zip" '$2 == name {print $1 "  " $2}' terraform.sha256 | sha256sum -c -
unzip -q "$tf_zip"
install -m 0755 terraform /usr/local/bin/terraform

k6_archive="k6-v${K6_VERSION}-linux-${arch}.tar.gz"
curl -fsSL -o "$k6_archive" \
  "https://github.com/grafana/k6/releases/download/v${K6_VERSION}/${k6_archive}"
curl -fsSL -o k6.sha256 \
  "https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-checksums.txt"
awk -v name="$k6_archive" '$2 == name {print $1 "  " $2}' k6.sha256 | sha256sum -c -
tar -xzf "$k6_archive"
k6_bin=$(find . -type f -name k6 | head -n 1)
[ -n "$k6_bin" ]
install -m 0755 "$k6_bin" /usr/local/bin/k6

k3d version
kubectl version --client
helm version
terraform version
k6 version

cd /
rm -rf "$tmp"
