#!/bin/bash
# Installs mikefarah yq v4.53.6 at /usr/local/bin/yq, verified against the
# release's own `checksums` entry. A release asset can be replaced after it
# ships, and the step that runs next holds a token that writes
# faultmaven-enterprise-infra's image-queue. linux/amd64 only: the GitHub-hosted
# ubuntu runners the callers use.
set -euo pipefail
YQ_VERSION=v4.53.6
YQ_SHA256=c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385
sudo wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
echo "${YQ_SHA256}  /usr/local/bin/yq" | sha256sum -c -
sudo chmod +x /usr/local/bin/yq
yq --version
