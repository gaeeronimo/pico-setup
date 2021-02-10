#!/bin/bash

# Exit on error
set -e

INSTALL_DEPENDENCIES="STD"
SUDO="sudo"

if grep -q Raspberry /proc/cpuinfo; then
    echo "Running on a Raspberry Pi"
elif [[ "$MSYSTEM" == "MINGW64" ]]; then
    echo "Running in minGW64"
    INSTALL_DEPENDENCIES="MINGW64"
    # TODO: Install vscode & putty from this script?
    SKIP_VSCODE=1
    SKIP_UART=1
    SUDO=""
elif [[ "$MSYSTEM" == "MSYS" ]] || [[ "$MSYSTEM" == "MINGW32" ]]; then
    echo "Run setup in a MINGW64 shell, please!"
    exit 1
else
    echo "Not running on a Raspberry Pi. Use at your own risk!"
fi

# Number of cores when running make
JNUM=4

# Where will the output go?
OUTDIR="$(pwd)/pico"

# Install dependencies

if [[ "$INSTALL_DEPENDENCIES" == "STD" ]]; then
    GIT_DEPS="git"
    SDK_DEPS="cmake gcc-arm-none-eabi gcc g++"
    OPENOCD_DEPS="gdb-multiarch automake autoconf build-essential texinfo libtool libftdi-dev libusb-1.0-0-dev"
    # Wget to download the deb
    VSCODE_DEPS="wget"
    UART_DEPS="minicom"

    # Build full list of dependencies
    DEPS="$GIT_DEPS $SDK_DEPS"

    if [[ "$SKIP_OPENOCD" == 1 ]]; then
        echo "Skipping OpenOCD (debug support)"
    else
        DEPS="$DEPS $OPENOCD_DEPS"
    fi

    if [[ "$SKIP_VSCODE" == 1 ]]; then
        echo "Skipping VSCODE"
    else
        DEPS="$DEPS $VSCODE_DEPS"
    fi

    echo "Installing Dependencies"
    sudo apt update
    sudo apt install -y $DEPS

elif [[ "$INSTALL_DEPENDENCIES" == "MINGW64" ]]; then

    GIT_DEPS="git"
    if command -v git > /dev/null; then
        # GIT already there, maybe git-for-windows. Keep it!
        GIT_DEPS=""
    fi

    # We need this to build the SDK and tools
    SDK_DEPS="base-devel mingw-w64-x86_64-arm-none-eabi-toolchain mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake mingw-w64-x86_64-ninja"
    OPENOCD_DEPS="base-devel mingw-w64-x86_64-toolchain" # mingw-w64-x86_64-libusb

    # Build full list of dependencies
    DEPS="$GIT_DEPS $SDK_DEPS"

    if [[ "$SKIP_OPENOCD" == 1 ]]; then
        echo "Skipping OpenOCD (debug support)"
    else
        DEPS="$DEPS $OPENOCD_DEPS"
    fi

    echo "Installing Dependencies"
    #pacman -Sy
    pacman -S --needed $DEPS

    # Workaround for openocd segfault with libusb 1.0.24-2
    if [[ "$(pacman -Q mingw-w64-x86_64-libusb)" == "mingw-w64-x86_64-libusb 1.0.24-2" ]]; then
        echo "Downgrade libusb to fix segfaults with openocd and picotool"
        TEMP_DOWNLOAD="$(mktemp -d)"
        if [[ -d "$TEMP_DOWNLOAD" ]]; then
            wget -P "$TEMP_DOWNLOAD" http://repo.msys2.org/mingw/x86_64/mingw-w64-x86_64-libusb-1.0.23-1-any.pkg.tar.xz
            pacman -U "$TEMP_DOWNLOAD/mingw-w64-x86_64-libusb-1.0.23-1-any.pkg.tar.xz"
            rm "$TEMP_DOWNLOAD/mingw-w64-x86_64-libusb-1.0.23-1-any.pkg.tar.xz"
            rmdir "$TEMP_DOWNLOAD"
        fi
    fi
    
else
    echo "Unknown install system, dependencies need to be installed manually!"
fi

echo "Creating $OUTDIR"
# Create pico directory to put everything in
mkdir -p $OUTDIR
cd $OUTDIR

# Clone sw repos
GITHUB_PREFIX="https://github.com/raspberrypi/"
GITHUB_SUFFIX=".git"
SDK_BRANCH="master"

for REPO in sdk examples extras playground
do
    DEST="$OUTDIR/pico-$REPO"

    if [ -d $DEST ]; then
        echo "$DEST already exists so skipping"
    else
        REPO_URL="${GITHUB_PREFIX}pico-${REPO}${GITHUB_SUFFIX}"
        echo "Cloning $REPO_URL"
        git clone -b $SDK_BRANCH $REPO_URL

        # Any submodules
        cd $DEST
        git submodule update --init
        cd $OUTDIR

        # Define PICO_SDK_PATH in ~/.bashrc
        VARNAME="PICO_${REPO^^}_PATH"
        echo "Adding $VARNAME to ~/.bashrc"
        echo "export $VARNAME=$DEST" >> ~/.bashrc
        export ${VARNAME}=$DEST
    fi
