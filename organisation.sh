#!/bin/bash

ORDERER_CLI="cli.divvy.com"
ORDERER_PEER="orderer.divvy.com:7050"

API_CONTAINER="api.divvy.com"

ORG=""
PEER_PORT=""
CA_PORT=""
CC_PORT=""
CHANNEL_OWNER=""

CHANNEL=""
MSP_NAME=""
CONFIG_DIR=""
VOLUME_DIR=""
CRYPTO_DIR=""
CLI_OUTPUT_DIR=""
ORG_CLI=""
ORG_PEER=""
CHANNEL_OWNER_CLI=""

. utils.sh

export PATH=$PWD/bin:$PATH

# Print the usage message
function printHelp() {
    echo "Usage: "
    echo "  organisation.sh <mode> --org <org name> [--pport <port>] [--caport <port>] [--ccport] [--channelowner <channel owner>]"
    echo "    <mode> - one of 'create', 'remove', or 'joinchannel'"
    echo "      - 'create' - bring up the network with docker-compose up"
    echo "      - 'remove' - clear the network with docker-compose down"
    echo "      - 'joinchannel' - joins an org peer to a channel"
    echo "      - 'showchannels' - lists all channels an org peer has joined"
    echo "      - 'nodestatus' - shows the status of an org peer node"
    echo "      - 'channelinfo' - show blockchain information of an org channel."
    echo "    --org <org name> - name of the org to use"
    echo "    --pport <port> - port the org peer listens on"
    echo "    --caport <port> - port the org CA listens on"
    echo "    --ccport <port> - port the org peer chaincode listens on"
    echo "    --channelowner <channel owner> - org who owns the channel being joined"
    echo "  organisation.sh --help (print this message)"
}

function checkPrereqs() {
    for tool in cryptogen configtxgen; do
        which $tool > /dev/null 2>&1

        if [ "$?" -ne 0 ]; then
            echo "${tool} not found. Make sure the binaries have been added to your path."
            exit 1
        fi
    done
}

function generateCryptoConfig() {
    sed -e "s/\${ORG}/$1/g" ./templates/crypto-config.yaml
}

function generateNetworkConfig() {
    sed -e "s/\${ORG}/$1/g" \
        -e "s/\${MSP_NAME}/$2/g" \
        -e "s/\${PEER_PORT}/$3/g" \
        ./templates/configtx.yaml
}

function generateOrgDefinition() {
    echo "Generating Org definition..."

    configtxgen -configPath $1 -printOrg $2 > "$1/${ORG}.json"

    if [ $? -ne 0 ]; then
        exit 1
    fi

    echo
}

function oneLinePem {
    echo "`awk 'NF {sub(/\\n/, ""); printf "%s\\\\\\\n",$0;}' $1`"
}

function generateConnectionProfile {
    local PP=$(oneLinePem "crypto-config/peerOrganizations/$1.divvy.com/tlsca/tlsca.$1.divvy.com-cert.pem")
    local CP=$(oneLinePem "crypto-config/peerOrganizations/$1.divvy.com/ca/ca.$1.divvy.com-cert.pem")

    sed -e "s/\${ORG}/$1/" \
        -e "s/\${MSP_NAME}/$2/" \
        -e "s/\${PEER_PORT}/$3/" \
        -e "s/\${CA_PORT}/$4/" \
        -e "s#\${PEER_PEM}#$PP#" \
        -e "s#\${CA_PEM}#$CP#" \
        ./templates/connection-profile.json
}

function generateDockerCompose() {
    local CURRENT_DIR=$PWD

    cd "crypto-config/peerOrganizations/$1.divvy.com/ca/"
    local PRIV_KEY=$(ls *_sk)

    cd "$CURRENT_DIR"

    sed -e "s/\${ORG}/$1/g" \
        -e "s/\${MSP_NAME}/$2/g" \
        -e "s/\${PEER_PORT}/$3/g" \
        -e "s/\${CA_PORT}/$4/g" \
        -e "s/\${CC_PORT}/$5/g" \
        -e "s/\${PRIV_KEY}/$PRIV_KEY/g" \
        ./templates/docker-compose-org.yaml
}

