#!/bin/bash

set -euo pipefail
# set -x

topdir=$( cd "$(dirname "$0")" && pwd -P)
echo "topdir: $topdir"

export MAKEFLAGS=$(( $(nproc || echo 2) + 1 ))

SYSROOT="$topdir/sysroot"
PREFIX="$SYSROOT/usr"
INCLUDEDIR="$PREFIX/include"
LIBDIR="$PREFIX/lib"

CC="i686-linux-gnu-gcc"
cc_install_dir=$("${CC}" -print-search-dirs | grep '^install: ' | sed 's/^install: //')
if [ -z "$cc_install_dir" ]; then
    echo "ERROR: couldn't discover compiler install directory" >&2
    exit 1
fi

export CFLAGS=
export CXXFLAGS=
export LDFLAGS=

function log() {
    echo -n "* "
    echo $@
}

function download_and_patch() {
    url=$1
    if test "$#" != 1; then
        echo "error: usage: ${FUNCNAME[0]} url" >&2
        return 1
    fi
    filename=$(basename "$url")
    dirname=$(echo "$filename" | sed 's/\.tar\.[a-z0-9]\+$//' )
    patchname=$(echo "$dirname" | sed 's/-[0-9]\+\(\.[0-9]\+\)\+$//' | tr "[:upper:]" "[:lower:]")
    
    if ! test -e "${dirname}"; then
        log "Downloading ${filename}..."
        mkdir -p tmp
        (
            cd tmp
            wget --no-verbose "$url" -O "$filename"
            log "Extracting ${filename}..."
            tar xf "${filename}"
            rm "${filename}"
            if test "$(echo "$topdir/patches/${patchname}"-*)" != "$topdir/patches/${patchname}-*"; then
                for f in "$topdir/patches/${patchname}"-*; do
                    echo "Applying $(basename "$f")..."
                    ( cd "${dirname}" && patch -p2 < "$f" )
                done
            fi
            mv "${dirname}" "${topdir}"
        )
    fi
}

function print_config_log() {
    # cat config.log | grep -B 500 "configure:[0-9]\+: \?error:"
    true
}

function download_patch_build() {
    target=$1
    url=$2
    shift 2
    
    filename=$(basename "$url")
    dirname=$(echo "$filename" | sed 's/\.tar\.[a-z0-9]\+$//' )
    patchname=$(echo "$dirname" | sed 's/-[0-9]\+\(\.[0-9]\+\)\+$//' | tr "[:upper:]" "[:lower:]")
    
    if ! should_build "$patchname"; then
        return
    fi
    
    log "Checking $target..."
    if ! test -e "$LIBDIR/$target"; then
        download_and_patch "$url"
        (
            cd "$dirname"
            mkdir -p build
            cd build
            export CC="${CC} -nostdinc -isystem $INCLUDEDIR -isystem $cc_install_dir/include -isystem $cc_install_dir/include-fixed -nodefaultlibs -L$LIBDIR -L$cc_install_dir -lc -ldl -lgcc --sysroot $SYSROOT -march=i686 -mtune=generic -fno-stack-protector"
            export PKG_CONFIG_LIBDIR="$LIBDIR/pkgconfig:$PREFIX/share/pkgconfig"
            ../configure --prefix="$PREFIX" --host="i686-linux-gnu" $@ || ( print_config_log; false )
            make
            make install
        )
    fi
}

##
## Actually build stuff
##

if test $# -gt 1; then
    echo >&2 "usage: $0 [MODULE]"
    exit 1
fi
module_to_build="${1:-}"
echo "module_to_build: $module_to_build"

function should_build() {
    test -z "$module_to_build" -o "$1" = "$module_to_build"
}

# kernel headers for glibc
if should_build "linux-headers"; then
    log "Checking linux/unistd.h..."
    if ! test -e "$PREFIX/include/linux/unistd.h"; then
        download_and_patch "https://mirrors.edge.kernel.org/pub/linux/kernel/v2.6/linux-2.6.39.4.tar.bz2"
        (
            cd linux-2.6.39.4
            make mrproper
            make headers_install ARCH="i386" INSTALL_HDR_PATH="$PREFIX"
        )
    fi
fi

