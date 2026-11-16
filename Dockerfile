FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-arm-none-eabi libnewlib-arm-none-eabi binutils-arm-none-eabi \
    make cmake srecord wget libc6-i386 lib32stdc++6 python-is-python3 python3 git zip xz-utils curl ca-certificates \
    build-essential libstdc++-arm-none-eabi-newlib \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
