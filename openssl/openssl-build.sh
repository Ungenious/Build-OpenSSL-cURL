#!/bin/bash

# This script downlaods and builds the Mac, iOS and tvOS openSSL libraries with Bitcode enabled

# Credits:
#
# Stefan Arentz
#   https://github.com/st3fan/ios-openssl
# Felix Schulze
#   https://github.com/x2on/OpenSSL-for-iPhone/blob/master/build-libssl.sh
# James Moore
#   https://gist.github.com/foozmeat/5154962
# Peter Steinberger, PSPDFKit GmbH, @steipete.
#   https://gist.github.com/felix-schwarz/c61c0f7d9ab60f53ebb0
# Jason Cox, @jasonacox
#   https://github.com/jasonacox/Build-OpenSSL-cURL

set -e

# set trap to help debug build errors
trap 'echo "** ERROR with Build - Check /tmp/openssl*.log"; tail /tmp/openssl*.log' INT TERM EXIT

usage ()
{
	echo "usage: $0 [openssl version] [iOS SDK version (defaults to latest)] [tvOS SDK version (defaults to latest)]"
	trap - INT TERM EXIT
	exit 127
}

if [ "$1" == "-h" ]; then
	usage
fi

if [ -z $2 ]; then
	IOS_SDK_VERSION="" #"9.1"
	IOS_MIN_SDK_VERSION="11.0"

	TVOS_SDK_VERSION="" #"9.0"
	TVOS_MIN_SDK_VERSION="11.0"
else
	IOS_SDK_VERSION=$2
	TVOS_SDK_VERSION=$3
fi

if [ -z $1 ]; then
	OPENSSL_VERSION="openssl-1.1.1a"
else
	OPENSSL_VERSION="openssl-$1"
fi

DEVELOPER=`xcode-select -print-path`

buildMac()
{
	ARCH=$1
	PLATFORM="macOS"

	echo "Building ${OPENSSL_VERSION} for ${PLATFORM} for ${ARCH}"

	TARGET="darwin-i386-cc"

	if [[ $ARCH == "x86_64" ]]; then
		TARGET="darwin64-x86_64-cc"
	fi

	export CC="${BUILD_TOOLS}/usr/bin/clang"

	pushd . > /dev/null
	cd "${OPENSSL_VERSION}"
	./Configure no-asm ${TARGET} --prefix="/tmp/${OPENSSL_VERSION}-${PLATFORM}-${ARCH}" &> "/tmp/${OPENSSL_VERSION}-${PLATFORM}-${ARCH}.log"
	make -j8 >> "/tmp/${OPENSSL_VERSION}-${PLATFORM}-${ARCH}.log" 2>&1
	make install_sw >> "/tmp/${OPENSSL_VERSION}-${PLATFORM}-${ARCH}.log" 2>&1
	# Keep openssl binary for Mac version
	cp "/tmp/${OPENSSL_VERSION}-${PLATFORM}-${ARCH}/bin/openssl" "/tmp/openssl"
	make clean >> "/tmp/${OPENSSL_VERSION}-${PLATFORM}-${ARCH}.log" 2>&1	
	popd > /dev/null
}

