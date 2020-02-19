#!/bin/bash

# if version not passed in, default to latest released version
export VERSION=1.4.4

# if ca version not passed in, default to latest released version
export CA_VERSION=1.4.4

export ARCH=$(echo "$(uname -s|tr '[:upper:]' '[:lower:]'|sed 's/mingw64_nt.*/windows/')-$(uname -m | sed 's/x86_64/amd64/g')")

export MARCH=$(uname -m)

printHelp() {
    echo "Usage: bootstrap.sh [version [ca_version]] [options]"
    echo
    echo "options:"
    echo "-h : this help"
    echo "-d : bypass docker image download"
    echo "-b : bypass download of platform-specific binaries"
    echo
    echo "e.g. bootstrap.sh 1.4.4"
    echo "would download docker images and binaries for version 1.4.4"
}

dockerFabricPull() {
    local FABRIC_TAG=$1

    for IMAGES in peer orderer ccenv tools; do
        echo "==> FABRIC IMAGE: $IMAGES"
        echo

        docker pull hyperledger/fabric-$IMAGES:$FABRIC_TAG
        docker tag hyperledger/fabric-$IMAGES:$FABRIC_TAG hyperledger/fabric-$IMAGES
    done
}

dockerCaPull() {
    local CA_TAG=$1

    echo "==> FABRIC CA IMAGE"
    echo

    docker pull hyperledger/fabric-ca:$CA_TAG
    docker tag hyperledger/fabric-ca:$CA_TAG hyperledger/fabric-ca
}

binaryDownload() {
    local BINARY_FILE=$1
    local URL=$2

    echo "===> Downloading: " ${URL}

    wget "${URL}" -q || rc=$?
    tar xvzf "${BINARY_FILE}" || rc=$?
    rm "${BINARY_FILE}"

    if [ -n "$rc" ]; then
        echo "==> There was an error downloading the binary file."
        return 22
    else
        echo "==> Done."
    fi
}

binariesInstall() {
    echo "===> Downloading version ${FABRIC_TAG} platform specific fabric binaries"
    binaryDownload ${BINARY_FILE} "https://github.com/hyperledger/fabric/releases/download/v${VERSION}/${BINARY_FILE}"

    if [ $? -eq 22 ]; then
        echo
        echo "------> ${FABRIC_TAG} platform specific fabric binary is not available to download <----"
        echo
    fi

    echo "===> Downloading version ${CA_TAG} platform specific fabric-ca-client binary"
    binaryDownload ${CA_BINARY_FILE} "https://github.com/hyperledger/fabric-ca/releases/download/v${CA_VERSION}/${CA_BINARY_FILE}"

    if [ $? -eq 22 ]; then
        echo
        echo "------> ${CA_TAG} fabric-ca-client binary is not available to download  (Available from 1.1.0-rc1) <----"
        echo
    fi
}

dockerInstall() {
    which docker >& /dev/null
    NODOCKER=$?

    if [ "${NODOCKER}" == 0 ]; then
        echo "===> Pulling fabric Images"
        dockerFabricPull ${FABRIC_TAG}
        echo "===> Pulling fabric ca Image"
        dockerCaPull ${CA_TAG}
        echo "===> List out hyperledger docker images"
        docker images | grep hyperledger*
    else
        echo "========================================================="
        echo "Docker not installed, bypassing download of Fabric images"
        echo "========================================================="
    fi
}

DOCKER=true
BINARIES=true

# prior to 1.2.0 architecture was determined by uname -m
if [[ $VERSION =~ ^1\.[0-1]\.* ]]; then
    export FABRIC_TAG=${MARCH}-${VERSION}
    export CA_TAG=${MARCH}-${CA_VERSION}
else
  # starting with 1.2.0, multi-arch images will be default
  : ${CA_TAG:="$CA_VERSION"}
  : ${FABRIC_TAG:="$VERSION"}
fi

BINARY_FILE=hyperledger-fabric-${ARCH}-${VERSION}.tar.gz
CA_BINARY_FILE=hyperledger-fabric-ca-${ARCH}-${CA_VERSION}.tar.gz

# then parse opts
while getopts "h?db" opt; do
    case "$opt" in
        h|\?)
            printHelp
            exit 0
        ;;
        d)  DOCKER=false
        ;;
        b)  BINARIES=false
        ;;
    esac
done

if [ "$BINARIES" == "true" ]; then
    echo
    echo "Installing Hyperledger Fabric binaries"
    echo
    binariesInstall
fi
if [ "$DOCKER" == "true" ]; then
    echo
    echo "Installing Hyperledger Fabric docker images"
    echo
    dockerInstall
fi
