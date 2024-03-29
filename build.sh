#!/bin/bash

set -euo pipefail
# set -x

topdir=$( cd "$(dirname "$0")" && pwd -P)
echo "topdir: $topdir"

export MAKEFLAGS=$(( $(nproc || echo 2) + 1 ))

HOST_PREFIX="$topdir/toolchain/usr"
export PATH="$HOST_PREFIX/bin:$PATH"

SYSROOT="$HOST_PREFIX/i686-linux-gnu"
PREFIX="$SYSROOT"
INCLUDEDIR="$PREFIX/include"
LIBDIR="$PREFIX/lib"

CC="i686-linux-gnu-gcc"

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
    dirname=$(echo "${filename%.tar.*}" )
    patchname=$(echo "$dirname" | sed 's/-[0-9]\+\(\.[0-9]\+\)\+$//' | tr "[:upper:]" "[:lower:]")
    
    if ! test -e "${dirname}"; then
        log "Downloading ${filename}..."
        mkdir -p tmp
        (
            cd tmp
            wget --no-verbose "$url" -O "$filename"
            log "Extracting ${filename}..."
            mkdir "${dirname}"
            tar xf "${filename}" -C "${dirname}" --strip-components=1
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
    echo
    cat config.log | grep -B 500 "configure:[0-9]\+: \?error:"
    false
}

function download_patch_build_host() {
    url=$1
    shift 1
    
    filename=$(basename "$url")
    dirname=$(echo "${filename%.tar.*}" )
    patchname=host_$(echo "$dirname" | sed 's/-[0-9]\+\(\.[0-9]\+\)\+$//' | tr "[:upper:]" "[:lower:]")
    
    if ! should_build "$patchname"; then
        return
    fi
    
    download_and_patch "$url"
    (
        cd "$dirname"
        mkdir -p build_host
        cd build_host
        ../configure CFLAGS="-w" --prefix="$HOST_PREFIX" $@ || ( print_config_log; false )
        make
        make install
    )
    fix_runpaths
}

function download_patch_build() {
    url=$1
    shift 1
    
    filename=$(basename "$url")
    dirname=$(echo "${filename%.tar.*}" )
    patchname=$(echo "$dirname" | sed 's/-[0-9]\+\(\.[0-9]\+\)\+$//' | tr "[:upper:]" "[:lower:]")
    
    if ! should_build "$patchname"; then
        return
    fi
    
    download_and_patch "$url"
    (
        cd "$dirname"
        mkdir -p build
        cd build
        export CC="${CC} -march=i686 -mtune=generic -w"
        export PKG_CONFIG_LIBDIR="$LIBDIR/pkgconfig:$PREFIX/share/pkgconfig"
        ../configure --prefix="$PREFIX" --host="i686-linux-gnu" $@ || ( print_config_log; false )
        make
        make install
    )
}

