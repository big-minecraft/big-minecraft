command_exists() {
    command -v "$1" &> /dev/null
}

if ! command_exists helm; then
    echo "Helm is not installed. Please install it by following the instructions at https://helm.sh/docs/intro/install/"
    exit 1
fi

if ! command_exists helmfile; then
    echo "Helmfile is not installed. Please install it by following the instructions at https://github.com/roboll/helmfile#installation"
    exit 1
fi


helm upgrade big-minecraft ../
helmfile apply --file ../helmfile.yaml  