buildIOS()
{
	ARCH=$1
	BITCODE=$2

	pushd . > /dev/null
	cd "${OPENSSL_VERSION}"

	if [[ "${ARCH}" == "i386" || "${ARCH}" == "x86_64" ]]; then
		PLATFORM="iPhoneSimulator"
		CLANG_VERSION_FLAG="-miphonesimulator-version-min"
	else
		PLATFORM="iPhoneOS"
		CLANG_VERSION_FLAG="-miphoneos-version-min"
		sed -ie "s!static volatile sig_atomic_t intr_signal;!static volatile intr_signal;!" "crypto/ui/ui_openssl.c"
	fi

    if [[ "${BITCODE}" == "nobitcode" ]]; then
            CC_BITCODE_FLAG=""
    else
            CC_BITCODE_FLAG="-fembed-bitcode"
    fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${IOS_SDK_VERSION}.sdk"
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc -arch ${ARCH} ${CC_BITCODE_FLAG}"

	echo "Building ${OPENSSL_VERSION} for ${PLATFORM} ${IOS_SDK_VERSION} ${ARCH}"

	if [[ "${ARCH}" == "x86_64" ]]; then
		./Configure no-asm no-shared darwin64-x86_64-cc --prefix="/tmp/${OPENSSL_VERSION}-iOS-${ARCH}" &> "/tmp/${OPENSSL_VERSION}-iOS-${ARCH}.log"
	else
		./Configure ios64-xcrun no-shared --prefix="/tmp/${OPENSSL_VERSION}-iOS-${ARCH}" &> "/tmp/${OPENSSL_VERSION}-iOS-${ARCH}.log"
	fi

	# add -isysroot to CC=
	sed -ie "s|^CFLAGS=|CFLAGS= -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} ${CLANG_VERSION_FLAG}=${IOS_MIN_SDK_VERSION} |" "Makefile"	

	make -j8 >> "/tmp/${OPENSSL_VERSION}-iOS-${ARCH}.log" 2>&1
	make install_sw >> "/tmp/${OPENSSL_VERSION}-iOS-${ARCH}.log" 2>&1
	make clean >> "/tmp/${OPENSSL_VERSION}-iOS-${ARCH}.log" 2>&1
	popd > /dev/null
}

buildTVOS()
{
	ARCH=$1

	pushd . > /dev/null
	cd "${OPENSSL_VERSION}"

	if [[ "${ARCH}" == "i386" || "${ARCH}" == "x86_64" ]]; then
		PLATFORM="AppleTVSimulator"
		CLANG_VERSION_FLAG="-mappletvsimulator-version-min"
	else
		PLATFORM="AppleTVOS"
		CLANG_VERSION_FLAG="-mtvos-version-min"
		sed -ie "s!static volatile sig_atomic_t intr_signal;!static volatile intr_signal;!" "crypto/ui/ui_openssl.c"
	fi

	export $PLATFORM
	export CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
	export CROSS_SDK="${PLATFORM}${TVOS_SDK_VERSION}.sdk"
	export BUILD_TOOLS="${DEVELOPER}"
	export CC="${BUILD_TOOLS}/usr/bin/gcc -fembed-bitcode -arch ${ARCH}"
	export LC_CTYPE=C

	echo "Building ${OPENSSL_VERSION} for ${PLATFORM} ${TVOS_SDK_VERSION} ${ARCH}"

	# Patch apps/speed.c to not use fork() since it's not available on tvOS
	LANG=C sed -i -- 's/define HAVE_FORK 1/define HAVE_FORK 0/' "./apps/speed.c"

	# Patch apps/ocsp.c to not define OCSP_DAEMON which requires fork
	LANG=C sed -i -- 's|#  define OCSP_DAEMON|\/\/&|' "./apps/ocsp.c"

	# Patch Configure to build for tvOS, not iOS
	LANG=C sed -i -- 's/D\_REENTRANT\:iOS/D\_REENTRANT\:tvOS/' "./Configure"
	chmod u+x ./Configure

	if [[ "${ARCH}" == "x86_64" ]]; then
		./Configure tvossimulator-xcrun no-shared no-asm --prefix="/tmp/${OPENSSL_VERSION}-tvOS-${ARCH}" &> "/tmp/${OPENSSL_VERSION}-tvOS-${ARCH}.log"
	else
		./Configure tvos64-xcrun no-shared --prefix="/tmp/${OPENSSL_VERSION}-tvOS-${ARCH}" &> "/tmp/${OPENSSL_VERSION}-tvOS-${ARCH}.log"
	fi
	
	# add -isysroot to CC=	
	sed -ie "s|^CFLAGS=|CFLAGS= -isysroot ${CROSS_TOP}/SDKs/${CROSS_SDK} ${CLANG_VERSION_FLAG}=${TVOS_MIN_SDK_VERSION} |" "Makefile"	

	make -j8 >> "/tmp/${OPENSSL_VERSION}-tvOS-${ARCH}.log" 2>&1	
	make install_sw >> "/tmp/${OPENSSL_VERSION}-tvOS-${ARCH}.log" 2>&1
	make clean >> "/tmp/${OPENSSL_VERSION}-tvOS-${ARCH}.log" 2>&1
	popd > /dev/null
}


