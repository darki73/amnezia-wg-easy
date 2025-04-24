###############################################################################
# Stage 0 – build AmneziaWG CLI tools (awg / awg-quick)                       #
###############################################################################
FROM alpine:3.20 AS build_awg_tools
RUN apk add --no-cache git build-base linux-headers bash
ENV WITH_WGQUICK=yes WITH_BASHCOMPLETION=no
RUN git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools /src \
 && make -C /src/src -j$(nproc) \
 && make -C /src/src install PREFIX=/usr

###############################################################################
# Stage 1 – build AmneziaWG userspace implementation (wireguard-go)           #
###############################################################################
FROM golang:1.24-alpine AS build_awg_go
RUN apk add --no-cache git make
RUN git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go /src \
 && cd /src && make

###############################################################################
# Stage 2 – install production Node modules for the UI                        #
###############################################################################
FROM node:20-alpine AS build_ui
COPY src /app
WORKDIR /app
RUN npm ci --omit=dev \
    && mv node_modules /node_modules

###############################################################################
# Stage 3 – final runtime image (lean)                                        #
###############################################################################
FROM node:20-alpine
RUN apk add --no-cache dumb-init iptables iptables-legacy iproute2 libcap bash \
    && mkdir -p /etc/amnezia \
    && ln -s /etc/wireguard /etc/amnezia/amneziawg

# AmneziaWG CLI tools
COPY --from=build_awg_tools /usr/bin/awg /usr/bin/
COPY --from=build_awg_tools /usr/bin/awg-quick /usr/bin/
# recreate the legacy names **inside the final image**
RUN ln -sf /usr/bin/awg       /usr/bin/wg \
 && ln -sf /usr/bin/awg-quick /usr/bin/wg-quick

# userspace WireGuard implementation
COPY --from=build_awg_go /src/amneziawg-go /usr/bin/wireguard-go
RUN setcap cap_net_admin+ep /usr/bin/wireguard-go

# Node.js app
WORKDIR /app
COPY --from=build_ui /app /app
COPY --from=build_ui /node_modules /node_modules

# health probe: `wg show` must list at least one interface
HEALTHCHECK --interval=1m --timeout=5s --retries=3 \
  CMD /bin/sh -c "wg show | grep -q interface"

ENV WG_QUICK_USERSPACE_IMPLEMENTATION=/usr/bin/wireguard-go \
    DEBUG=Server,WireGuard

CMD ["/usr/bin/dumb-init", "node", "server.js"]