done

cd $OUTDIR

# On Windows cmake defaults to "NMake Makefiles" which will not work 
if [[ "$MSYSTEM" == "MINGW64" ]]; then
    GENERATOR="Ninja"
    echo "Adding CMAKE_GENERATOR to ~/.bashrc"
    echo "export CMAKE_GENERATOR=\"$GENERATOR\"" >> ~/.bashrc
fi

# Pick up new variables we just defined
source ~/.bashrc

# Adjust to choosen cmake generator
if [[ "$CMAKE_GENERATOR" == "Ninja" ]]; then
    BUILD_COMMAND="ninja"
else
    BUILD_COMMAND="make -j$JNUM"
fi

# Build a couple of examples
cd "$OUTDIR/pico-examples"
mkdir -p build
cd build
cmake ../ -DCMAKE_BUILD_TYPE=Debug

if [[ "$CMAKE_GENERATOR" == "Ninja" ]]; then
    echo "Building examples..."
    # Note: Ninja is quite fast, we just build all examples...
    ninja
else 
    for e in blink hello_world
    do
        echo "Building $e"
        cd $e
        $BUILD_COMMAND
        cd ..
    done
fi

cd $OUTDIR

# Picoprobe and picotool
for REPO in picoprobe picotool
do
    DEST="$OUTDIR/$REPO"
    REPO_URL="${GITHUB_PREFIX}${REPO}${GITHUB_SUFFIX}"
    if [ -d $DEST ]; then
        echo "$DEST already exists so skipping"
    else
        git clone $REPO_URL
    fi

    # Not 100% sure why this is needed...
    if [[ "$REPO" == "picotool" ]] && [[ "$MSYSTEM" == "MINGW64" ]]; then
        ADDITIONAL_CMAKE_ARGS="-DLIBUSB_INCLUDE_DIR=/mingw64/include/libusb-1.0"
    fi

    # Build both
    cd $DEST
    mkdir -p build
    cd build
    cmake ../ $ADDITIONAL_CMAKE_ARGS
    $BUILD_COMMAND

    if [[ "$REPO" == "picotool" ]]; then
        echo "Installing picotool to /usr/local/bin/picotool"
        $SUDO mkdir -p /usr/local/bin
        $SUDO cp picotool /usr/local/bin/
    fi

    cd $OUTDIR
done

if [ -d openocd ]; then
    echo "openocd already exists so skipping"
    SKIP_OPENOCD=1
fi

if [[ "$SKIP_OPENOCD" == 1 ]]; then
    echo "Won't build OpenOCD"
else
    # Build OpenOCD
    echo "Building OpenOCD"
    cd $OUTDIR
    # Should we include picoprobe support (which is a Pico acting as a debugger for another Pico)
    INCLUDE_PICOPROBE=1
    OPENOCD_BRANCH="rp2040"
    OPENOCD_CONFIGURE_ARGS="--enable-ftdi"
    if [[ ! "$MSYSTEM" == "MINGW64" ]]; then
        OPENOCD_CONFIGURE_ARGS="$OPENOCD_CONFIGURE_ARGS --enable-sysfsgpio --enable-bcm2835gpio"
    fi
    if [[ "$INCLUDE_PICOPROBE" == 1 ]]; then
        OPENOCD_BRANCH="picoprobe"
        OPENOCD_CONFIGURE_ARGS="$OPENOCD_CONFIGURE_ARGS --enable-picoprobe"
    fi

    git clone "${GITHUB_PREFIX}openocd${GITHUB_SUFFIX}" -b $OPENOCD_BRANCH --depth=1
    cd openocd
    ./bootstrap
    ./configure $OPENOCD_CONFIGURE_ARGS
    make -j$JNUM
    $SUDO make install
fi

cd $OUTDIR

# Liam needed to install these to get it working
EXTRA_VSCODE_DEPS="libx11-xcb1 libxcb-dri3-0 libdrm2 libgbm1 libegl-mesa0"
if [[ "$SKIP_VSCODE" == 1 ]]; then
    echo "Won't include VSCODE"
else
    if [ -f vscode.deb ]; then
        echo "Skipping vscode as vscode.deb exists"
    else
        echo "Installing VSCODE"
        if uname -m | grep -q aarch64; then
            VSCODE_DEB="https://aka.ms/linux-arm64-deb"
        else
            VSCODE_DEB="https://aka.ms/linux-armhf-deb"
        fi

        wget -O vscode.deb $VSCODE_DEB
        sudo apt install -y ./vscode.deb
        sudo apt install -y $EXTRA_VSCODE_DEPS

        # Get extensions
        code --install-extension marus25.cortex-debug
        code --install-extension ms-vscode.cmake-tools
        code --install-extension ms-vscode.cpptools
    fi
fi

# Enable UART
if [[ "$SKIP_UART" == 1 ]]; then
    echo "Skipping uart configuration"
else
    sudo apt install -y $UART_DEPS
    echo "Disabling Linux serial console (UART) so we can use it for pico"
    sudo raspi-config nonint do_serial 2
    echo "You must run sudo reboot to finish UART setup"
fi