echo "Cleaning up"
rm -rf include/openssl/* lib/*

mkdir -p Mac/lib
mkdir -p iOS/lib
mkdir -p tvOS/lib
mkdir -p Mac/include/openssl/
mkdir -p iOS/include/openssl/
mkdir -p tvOS/include/openssl/

rm -rf "/tmp/${OPENSSL_VERSION}-*"
rm -rf "/tmp/${OPENSSL_VERSION}-*.log"

rm -rf "${OPENSSL_VERSION}"

if [ ! -e ${OPENSSL_VERSION}.tar.gz ]; then
	echo "Downloading ${OPENSSL_VERSION}.tar.gz"
	curl -LO https://www.openssl.org/source/${OPENSSL_VERSION}.tar.gz
else
	echo "Using ${OPENSSL_VERSION}.tar.gz"
fi

echo "Unpacking openssl"
tar xfz "${OPENSSL_VERSION}.tar.gz"

echo "Building Mac libraries"
buildMac "x86_64"

echo "Copying headers"
cp /tmp/${OPENSSL_VERSION}-macOS-x86_64/include/openssl/* Mac/include/openssl/

lipo \
	"/tmp/${OPENSSL_VERSION}-macOS-x86_64/lib/libcrypto.a" \
	-create -output Mac/lib/libcrypto.a

lipo \
	"/tmp/${OPENSSL_VERSION}-macOS-x86_64/lib/libssl.a" \
	-create -output Mac/lib/libssl.a

echo "Building iOS libraries (bitcode)"
buildIOS "arm64" "bitcode"
buildIOS "x86_64" "bitcode"
# buildIOS "armv7" "nobitcode"
# buildIOS "armv7s" "nobitcode"
# buildIOS "i386" "bitcode"

echo "Copying headers"
cp /tmp/${OPENSSL_VERSION}-iOS-arm64/include/openssl/* iOS/include/openssl/

lipo \
	"/tmp/${OPENSSL_VERSION}-iOS-arm64/lib/libcrypto.a" \
	"/tmp/${OPENSSL_VERSION}-iOS-x86_64/lib/libcrypto.a" \
	-create -output iOS/lib/libcrypto.a

lipo \
	"/tmp/${OPENSSL_VERSION}-iOS-arm64/lib/libssl.a" \
	"/tmp/${OPENSSL_VERSION}-iOS-x86_64/lib/libssl.a" \
	-create -output iOS/lib/libssl.a

echo "Copying tvos conf file"
cp "/Users/brain/Development/15-tvos.conf" "${OPENSSL_VERSION}/Configurations/"

echo "Building tvOS libraries"
buildTVOS "x86_64"
buildTVOS "arm64"

echo "Copying headers"
cp /tmp/${OPENSSL_VERSION}-tvOS-arm64/include/openssl/* tvOS/include/openssl/

lipo \
	"/tmp/${OPENSSL_VERSION}-tvOS-arm64/lib/libcrypto.a" \
	"/tmp/${OPENSSL_VERSION}-tvOS-x86_64/lib/libcrypto.a" \
	-create -output tvOS/lib/libcrypto.a

lipo \
	"/tmp/${OPENSSL_VERSION}-tvOS-arm64/lib/libssl.a" \
	"/tmp/${OPENSSL_VERSION}-tvOS-x86_64/lib/libssl.a" \
	-create -output tvOS/lib/libssl.a

echo "Cleaning up"
rm -rf /tmp/${OPENSSL_VERSION}-*
rm -rf ${OPENSSL_VERSION}

#reset trap
trap - INT TERM EXIT

echo "Done"
