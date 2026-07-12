ARG ADE_CORE_IMAGE=mcr.microsoft.com/deployment-environments/runners/core@sha256:0146f2afc24910cffa7d95eb17c21fc5ff6a64516e2cdbfe32e5d77bf4b2dd23

FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40 AS terraform-download
ARG TERRAFORM_VERSION=1.15.8
ARG TERRAFORM_SHA256=d25ce7b6902013ad905db3d2eab0be4cd905887fe88b81a6171b8d5503c31f3d
ARG AKS_PREVIEW_EXTENSION_URL=https://azcliprod.blob.core.windows.net/cli-extensions/aks_preview-21.0.0b8-py2.py3-none-any.whl
ARG AKS_PREVIEW_EXTENSION_SHA256=aa39868b5441c659afc11d069ef42bd48dbbd86d257058a76dfb552dc2748763
ARG CONTAINERAPP_EXTENSION_URL=https://azcliprod.blob.core.windows.net/cli-extensions/containerapp-1.3.0b4-py2.py3-none-any.whl
ARG CONTAINERAPP_EXTENSION_SHA256=8f9bd1ab0cceb683dad4cef73ba26344d0a40e528da920134a5a86c4feda4577
# Base image and Terraform archive are digest-pinned; Alpine security package
# revisions intentionally follow the selected 3.23 repository patch stream.
# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates curl unzip \
    && curl --fail --show-error --silent --location --retry 5 \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
      --output /tmp/terraform.zip \
    && printf '%s  %s\n' "${TERRAFORM_SHA256}" /tmp/terraform.zip >/tmp/terraform.sha256 \
    && sha256sum -c /tmp/terraform.sha256 \
    && unzip /tmp/terraform.zip -d /out \
    && curl --fail --show-error --silent --location --retry 5 \
      "${AKS_PREVIEW_EXTENSION_URL}" \
      --output /out/aks_preview-21.0.0b8-py2.py3-none-any.whl \
    && printf '%s  %s\n' "${AKS_PREVIEW_EXTENSION_SHA256}" /out/aks_preview-21.0.0b8-py2.py3-none-any.whl >/tmp/aks-preview.sha256 \
    && sha256sum -c /tmp/aks-preview.sha256 \
    && curl --fail --show-error --silent --location --retry 5 \
      "${CONTAINERAPP_EXTENSION_URL}" \
      --output /out/containerapp-1.3.0b4-py2.py3-none-any.whl \
    && printf '%s  %s\n' "${CONTAINERAPP_EXTENSION_SHA256}" /out/containerapp-1.3.0b4-py2.py3-none-any.whl >/tmp/containerapp.sha256 \
    && sha256sum -c /tmp/containerapp.sha256 \
    && /out/terraform version

# The Microsoft ADE core image owns the runner entrypoint and executes its
# mounted operation contract as root. Dropping privileges in the derived image
# breaks that managed harness; the runner is digest-pinned and contains no
# application or tenant credentials.
FROM ${ADE_CORE_IMAGE}
LABEL org.opencontainers.image.title="ADE Terraform runner for azure-platform-engineering-lab" \
      org.opencontainers.image.description="Maintenance-mode compatibility runner; deploy and delete only" \
      org.opencontainers.image.version="1.1.0" \
      io.azure.platform.terraform.version="1.15.8" \
      io.azure.platform.ade-core.digest="sha256:0146f2afc24910cffa7d95eb17c21fc5ff6a64516e2cdbfe32e5d77bf4b2dd23"
ENV AZURE_EXTENSION_DIR=/opt/az/extensions
COPY --from=terraform-download /out/terraform /usr/local/bin/terraform
COPY --from=terraform-download /out/aks_preview-21.0.0b8-py2.py3-none-any.whl /tmp/aks_preview-21.0.0b8-py2.py3-none-any.whl
COPY --from=terraform-download /out/containerapp-1.3.0b4-py2.py3-none-any.whl /tmp/containerapp-1.3.0b4-py2.py3-none-any.whl
COPY scripts/ /scripts/
COPY sample/ /samples/
RUN mkdir -p "$AZURE_EXTENSION_DIR" \
    && az extension add --source /tmp/aks_preview-21.0.0b8-py2.py3-none-any.whl --yes --only-show-errors \
    && test "$(az extension show --name aks-preview --query version --output tsv)" = '21.0.0b8' \
    && az extension add --source /tmp/containerapp-1.3.0b4-py2.py3-none-any.whl --yes --only-show-errors \
    && test "$(az extension show --name containerapp --query version --output tsv)" = '1.3.0b4' \
    && rm -f /tmp/aks_preview-21.0.0b8-py2.py3-none-any.whl /tmp/containerapp-1.3.0b4-py2.py3-none-any.whl \
    && chmod 0555 /scripts/*.sh /usr/local/bin/terraform \
    && chmod -R a=rX /samples "$AZURE_EXTENSION_DIR" \
    && command -v az curl jq python3 tar \
    && terraform version \
    && az aks approuting defaultdomain show --help >/dev/null
