#!/bin/zsh
# Builds AirportItlwm.kext for macOS Tahoe (target "AirportItlwm-Tahoe", Release
# settings) with the Command Line Tools only, no Xcode.
#
#   zsh scripts/build-airportitlwm-tahoe-clt.sh [MacKernelSDK dir] [output dir]
#
# Defaults: ./MacKernelSDK (acidanthera/MacKernelSDK 3f75008, as in CI) and ./build/Tahoe.
# Mirrors itlwm.xcodeproj: every source (C included) is compiled as C++ (GCC_INPUT_FILETYPE),
# gnu++14, -O1, PrivateSPI.pch as prefix header, Tahoe defines, WCL/Info.plist.
set -e
ROOT=${0:A:h:h}
SDK=${1:-$ROOT/MacKernelSDK}
OUT=${2:-$ROOT/build/Tahoe}
VER=$(awk '/MODULE_VERSION =/ {gsub(/;/, "", $3); print $3; exit}' $ROOT/itlwm.xcodeproj/project.pbxproj)
COMMIT=$(cat $ROOT/.commit 2>/dev/null || git -C $ROOT rev-parse --short HEAD 2>/dev/null || echo unknown)
NAME=AirportItlwm; BID=com.zxystd.AirportItlwm
KEXT=$OUT/$NAME.kext
OBJ=$OUT/obj
JOBS=${JOBS:-4}
[[ -d $SDK/Headers ]] || { echo "MacKernelSDK not found at $SDK"; exit 1; }

# Firmware blob (Xcode runs scripts/fw_gen.sh as a build phase).
[[ -f $ROOT/include/FwBinary.cpp ]] || python3 $ROOT/scripts/zlib_compress_fw.py \
    $ROOT/include/FwBinary.cpp $ROOT/itlwm/firmware/

SRCS=(
  itl80211/ItlDma.cpp itl80211/compat.cpp itl80211/zutil.c
  itl80211/openbsd/sys/_mbuf.cpp itl80211/openbsd/sys/_task.cpp itl80211/openbsd/sys/_ifq.cpp
  itl80211/openbsd/sys/arp.c
  itl80211/openbsd/net80211/{ieee80211_ra,ieee80211_proto,_string,ieee80211_ioctl,ieee80211,ieee80211_rssadapt,ieee80211_input,timeout,ieee80211_mira,ieee80211_crypto_bip,ieee80211_crypto_tkip,ieee80211_crypto_ccmp,ieee80211_crypto_wep,ieee80211_pae_input,ieee80211_amrr,ieee80211_output,ieee80211_crypto,ieee80211_regdomain,ieee80211_node,ieee80211_pae_output}.c
  itl80211/openbsd/net80211/CTimeout.cpp
  itl80211/openbsd/crypto/{sha1-pbkdf2,aes,hmac,sha2,rijndael,ecb3_enc,set_key,cast,michael,sha1,cmac,ecb_enc,chachapoly,md5,arc4,blf,poly1305,key_wrap,gmac,rmd160,idgen}.c
  include/FwBinary.cpp include/HAL/ItlHalService.cpp
  itlwm/hal_iwx/ItlIwx.cpp itlwm/hal_iwn/ItlIwn.cpp
  itlwm/hal_iwm/{rs,utils,fw,io,rx,coex,tx,hw,phy,mac80211,nvm,ctxt,led,power,scan,ItlIwm}.cpp
  AirportItlwm/AirportItlwmV2.cpp AirportItlwm/AirportItlwmEthernetInterface.cpp
  AirportItlwm/AirportItlwmSkywalkInterface.cpp AirportItlwm/WCL/WCL.cpp
  AirportItlwm/IOPCIEDeviceWrapper.cpp
)

