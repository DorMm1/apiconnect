# Linux agent look-alike for tests/e2e: Ubuntu 24.04 + git + python3, the offline tool bundle installed with
# tools/install-offline.sh, and tests/e2e/fake-apic on PATH as `apic`.
#
# Build context = repository root, with the offline binaries copied in first (git-ignored):
#   cp -r <extracted-bundle>/tools/linux-x64 tools/
#   docker build -f tests/e2e/Dockerfile -t apic-e2e .
#   docker run --rm -v "$PWD:/src:ro" apic-e2e
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends git python3 python3-pip ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY tools/ /opt/tools/
RUN bash /opt/tools/install-offline.sh /opt/tools/linux-x64 /usr/local/bin
COPY tests/e2e/fake-apic /usr/local/bin/apic
RUN chmod 0755 /usr/local/bin/apic
WORKDIR /work
CMD ["bash", "/src/tests/e2e/run-tests.sh"]
