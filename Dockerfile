# Owelk on Linux in a container (Ubuntu 24.04): built by tools/install-local.sh, the same steps a Linux desktop
# runs, with the Qt of tools/qt.txt. Use it to build and test the Linux version from any computer.
#
#   docker build -t owelk .     the first build downloads Qt (about 1.5 GB) and keeps it for later builds
#   docker run --rm owelk       runs every test (offscreen)
#
# The image follows the computer's processor (x86-64 or ARM64, e.g. Apple silicon). Showing the app's window
# from a container needs a Linux desktop (X11); see README.md.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# What tools/install-local.sh itself needs; it installs the rest. Fonts for text in the tests.
RUN apt-get update \
    && apt-get install -y --no-install-recommends sudo python3 python3-venv ca-certificates fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
# An ordinary user, as on a desktop, allowed to install packages.
RUN useradd --create-home --shell /bin/bash owelk \
    && echo 'owelk ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/owelk
USER owelk
WORKDIR /home/owelk/Owelk

# Packages and Qt first: this layer is reused until tools/qt.txt or the script changes.
COPY --chown=owelk:owelk tools/install-local.sh tools/qt.txt tools/
RUN tools/install-local.sh --deps --yes

COPY --chown=owelk:owelk . .
# Linking the web engine takes much memory: 4 jobs fit Docker's default 8 GB (--build-arg OWELK_JOBS=<n>).
ARG OWELK_JOBS=4
RUN tools/install-local.sh --yes --with-tests

# No GPU and no sandbox inside a container.
ENV PATH=/home/owelk/.local/bin:$PATH \
    QT_QPA_PLATFORM=offscreen \
    QT_QUICK_BACKEND=software \
    QTWEBENGINE_DISABLE_SANDBOX=1 \
    QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-gpu"
CMD ["ctest", "--test-dir", "build-release", "--output-on-failure", "--timeout", "600"]