# Xcode resolves bare #include "x.h" through a header map of every project header; emulate it
# with -I for each header directory (the versioned macOS15/macOS26 copies are reached through
# the include/Airport wrappers, so they stay off the path).
HDIRS=(${(f)"$(cd $ROOT && find . \( -name '*.h' -o -name '*.hpp' \) -not -path './MacKernelSDK/*' \
        -not -path '*/macOS15/*' -not -path '*/macOS26/*' -not -path './build/*' -exec dirname {} \; | sort -u |
        sed "s|^\.|-I$ROOT|")"})
FLAGS=(-arch x86_64 -mkernel -nostdinc -fno-builtin -fno-common -fno-stack-protector
       -mmacosx-version-min=10.15 -O1 -g
       -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
       -DAIRPORT_WCL -DAIRPORT_VTD "-D__IO80211_TARGET=__MAC_26_0" -DAIRPORT -D__PRIVATE_SPI__
       -DIO80211FAMILY_V2 -DIEEE80211_STA_ONLY "-DITLWM_VERSION=\"$VER\"" "-DGIT_COMMIT=\"_$COMMIT\""
       -isystem $SDK/Headers -iframework $SDK/Headers
       -isystem $ROOT/itl80211/openbsd -isystem $ROOT/itl80211 -isystem $ROOT/include
       -I$ROOT/itl80211 -I$ROOT/include -I$ROOT $HDIRS
       -include $ROOT/itlwm/PrivateSPI.pch)
CXXFLAGS=(-x c++ -std=gnu++14 -nostdinc++ -fno-exceptions -fno-rtti -fapple-kext
          -Wno-deprecated-register -Wno-deprecated-declarations -Wno-inconsistent-missing-override
          -Wno-unused-value -Wno-c++11-narrowing -Wno-writable-strings -Wno-invalid-offsetof)

rm -rf $KEXT; mkdir -p $KEXT/Contents/MacOS $OBJ
sed -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BID/g" -e "s/\$(PRODUCT_NAME)/$NAME/g" \
    -e "s/\$(EXECUTABLE_NAME)/$NAME/g" -e "s/\$(DEVELOPMENT_LANGUAGE)/en/g" \
    -e "s/\$(MODULE_VERSION)/$VER/g" -e "s/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/KEXT/g" \
    $ROOT/AirportItlwm/WCL/Info.plist > $KEXT/Contents/Info.plist
grep -q '\$(' $KEXT/Contents/Info.plist && { echo "unresolved variable in Info.plist"; exit 1; }
plutil -lint $KEXT/Contents/Info.plist >/dev/null

cat > $OBJ/kmodinfo.c <<EOC
#include <mach/mach_types.h>
extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL($BID, "$VER", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
EOC
clang -arch x86_64 -mkernel -nostdinc -mmacosx-version-min=10.15 -DKERNEL -isystem $SDK/Headers \
  -c $OBJ/kmodinfo.c -o $OBJ/kmodinfo.o

compile() {
  local src=$1 obj=$OBJ/${${1//\//_}%.*}.o
  [[ -f $obj && $obj -nt $ROOT/$src ]] && return 0
  clang++ $FLAGS $CXXFLAGS -c $ROOT/$src -o $obj 2>$obj.log || { echo "FAILED $src"; tail -30 $obj.log; return 1; }
}
pids=(); failed=0
for s in $SRCS; do
  compile $s & pids+=$!
  if (( ${#pids} >= JOBS )); then wait ${pids[1]} || failed=1; shift pids; fi
done
for p in $pids; do wait $p || failed=1; done
(( failed )) && { echo "compile failed"; exit 1; }

clang++ -arch x86_64 -mkernel -nostdlib -static -Xlinker -kext -Xlinker -export_dynamic \
  -mmacosx-version-min=10.15 $OBJ/kmodinfo.o $OBJ/*_*.o $SDK/Library/x86_64/libkmod.a -lcc_kext \
  -o $KEXT/Contents/MacOS/$NAME
codesign -f -s - $KEXT >/dev/null 2>&1 || true
echo "built $KEXT ($VER, $COMMIT)"
