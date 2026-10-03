FROM ubuntu:24.04

# keeps apt from ever prompting.
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
  systemd \
  systemd-sysv \
  && rm -rf /var/lib/apt/lists/*

# Tells systemd it is asked to shut down, not killed.
STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