# glibc
if should_build "glibc"; then
    log "Checking libc.so..."
    if ! test -e "$LIBDIR/libc.so"; then
        download_and_patch "https://ftp.gnu.org/gnu/libc/glibc-2.13.tar.bz2"
        (
            cd glibc-2.13
            mkdir -p build
            cd build
            # cannot have sysroot and stuff because configure needs to compile executables that link against glibc. ugh.
            export CC="${CC} -g -march=i686 -mtune=generic -fno-stack-protector -U_FORTIFY_SOURCE"
            ../configure --prefix="$PREFIX" --host="i686-linux-gnu" || ( print_config_log; false )
            make
            make install
        )
    fi
fi

# zlib
download_patch_build "libz.so" "https://zlib.net/zlib-1.2.11.tar.gz"

# prep for X libraries
download_patch_build "pkgconfig/pthread-stubs.pc" "https://xcb.freedesktop.org/dist/libpthread-stubs-0.3.tar.bz2"
download_patch_build "pkgconfig/inputproto.pc" "https://www.x.org/releases/individual/proto/inputproto-2.1.99.6.tar.bz2"
download_patch_build "pkgconfig/kbproto.pc" "https://www.x.org/releases/individual/proto/kbproto-1.0.5.tar.bz2"
download_patch_build "pkgconfig/xextproto.pc" "https://www.x.org/releases/individual/proto/xextproto-7.2.0.tar.bz2"
download_patch_build "pkgconfig/xproto.pc" "https://www.x.org/releases/individual/proto/xproto-7.0.22.tar.bz2"
download_patch_build "pkgconfig/xcb-proto.pc" "https://www.x.org/releases/individual/xcb/xcb-proto-1.6.tar.bz2"
download_patch_build "pkgconfig/xorg-macros.pc" "https://www.x.org/releases/individual/util/util-macros-1.16.2.tar.bz2"
download_patch_build "pkgconfig/xtrans.pc" "https://www.x.org/releases/individual/lib/xtrans-1.2.6.tar.bz2"

# X11
download_patch_build "libICE.so" "https://www.x.org/releases/individual/lib/libICE-1.0.7.tar.bz2"
download_patch_build "libSM.so" "https://www.x.org/releases/individual/lib/libSM-1.2.0.tar.bz2"
download_patch_build "libXau.so" "https://www.x.org/releases/individual/lib/libXau-1.0.6.tar.bz2"
download_patch_build "libxcb.so" \
    "https://www.x.org/releases/individual/xcb/libxcb-1.7.tar.bz2" \
    --enable-xinput
download_patch_build "libX11.so" "https://www.x.org/releases/individual/lib/libX11-1.4.99.1.tar.bz2"
download_patch_build "libXt.so" "https://www.x.org/releases/individual/lib/libXt-1.1.1.tar.bz2"
download_patch_build "libXext.so" "https://www.x.org/releases/individual/lib/libXext-1.3.0.tar.bz2"
download_patch_build "libXi.so" "https://www.x.org/releases/individual/lib/libXi-1.5.99.3.tar.bz2"

# glib and gtk+
download_patch_build "libglib-1.2.so.0" "https://download.gnome.org/sources/glib/1.2/glib-1.2.10.tar.gz"
download_patch_build "libgtk-1.2.so.0" \
    "https://download.gnome.org/sources/gtk+/1.2/gtk+-1.2.10.tar.gz" \
    --disable-glibtest --with-glib-prefix="$PREFIX" --with-x

# libtool provides ltdl which is required by pulseaudio
download_patch_build "libltdl.so" "https://ftpmirror.gnu.org/libtool/libtool-2.4.2.tar.gz"

# audio
download_patch_build "libasound.so" "ftp://ftp.alsa-project.org/pub/lib/alsa-lib-1.2.4.tar.bz2"
download_patch_build "libsndfile.so" "http://www.mega-nerd.com/libsndfile/files/libsndfile-1.0.20.tar.gz"
download_patch_build "libpulse.so" \
    "https://freedesktop.org/software/pulseaudio/releases/pulseaudio-14.2.tar.gz" \
    --enable-memfd=no --without-caps --disable-glib2
    