function cliMkdirp() {
    echo
    echo "Creating directory $2 on $1..."
    echo

    sudo docker exec $1 mkdir -p $2

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliRmrf() {
    echo
    echo "Removing directory $2 on $1..."
    echo

    sudo docker exec $1 rm -rf $2

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliFetchLatestChannelConfigBlock() {
    echo
    echo "Fetching latest config block for channel $2..."
    echo

    sudo docker exec $1 peer channel fetch config $3 --tls --cafile $4 -o $ORDERER_PEER -c $2

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliDecodeConfigBlock() {
    echo
    echo "Decoding config block..."
    echo

    local type="${4:-common.Block}"
    local treePath="${5:-.data.data[0].payload.data.config}"

    sudo docker exec -i $1 bash <<EOF
        configtxlator proto_decode --input "$2" --type "$type" | jq "$treePath" > "$3"
EOF

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliEncodeConfigJson() {
    echo
    echo "Encoding config block..."
    echo

    local type="${4:-common.Config}"

    sudo docker exec $1 configtxlator proto_encode \
        --input $2 \
        --output $3 \
        --type $type

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliGenerateUpdateBlock() {
    echo
    echo "Generating config update block for channel $2..."
    echo

    sudo docker exec $1 configtxlator compute_update \
        --channel_id $2 \
        --original $3 \
        --updated $4 \
        --output $5

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliAddConfigUpdateHeader() {
    echo
    echo "Adding header to config update for channel $2..."
    echo

    sudo docker exec -i \
        -e channel=$2 \
        -e updatesFile=$3 \
        -e outFile=$4 \
        $1 bash -c 'updates=$(< $updatesFile); echo \''{\""payload\"":{\""header\"":{\""channel_header\"":{\""channel_id\"":\""$channel\"", \""type\"":2}},\""data\"":{\""config_update\"":$updates}}}\'' | jq . > $outFile'

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliSubmitChannelUpdate() {
    echo
    echo "Submitting config update for channel $3..."
    echo

    sudo docker exec $1 peer channel update -f $2 -c $3 -o $ORDERER_PEER --tls --cafile $4

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliFetchChannelGenesisBlock() {
    echo
    echo "Fetching genesis block for channel $2..."
    echo

    sudo docker exec $1 peer channel fetch 0 $3 -o $ORDERER_PEER -c $2 --tls --cafile $4

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliJoinPeerToChannel() {
    echo
    echo "Joining $ORG_PEER to channel $2..."
    echo

    sudo docker exec $1 peer channel join -b $3 --tls --cafile $4

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliPeerNodeStatus() {
    sudo docker exec $1 peer node status

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliChannelInfo() {
    sudo docker exec $1 peer channel getinfo -c $2

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function listPeerChannels() {
    echo
    sudo docker exec $1 peer channel list
    echo

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliInstallChaincode() {
    echo
    echo "Installing chaincode $2 v$3 on peer..."
    echo

    local path="${4:-chaincode}"

    sudo docker exec $1 peer chaincode install \
        -n $2 \
        -v $3 \
        -p $path \
        -l node

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function cliInstantiateChaincode() {
    echo
    echo "Instanciating chaincode $2 v$3 on channel $4..."
    echo

    sudo docker exec $1 peer chaincode instantiate \
        -o $ORDERER_PEER \
        -n $2 \
        -v $3 \
        -C $4 \
        -c $5 \
        -P $6 \
        -l node \
        --tls \
        --cafile $7

    if [ $? -ne 0 ]; then
        exit 1
    fi

    # Wait for instantiation request to be committed.
    sleep 10
}

function cliInvokeChaincode() {
    echo
    echo "Inkoving initial $2 ledger transaction on $3 channel..."
    echo

    sudo docker exec $1 peer chaincode invoke \
        -o $ORDERER_PEER \
        -n $2 \
        -C $3 \
        -c $4 \
        --tls \
        --cafile $5

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function addOrgToConsortium() {
    local ORG_DEF="./org-config/$1/$1.json"
    local CONF_BLOCK="$CLI_OUTPUT_DIR/config-$1.pb"
    local CONF_MOD_BLOCK="$CLI_OUTPUT_DIR/config-modified-$1.pb"
    local CONF_DELTA_BLOCK="$CLI_OUTPUT_DIR/config-delta-$1.pb"
    local CONF_JSON="$CLI_OUTPUT_DIR/config-$1.json"
    local CONF_MOD_JSON="$CLI_OUTPUT_DIR/config-modified-$1.json"
    local CONF_DELTA_JSON="$CLI_OUTPUT_DIR/config-delta-$1.json"
    local PAYLOAD_BLOCK="$CLI_OUTPUT_DIR/payload-$1.pb"
    local PAYLOAD_JSON="$CLI_OUTPUT_DIR/payload-$1.json"
    local CA_PATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto-config/msp/tlscacerts/tlsca.divvy.com-cert.pem

    cliMkdirp $ORDERER_CLI $CLI_OUTPUT_DIR

    cliFetchLatestChannelConfigBlock $ORDERER_CLI $CHANNEL $CONF_BLOCK $CA_PATH

    cliDecodeConfigBlock $ORDERER_CLI $CONF_BLOCK $CONF_JSON

    # Add the Org definition to config.
    sudo docker exec -i $ORDERER_CLI bash <<EOF
        jq -s '.[0] * {"channel_group":{"groups":{"Consortiums":{"groups": {"Default": {"groups": {"$MSP_NAME":.[1]}, "mod_policy": "/Channel/Orderer/Admins", "policies": {}, "values": {"ChannelCreationPolicy": {"mod_policy": "/Channel/Orderer/Admins","value": {"type": 3,"value": {"rule": "ANY","sub_policy": "Admins"}},"version": "0"}},"version": "0"}}}}}}' $CONF_JSON $ORG_DEF > $CONF_MOD_JSON
EOF

    if [ $? -ne 0 ]; then
        exit 1
    fi

    # Convert the origional (extracted) config to a block, so we can diff it against the updates.
    cliEncodeConfigJson $ORDERER_CLI $CONF_JSON $CONF_BLOCK

    # Convert the updated config to a block, so we can diff it against the origional.
    cliEncodeConfigJson $ORDERER_CLI $CONF_MOD_JSON $CONF_MOD_BLOCK

    # Diff the changes to create an "update" block.
    cliGenerateUpdateBlock $ORDERER_CLI $CHANNEL $CONF_BLOCK $CONF_MOD_BLOCK $CONF_DELTA_BLOCK

    # Convert the update block to JSON so we can add a header.
    cliDecodeConfigBlock $ORDERER_CLI $CONF_DELTA_BLOCK $CONF_DELTA_JSON common.ConfigUpdate '.'

    # Add the header.
    cliAddConfigUpdateHeader $ORDERER_CLI $CHANNEL $CONF_DELTA_JSON $PAYLOAD_JSON

    # Convert the payload to a block.
    cliEncodeConfigJson $ORDERER_CLI $PAYLOAD_JSON $PAYLOAD_BLOCK common.Envelope

    # Make the update.
    cliSubmitChannelUpdate $ORDERER_CLI $PAYLOAD_BLOCK $CHANNEL $CA_PATH

    # Clean up.
    cliRmrf $ORDERER_CLI $CLI_OUTPUT_DIR
}

function createOrgChannel() {
    local orgChannelId="$2-channel"
    local ordererCaPath=/etc/hyperledger/fabric/orderer/msp/tlscacerts/tlsca.divvy.com-cert.pem

    echo "Generating config transactions..."

    # Generate the channel configuration transation.
    configtxgen \
        -configPath $1 \
        -profile $orgChannelId \
        -outputCreateChannelTx "$1/channel.tx" \
        -channelID $orgChannelId

    # Generate the anchor peer transaction.
    configtxgen \
        -configPath $1 \
        -profile $orgChannelId \
        -outputAnchorPeersUpdate "$1/$2-msp-anchor-$2-channel.tx" \
        -channelID $orgChannelId \
        -asOrg "$2-msp"

    echo
    echo "Creating channel..."

    sudo docker exec \
        -e "CORE_PEER_MSPCONFIGPATH=/etc/hyperledger/fabric/msp/users/Admin@$2.divvy.com/msp" \
        $ORG_PEER peer channel create \
        -o $ORDERER_PEER \
        -c "$orgChannelId" \
        -f ./org-config/channel.tx \
        --tls \
        --cafile $ordererCaPath

    if [ $? -ne 0 ]; then
        exit 1
    fi

    echo
    echo "Adding peer to channel..."

    sudo docker exec \
        -e "CORE_PEER_MSPCONFIGPATH=/etc/hyperledger/fabric/msp/users/Admin@$2.divvy.com/msp" \
        $ORG_PEER peer channel join \
        -b "$orgChannelId.block"

    if [ $? -ne 0 ]; then
        exit 1
    fi

    # Check the peer successfully joined the channel.
    listPeerChannels $ORG_PEER

    echo
    echo "Adding anchor peer config to channel..."

    sudo docker exec \
        -e "CORE_PEER_MSPCONFIGPATH=/etc/hyperledger/fabric/msp/users/Admin@$2.divvy.com/msp" \
        $ORG_PEER peer channel update \
        -o $ORDERER_PEER \
        -c "$orgChannelId" \
        -f ./org-config/"$2-msp-anchor-$2-channel.tx" \
        --tls \
        --cafile $ordererCaPath

    if [ $? -ne 0 ]; then
        exit 1
    fi
}

checkPrereqs

MODE=$1
shift

if [ "$MODE" != "create" ] && [ "$MODE" != "remove" ] && [ "$MODE" != "joinchannel" ] && [ "$MODE" != "showchannels" ] && [ "$MODE" != "nodestatus" ] && [ "$MODE" != "channelinfo" ]; then
    printHelp
    exit 1
fi

POSITIONAL=()
while [[ $# -gt 0 ]]
do
    opt="$1"
    case "$opt" in
        --help)
            printHelp
            exit 0
            ;;
        --org)
            ORG="$(generateSlug $2)"
            MSP_NAME="${ORG}-msp"
            shift
            shift
            ;;
        --pport)
            PEER_PORT=$2
            shift
            shift
            ;;
        --caport)
            CA_PORT=$2
            shift
            shift
            ;;
        --ccport)
            CC_PORT=$2
            shift
            shift
            ;;
        --channelowner)
            CHANNEL_OWNER=$2
            CHANNEL_OWNER_CLI="cli.$2.divvy.com"
            CHANNEL="$2-channel"
            shift
            shift
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

if [ "$ORG" == "" ]; then
    echo "No organisation name specified."
    echo
    printHelp
    exit 1
fi

CONFIG_DIR="$PWD/org-config/$ORG"
VOLUME_DIR="$PWD/peer.$ORG.divvy.com"
CRYPTO_DIR="$PWD/crypto-config/peerOrganizations/$ORG.divvy.com"
CLI_OUTPUT_DIR="./org-artifacts/$ORG"
ORG_CLI="cli.$ORG.divvy.com"
ORG_PEER="peer.$ORG.divvy.com"

if [ "$MODE" == "create" ]; then
    if [ "$PEER_PORT" == "" ]; then
        echo "No peer port specified."
        echo
        printHelp
        exit 1
    fi

    if [ "$CA_PORT" == "" ]; then
        echo "No CA port specified."
        echo
        printHelp
        exit 1
    fi

    if [ "$CC_PORT" == "" ]; then
        echo "No chaincode port specified."
        echo
        printHelp
        exit 1
    fi

    if [ -d $CONFIG_DIR ]; then
        echo "There is already an organisation called ${ORG}."
        exit 1
    fi

    # Don't clobber the client app namespace.
    if [ "$ORG" == "app" ]; then
        echo "There is already an organisation called ${ORG}."
        exit 1
    fi

    CHANNEL='sys-channel'

    mkdir -p $CONFIG_DIR

    echo "Generating crypto config for ${ORG}..."
    generateCryptoConfig $ORG > "$CONFIG_DIR/crypto-config.yaml"
    echo

    echo "Generating certificates for trust domain:"
    generateCryptoMaterial "$CONFIG_DIR/crypto-config.yaml"
    echo

    echo "Generating network config..."
    generateNetworkConfig $ORG $MSP_NAME $PEER_PORT > "$CONFIG_DIR/configtx.yaml"
    echo

    generateOrgDefinition $CONFIG_DIR $MSP_NAME

    echo "Generating connection profile..."
    generateConnectionProfile $ORG $MSP_NAME $PEER_PORT $CA_PORT > "$CONFIG_DIR/connection-profile.json"
    echo

    echo "Generating docker compose file..."
    generateDockerCompose $ORG $MSP_NAME $PEER_PORT $CA_PORT $CC_PORT > "$CONFIG_DIR/docker-compose.yaml"
    echo

    echo "Starting Organisation containers..."
    echo
    sudo docker-compose -f "$CONFIG_DIR/docker-compose.yaml" up -d 2>&1

    sleep 10

    echo
    sudo docker ps -a --filter name=".$ORG.divvy.com"
    echo

    echo "Generating wallet..."
    sudo docker exec $API_CONTAINER node ./lib/security.js enrolladmin ${ORG}
    echo

    if [ $? -ne 0 ]; then
        exit 1
    fi

    echo "Adding $ORG to the default consortium..."
    addOrgToConsortium $ORG $MSP_NAME
    echo

    createOrgChannel $CONFIG_DIR $ORG
    echo

    cliInstallChaincode $ORG_CLI share 1.0

    cliInstantiateChaincode $ORG_CLI share 1.0 "$ORG-channel" '{"Args":[]}' "AND('${MSP_NAME}.member')" "/opt/gopath/src/github.com/hyperledger/fabric/orderer/msp/tlscacerts/tlsca.divvy.com-cert.pem"

    cliInvokeChaincode $ORG_CLI share "$ORG-channel" "{\"Args\":[\"com.divvy.share:instantiate\",\"$ORG\"]}" "/opt/gopath/src/github.com/hyperledger/fabric/orderer/msp/tlscacerts/tlsca.divvy.com-cert.pem"

    echo "Done"
elif [ "$MODE" == "remove" ]; then
    # TODO: Remove from consortium
    # TODO: Remove org from all channels
    # TODO: Remove all other orgs from org channel

    echo "Stopping $ORG containers..."
    sudo docker-compose -f "$CONFIG_DIR/docker-compose.yaml" down --volumes
    echo

    echo "Removing files..."
    for dir in "$CRYPTO_DIR" "$CONFIG_DIR" "$VOLUME_DIR" "../api/wallet/${ORG}"; do
        echo "Removing $dir"
        rm -rf $dir
    done
    echo

    echo "Done"
elif [ "$MODE" == "joinchannel" ]; then
    if [ "$CHANNEL_OWNER" == "" ]; then
        echo "No channel owner specified."
        echo
        printHelp
        exit 1
    fi

    if [ ! -d "$CONFIG_DIR" ]; then
        echo "Invalid org name. Did you spell the org name correctly?"
        exit 1
    fi

    configBlock="$CLI_OUTPUT_DIR/config-$CHANNEL.pb"
    configBlockUpdated="$CLI_OUTPUT_DIR/config-$CHANNEL-updated.pb"
    configJson="$CLI_OUTPUT_DIR/config-$CHANNEL.json"
    configJsonUpdated="$CLI_OUTPUT_DIR/config-$CHANNEL-updated.json"
    payloadBlock="$CLI_OUTPUT_DIR/config-$CHANNEL-payload.pb"
    payloadJson="$CLI_OUTPUT_DIR/config-$CHANNEL-payload.json"
    orgDefinition="$CLI_OUTPUT_DIR/$ORG.json"
    channelGenesisBlock="$CLI_OUTPUT_DIR/$CHANNEL-genesis.block"
    caPath="/opt/gopath/src/github.com/hyperledger/fabric/orderer/msp/tlscacerts/tlsca.divvy.com-cert.pem"

    cliMkdirp $CHANNEL_OWNER_CLI $CLI_OUTPUT_DIR

    generateOrgDefinition $CONFIG_DIR $MSP_NAME
    sudo docker cp "$CONFIG_DIR/$ORG.json" $CHANNEL_OWNER_CLI:"/opt/gopath/src/github.com/hyperledger/fabric/peer/$orgDefinition"

    cliFetchLatestChannelConfigBlock $CHANNEL_OWNER_CLI $CHANNEL $configBlock $caPath

    cliDecodeConfigBlock $CHANNEL_OWNER_CLI $configBlock $configJson

    # Add Org to config.
    sudo docker exec -i $CHANNEL_OWNER_CLI bash <<EOF
        jq -s '.[0] * {"channel_group":{"groups":{"Application":{"groups": {"$MSP_NAME":.[1]}}}}}' $configJson $orgDefinition > $configJsonUpdated
EOF

    if [ $? -ne 0 ]; then
        exit 1
    fi

    # TODO: Update the chaincode endorsement policy so the new org can execute chaincode.

    # Convert the origional (extracted) config to a block, so we can diff it against the updates.
    cliEncodeConfigJson $CHANNEL_OWNER_CLI $configJson $configBlock

    # Convert the updated config to a block, so we can diff it against the origional.
    cliEncodeConfigJson $CHANNEL_OWNER_CLI $configJsonUpdated $configBlockUpdated

    # Diff the changes to create an "update" block.
    cliGenerateUpdateBlock $CHANNEL_OWNER_CLI $CHANNEL $configBlock $configBlockUpdated $payloadBlock

    # Convert the update block to JSON so we can add a header.
    cliDecodeConfigBlock $CHANNEL_OWNER_CLI $payloadBlock $payloadJson common.ConfigUpdate '.'

    # Add the header.
    cliAddConfigUpdateHeader $CHANNEL_OWNER_CLI $CHANNEL $payloadJson $payloadJson

    # Convert the payload to a block.
    cliEncodeConfigJson $CHANNEL_OWNER_CLI $payloadJson $payloadBlock common.Envelope

    # Submit the block.
    cliSubmitChannelUpdate $CHANNEL_OWNER_CLI $payloadBlock $CHANNEL $caPath

    # Clean up.
    cliRmrf $CHANNEL_OWNER_CLI $CLI_OUTPUT_DIR

    cliMkdirp $ORG_CLI $CLI_OUTPUT_DIR

    # Fetch the genesis block to start syncing the new org peer's ledger
    cliFetchChannelGenesisBlock $ORG_CLI $CHANNEL $channelGenesisBlock $caPath

    # Join peer to channel
    cliJoinPeerToChannel $ORG_CLI $CHANNEL $channelGenesisBlock $caPath $caPath

    listPeerChannels $ORG_CLI

    echo "Done"
elif [ "$MODE" == "showchannels" ]; then
    listPeerChannels $ORG_CLI
elif [ "$MODE" == "nodestatus" ]; then
    cliPeerNodeStatus $ORG_CLI
elif [ "$MODE" == "channelinfo" ]; then
    cliChannelInfo $ORG_CLI "$ORG-channel"
fi
