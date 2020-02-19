# This is a collection of bash functions used by different scripts

function askProceed() {
    read -p "Continue? [Y/n] " ans
    case "$ans" in
    y | Y | "")
        echo "proceeding ..."
        ;;
    n | N)
        echo "exiting..."
        exit 1
        ;;
    *)
        echo "invalid response"
        askProceed
        ;;
    esac
    echo
}

# Remove all non-alphanumeric characters from a string and transform to lowercase.
function generateSlug() {
    echo $1 | tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]'
}

function generateCryptoMaterial() {
    cryptogen generate --config=$1

    if [ $? -ne 0 ]; then
        echo "Failed to generate certificates..."
        exit 1
    fi
}

function orgDockerComposeFiles() {
    find ./org-config/ -name 'docker-compose.yaml'
}