# rebuild SDL with pulseaudio support
download_patch_build "libSDL.so" \
    "https://libsdl.org/release/SDL-1.2.15.tar.gz" \
     --with-x --enable-alsa=yes --enable-alsa-shared=no --enable-pulseaudio=yes \
     --enable-pulseaudio-shared=no

# download and unpack dockingstation_195_64
if should_build "lc2e"; then
    log "Checking lc2e..."
    if ! test -e "dockingstation_195_64/lc2e"; then
        (
        mkdir -p tmp
        cd tmp
        wget "http://www.creaturesdockingstation.com/dockingstation_195_64.tar.bz2"
        tar xf dockingstation_195_64.tar.bz2
        rm dockingstation_195_64.tar.bz2
        (
            cd dockingstation_195_64
            mv "dsbuild 195/global"/* .
            mv ports/linux_x86_glibc21_64/Catalogue/* Catalogue/
            rm -fr ports/linux_x86_glibc21_64/Catalogue
            mv ports/linux_x86_glibc21_64/* .
            log "Unpacking dockingstation_195_64..."
            rm -fr "dsbuild 195" ports cdtastic Readme.txt dstation-install
            find . -name '*.bz2' -exec bunzip2 {} \;
            rm Readme.txt dstation-install
            for d in Backgrounds Images "Overlay Data" Sounds; do
            ( cd "$d" && for f in *; do test "$f" == "${f,,}" || mv "$f" "${f,,}"; done )
            done
        )
        mv dockingstation_195_64 "$topdir"
        )
    fi

    # copy in creaturesdockingstation.sh
    cp creaturesdockingstation.sh dockingstation_195_64

    # get the libraries
    log "Bundling lib32..."
    rm -fr "dockingstation_195_64/lib32" 
    libs=$(LD_LIBRARY_PATH="$LIBDIR:$topdir/dockingstation_195_64" ldd "$topdir/dockingstation_195_64/lc2e" | grep "=>" | sed 's/^.*=>//g' | sed 's/(0x[a-f0-9]\+)$//g')
    mkdir -p "dockingstation_195_64/lib32"
    cp "$LIBDIR/ld-linux.so.2" "dockingstation_195_64/lib32"
    for f in $libs; do
        if [[ "$f" == "$LIBDIR"/* ]]; then
            cp "$f" "dockingstation_195_64/lib32"
        elif [[ "$f" == "$topdir/dockingstation_195_64"/* ]]; then
            true
        else
            echo "ERROR: $f" >&2
            exit 1
        fi
    done

    log "Bundling lib32_glibc..."
    rm -fr "dockingstation_195_64/lib32_glibc"
    mkdir -p "dockingstation_195_64/lib32_glibc"
    mv dockingstation_195_64/lib32{,_glibc}/ld-linux.so.2
    mv dockingstation_195_64/lib32{,_glibc}/libc.so.*
    mv dockingstation_195_64/lib32{,_glibc}/libdl.so.*
    mv dockingstation_195_64/lib32{,_glibc}/libm.so.*
    mv dockingstation_195_64/lib32{,_glibc}/libpthread.so.*
    mv dockingstation_195_64/lib32{,_glibc}/librt.so.*

    log "Finding libgcc_s.so..."
    (
        mkdir -p tmp
        cd tmp
        echo "int main() { return 0; }" > dummy.c
        "${CC}" dummy.c -o dummy -Wl,--no-as-needed -lgcc_s
        libgcc_s_path=$(ldd dummy | grep "libgcc_s.so" | grep "=>" | sed 's/^.*=> *//' | sed 's/ \+(0x[a-f0-9]\+)$//')
        if test -z "${libgcc_s_path}"; then
            echo "ERROR: couldn't find libgcc_s" >&2
        fi
        echo "${libgcc_s_path}"
        # TODO: check for bad glibc versions (or do we? can't be worse than the SIGABRT when it's missing...)
        cp "${libgcc_s_path}" "$topdir/dockingstation_195_64/lib32_glibc/"
    )

    log "Fixing rpaths..."
    for f in dockingstation_195_64/lib32/* dockingstation_195_64/lib32_glibc/*; do
        rpath=$(patchelf --print-rpath "$f")
        if [[ "$rpath" == /* ]]; then
            patchelf --remove-rpath "$f"
        fi
    done
fi