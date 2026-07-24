BINUTILS_VER = 2.44
GCC_VER = 15.1.0
MUSL_VER = 1.2.6
LINUX_VER = 5.8.5
GMP_VER = 6.3.0
MPC_VER = 1.3.1
MPFR_VER = 4.2.2
ISL_VER =

COMMON_CONFIG += --disable-nls
GCC_CONFIG += --enable-checking=release
GCC_CONFIG += --disable-lto
GCC_CONFIG += --disable-libquadmath --disable-decimal-float
GCC_CONFIG += --disable-libitm --disable-libgomp --disable-libvtv

COMMON_CONFIG += CFLAGS="-O2 -g -fno-lto"
COMMON_CONFIG += CXXFLAGS="-O2 -g -fno-lto"
GCC_CONFIG += CFLAGS_FOR_TARGET="-O2 -g -fno-lto"
GCC_CONFIG += CXXFLAGS_FOR_TARGET="-O2 -g -fno-lto"
