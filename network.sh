#!/bin/bash

export PATH=$PWD/bin:$PATH

. utils.sh

# Print the usage message
function printHelp() {
    echo "Usage: "
    echo "  network.sh <mode>"
    echo "    <mode> - one of 'up', 'down', 'restart', 'reset' or 'generate'"
    echo "      - 'up' - bring up the network with docker-compose up"
    echo "      - 'down' - clear the network with docker-compose down"
    echo "      - 'restart' - restart the network"
    echo "      - 'reset' - deletes all config and blocks so you can start fresh"
    echo "      - 'generate' - generate required certificates and genesis block"
    echo "  network.sh -h (print this message)"
}

function checkPrereqs() {
    # Note, we check configtxlator externally because it does not require a config file, and peer in the
    # docker image because of FAB-8551 that makes configtxlator return 'development version' in docker
    LOCAL_VERSION=$(configtxlator version | sed -ne 's/ Version: //p')
    DOCKER_IMAGE_VERSION=$(sudo docker run --rm hyperledger/fabric-tools:1.4.4 peer version | sed -ne 's/ Version: //p' | head -1)

    echo "LOCAL_VERSION=$LOCAL_VERSION"
    echo "DOCKER_IMAGE_VERSION=$DOCKER_IMAGE_VERSION"

    if [ "$LOCAL_VERSION" != "$DOCKER_IMAGE_VERSION" ]; then
        echo "=================== WARNING ==================="
        echo "  Local fabric binaries and docker images are  "
        echo "  out of sync. This may cause problems.        "
        echo "==============================================="
    fi

    for tool in cryptogen configtxgen; do
        which $tool > /dev/null 2>&1

        if [ "$?" -ne 0 ]; then
            echo "${tool} not found. Have you run the bootstrap script?"
            exit 1
        fi
    done
}

function generateGenesisBlock() {
    if [ -d "orderer.divvy.com" ]; then
        rm -rf ./orderer.divvy.com
    fi

    mkdir ./orderer.divvy.com

    configtxgen -profile Genesis -channelID sys-channel -outputBlock ./orderer.divvy.com/genesis.block

    if [ $? -ne 0 ]; then
        echo "Failed to generate orderer genesis block..."
        exit 1
    fi
}

function generateDockerCompose() {
    local currentDir=$PWD

    cd "crypto-config/ordererOrganizations/divvy.com/ca/"
    local privKey=$(ls *_sk)

    cd "$currentDir"

    sed -e "s/\${PRIV_KEY}/$privKey/g" ./templates/docker-compose-net.yaml
}

function networkUp() {
    checkPrereqs

    if [ ! -d "crypto-config" ]; then
        echo "Generating certificates for orderer..."
        generateCryptoMaterial ./crypto-config.yaml
        echo

        echo "Generating docker compose file..."
        generateDockerCompose > ./docker-compose.yaml
        echo

        echo "Generating genesis block..."
        generateGenesisBlock
        echo
    fi

    # Bring up the core containers.
    sudo docker-compose -f docker-compose.yaml up -d 2>&1
    sudo docker-compose -f ../api/docker-compose.yaml up -d 2>&1
    sudo docker-compose -f ../application/docker-compose.yaml up -d 2>&1

    # Bring up the Org containers.
    sudo docker-compose $(find ./org-config/ -name 'docker-compose.yaml' | sed 's/.*/-f &/' | tr '\n\r' ' ') up -d 2>&1

    sudo docker ps -a

    if [ $? -ne 0 ]; then
        echo "ERROR !!!! Unable to start network"
        exit 1
    fi
}

function clearContainers() {
    CONTAINER_IDS=$(sudo docker ps -a | awk '($2 ~ /dev-peer.*/) {print $1}')

    if [ -z "$CONTAINER_IDS" -o "$CONTAINER_IDS" == " " ]; then
        echo "---- No containers available for deletion ----"
    else
        sudo docker rm -f $CONTAINER_IDS
    fi
}

function removeUnwantedImages() {
    DOCKER_IMAGE_IDS=$(sudo docker images | awk '($1 ~ /dev-peer.*/) {print $3}')

    if [ -z "$DOCKER_IMAGE_IDS" -o "$DOCKER_IMAGE_IDS" == " " ]; then
        echo "---- No images available for deletion ----"
    else
        sudo docker rmi -f $DOCKER_IMAGE_IDS
    fi
}

function networkDown() {
    # Remove Org containers.
    sudo docker-compose $(find ./org-config/ -name 'docker-compose.yaml' | sed 's/.*/-f &/' | tr '\n\r' ' ') down --volumes --remove-orphans

    # Remove core containers.
    sudo docker-compose -f ../api/docker-compose.yaml down --volumes --remove-orphans
    sudo docker-compose -f ../application/docker-compose.yaml down --volumes --remove-orphans
    sudo docker-compose -f ./docker-compose.yaml down --volumes --remove-orphans

    # Don't remove the generated artifacts -- note, the ledgers are always removed
    if [ "$MODE" != "restart" ]; then
        sudo docker run -v $PWD:/tmp/divvy --rm hyperledger/fabric-tools:1.4.4 rm -Rf /tmp/divvy/ledgers-backup

        clearContainers

        removeUnwantedImages
    fi
}

function networkReset() {
    rm -rf ./crypto-config ./orderer.divvy.com ./org-config ./docker-compose.yaml
}

MODE=$1
shift

if [ "$MODE" == "up" ]; then
    EXPMODE="Starting"
elif [ "$MODE" == "down" ]; then
    EXPMODE="Stopping"
elif [ "$MODE" == "restart" ]; then
    EXPMODE="Restarting"
elif [ "$MODE" == "reset" ]; then
    EXPMODE="Resetting"
elif [ "$MODE" == "generate" ]; then
    EXPMODE="Generating certs and genesis block"
else
    printHelp
    exit 1
fi

while getopts "h" opt; do
    case "$opt" in
        h)
            printHelp
            exit 0
            ;;
    esac
done

if [ "${MODE}" == "up" ]; then
    networkUp
elif [ "${MODE}" == "down" ]; then ## Clear the network
    networkDown
elif [ "${MODE}" == "generate" ]; then ## Generate Artifacts
    echo "Generating certificates for orderer..."
    generateCryptoMaterial ./crypto-config.yaml
    echo

    echo "Generating docker compose file..."
    generateDockerCompose > ./docker-compose.yaml
    echo

    echo "Generating genesis block..."
    generateGenesisBlock
    echo

    echo "Done"
elif [ "${MODE}" == "restart" ]; then ## Restart the network
    networkDown
    networkUp
elif [ "${MODE}" == "reset" ]; then ## Reset the network
    networkDown
    networkReset
else
    printHelp
    exit 1
fi
