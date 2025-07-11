FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    bash \
    ca-certificates \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Download precompiled binary with fallback
RUN mkdir -p /root/.nexus/bin \
    && curl -L -o /root/.nexus/bin/nexus-network \
       "https://github.com/kkkkkkog/nexus-cli/releases/download/v0.9.0-g/nexus-network-linux-x86_64" \
    && chmod +x /root/.nexus/bin/nexus-network \
    && ln -sf /root/.nexus/bin/nexus-network /root/.nexus/bin/nexus-cli \
    && echo 'export PATH="/root/.nexus/bin:/root/.nexus:$PATH"' >> ~/.bashrc

# Make nexus-network available in PATH  
ENV PATH="/root/.nexus/bin:/root/.nexus:$PATH"

# Set working directory
WORKDIR /app

# Default command
CMD ["bash", "-l"]