function relative_path() {
    s=$(cd ${1%%/};pwd)
    d=$(cd $2;pwd)
    b=
    while [ "${d#$s/}" == "${d}" ]; do
        s=$(dirname $s)
        b="../${b}"
    done
    echo ${b}${d#$s/}
}

function fix_runpaths() {
    (
        mkdir -p "$HOST_PREFIX"/{bin,libexec}
        elf_files=$(find "$HOST_PREFIX"/{bin,libexec} -type f -exec sh -c "file {} | grep -i ': elf ' > /dev/null" \; -print)
        IFS=$'\n'
        for f in $elf_files; do
            if test "$(basename "$f")" = "patchelf"; then
                continue
            fi
            rpath=$(relative_path "$(dirname "$f")" "$HOST_PREFIX/lib")
            echo patchelf --set-rpath "$rpath" "$f"
            patchelf --set-rpath "\$ORIGIN/$rpath" "$f"
        done
    )
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

# patchelf
download_patch_build_host "https://github.com/NixOS/patchelf/releases/download/0.12/patchelf-0.12.tar.bz2"

# binutils for i686
# binutils puts stuff into $HOST_PREFIX/i686-linux-gnu by default, which we're using for
# our sysroot... we could change it by passing tooldir="$HOST_PREFIX/libexec/binutils/i686-linux-gnu"
# to make and make install, but it's not a big issue.
download_patch_build_host "https://ftp.gnu.org/gnu/binutils/binutils-2.21.1.tar.bz2" \
   --target="i686-linux-gnu" --disable-nls --disable-werror --disable-multilib \
   --with-sysroot="$SYSROOT"

# kernel headers for gcc and glibc
if should_build "linux-headers"; then
   download_and_patch "https://mirrors.edge.kernel.org/pub/linux/kernel/v2.6/linux-2.6.39.4.tar.bz2"
   (
       cd linux-2.6.39.4
       make mrproper
       make headers_install ARCH="i386" INSTALL_HDR_PATH="$PREFIX"
   )
fi

# gcc for i686
download_patch_build_host "https://ftp.gnu.org/gnu/gmp/gmp-6.1.0.tar.bz2"
download_patch_build_host "https://ftp.gnu.org/gnu/mpfr/mpfr-3.1.2.tar.bz2" --with-gmp="$HOST_PREFIX"
download_patch_build_host "https://ftp.gnu.org/gnu/mpc/mpc-1.0.3.tar.gz" --with-gmp="$HOST_PREFIX" --with-mpfr="$HOST_PREFIX"
if should_build "host_gcc"; then
    download_and_patch "https://ftp.gnu.org/gnu/gcc/gcc-4.9.2/gcc-4.9.2.tar.bz2"
    (
        cd gcc-4.9.2
        mkdir -p build
        cd build
        ../configure --target="i686-linux-gnu" --prefix="$HOST_PREFIX" \
            --enable-languages=c --disable-multilib --disable-nls \
            --with-gmp="$HOST_PREFIX" --with-mpfr="$HOST_PREFIX" --with-mpc="$HOST_PREFIX" \
            --with-sysroot="$SYSROOT" --with-native-system-header-dir="/include" \
            CXXFLAGS="-std=gnu++0x" LDFLAGS="-Wl,-rpath=\"$HOST_PREFIX/lib\",--enable-new-dtags" \
            || ( print_config_log; false )
        # gcc looks for a limits.h to decide whether the gcc/include-fixed/limits.h
        # header should be made to expect a libc-supplied limits.h or not. but since
        # libc hasn't been built yet, explicitly force GCC to expect a limits.h
        make all-gcc LIMITS_H_TEST=true
        make install-gcc
    )
    fix_runpaths
fi

# glibc_bootstrap
if should_build "glibc_bootstrap"; then
    download_and_patch "https://ftp.gnu.org/gnu/libc/glibc-2.13.tar.bz2"
    (
        cd glibc-2.13
        mkdir -p build
        cd build
        export CC="${CC} -g -march=i686 -mtune=generic -U_FORTIFY_SOURCE -w"
        # add libc_cv_forced_unwind=yes, libc_cv_c_cleanup=yes, and libc_cv_ctors_header=yes
        # because the test executables will fail to link, since we don't have libc yet! stupid
        ../configure --prefix="$PREFIX" --host="i686-linux-gnu" --disable-multilib \
            libc_cv_forced_unwind=yes libc_cv_c_cleanup=yes libc_cv_ctors_header=yes \
            || ( print_config_log; false )
        # headers
        make install-bootstrap-headers=yes install-headers
        install bits/stdio_lim.h "$INCLUDEDIR/bits"
        touch "$INCLUDEDIR/gnu/stubs.h"
        # startup files
        make csu/subdir_lib
        mkdir -p "$LIBDIR"
        install csu/crt1.o csu/crti.o csu/crtn.o "$LIBDIR"
        # dummy libc that libgcc can link against
        if ! test -e "$LIBDIR/libc.so"; then
            i686-linux-gnu-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o "$LIBDIR/libc.so"
        fi
    )
fi

# libgcc
# static libraries libgcc.a and libgcc_eh.a go to $HOST_PREFIX/lib/gcc/i686-linux-gnu/4.9.2 ?
# shared library libgcc_s.so goes to $HOST_PREFIX/i686-linux-gnu/lib ?
if should_build "libgcc"; then ( cd gcc-4.9.2/build && make all-target-libgcc && make install-target-libgcc ); fi

# glibc_final
if should_build "glibc_final"; then ( cd glibc-2.13/build && make && make install ); fi

# zlib
download_patch_build "https://zlib.net/zlib-1.2.11.tar.gz"

# X11
download_patch_build "https://xcb.freedesktop.org/dist/libpthread-stubs-0.3.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/proto/inputproto-2.1.99.6.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/proto/kbproto-1.0.5.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/proto/xextproto-7.2.0.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/util/util-macros-1.16.2.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/proto/xproto-7.0.22.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/xcb/xcb-proto-1.7.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/lib/xtrans-1.2.6.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/lib/libICE-1.0.7.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/lib/libSM-1.2.0.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/lib/libXau-1.0.6.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/xcb/libxcb-1.9.1.tar.bz2" \
    --enable-xinput
download_patch_build "https://www.x.org/releases/individual/lib/libX11-1.4.99.1.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/lib/libXt-1.1.1.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/lib/libXext-1.3.0.tar.bz2"
download_patch_build "https://www.x.org/releases/individual/lib/libXi-1.5.99.3.tar.bz2"

# glib and gtk+
CFLAGS="-std=gnu89" download_patch_build "https://download.gnome.org/sources/glib/1.2/glib-1.2.10.tar.gz"
download_patch_build "https://download.gnome.org/sources/gtk+/1.2/gtk+-1.2.10.tar.gz" \
    --disable-glibtest --with-glib-prefix="$PREFIX" --with-x

# alsa
download_patch_build "ftp://ftp.alsa-project.org/pub/lib/alsa-lib-1.2.4.tar.bz2"

# pulseaudio
download_patch_build "https://ftpmirror.gnu.org/libtool/libtool-2.4.2.tar.gz" # provides libtdl
download_patch_build "http://www.mega-nerd.com/libsndfile/files/libsndfile-1.0.20.tar.gz"
download_patch_build "https://freedesktop.org/software/pulseaudio/releases/pulseaudio-14.2.tar.gz" \
    --enable-memfd=no --without-caps --disable-glib2
    
# rebuild SDL with pulseaudio support
download_patch_build "https://libsdl.org/release/SDL-1.2.15.tar.gz" \
     --with-x --enable-alsa=yes --enable-alsa-shared=no --enable-pulseaudio=yes \
     --enable-pulseaudio-shared=no

# rebuild SDL_mixer for consistency
download_patch_build "https://www.libsdl.org/projects/SDL_mixer/release/SDL_mixer-1.2.12.tar.gz"

# download and unpack dockingstation_195_64
if should_build "lc2e"; then
    log "Checking lc2e..."
    if ! test -e "dockingstation_195_64/lc2e"; then
        (
        mkdir -p tmp
        cd tmp
        wget --no-verbose "http://www.creaturesdockingstation.com/dockingstation_195_64.tar.bz2"
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
            log "Removing unneeded files..."
            rm Readme.txt dstation-install libSDL-1.2.so.0 libSDL_mixer-1.2.so.0
            log "Lowercasing filenames..."
            sed -i.bak "s/DS_music.mng/ds_music.mng/" user.cfg && rm user.cfg.bak
            for d in Backgrounds Images "Overlay Data" Sounds; do
                # lowercase the filenames
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
    LD_LIBRARY_PATH="$LIBDIR:$topdir/dockingstation_195_64" ldd "$topdir/dockingstation_195_64/lc2e"
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
        cp "${libgcc_s_path}" "$topdir/dockingstation_195_64/lib32/"
    )

    log "Fixing rpaths..."
    patchelf --set-rpath '$ORIGIN/lib32:$ORIGIN' dockingstation_195_64/imageconvert
    patchelf --set-rpath '$ORIGIN/lib32:$ORIGIN' dockingstation_195_64/langpick
    patchelf --set-rpath '$ORIGIN/lib32:$ORIGIN' dockingstation_195_64/lc2e
    for f in dockingstation_195_64/lib32/*; do
        rpath=$(patchelf --print-rpath "$f")
        if [[ "$rpath" == /* ]]; then
            patchelf --remove-rpath "$f"
        fi
    done
fi
