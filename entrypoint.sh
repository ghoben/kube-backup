#!/bin/bash -e
# (c)  pieterlange 2019
# (c)  changes on GPG Agent Gernot Hoebenreich 2020

# Trap errors
traperr() {
  echo "ERROR: ${BASH_SOURCE[1]} at about ${BASH_LINENO[0]}"
}

set -o errtrace
trap traperr ERR

#
# Initializes the gpg agent with passphrase and private key
#
function initializeGPGAgent()
{
    local GPG_KEY=$1
    local GPG_PASSPHRASE=$2

    echo "[info] initializeGPGAgent"
    echo "[info]  GPG_KEY=$GPG_KEY"

    mkdir -p  ~/.gnupg && \
    chmod 700 ~/.gnupg && \
    cp /gpg.conf ~/.gnupg/gpg.conf &&\
    echo "[info] GPG configuration created." 

    echo "[info] gpg-agent setup ..."&& \
    # configure gpg to use the gpg-agent
    sed -i 's/# use-agent/use-agent/' ~/.gnupg/gpg.conf                     && \
    # configure gpg to operate in non-tty mode
    echo "no-tty" >> ~/.gnupg/gpg.conf                                      && \
    # start gpg-agent as a daemon and allow preset-passphrase
    #   some clients will need to know how to connect to the agent.
    # |- GPG_AGENT_INFO=/backup/.gnupgp/S.gpg-agent; export GPG_AGENT_INFO;
    # |- eval output from gpg-agent start
    eval "$(gpg-agent --daemon --allow-preset-passphrase)" && \
    echo "[info] gpg-agent setup done."

# import the key into the gpg keyring
    echo "[info] Importing key ..."                                         && \
    gpg --allow-secret-key-import --passphrase "${GPG_PASSPHRASE}"             \
        --batch --import "${GPG_KEY}"                                       && \
# convert gpg passphrase to hex
    local GPG_PASSPHRASE_HEX                                                && \
    GPG_PASSPHRASE_HEX=$(echo -n "$GPG_PASSPHRASE"                             \
                          | od -A n -t x1                                      \
                          | sed 's/ *//g')                                  && \
# extract gpg key's keygrip 
    local GPG_KEYGRIP                                                       && \
    GPG_KEYGRIP=$(gpg --with-keygrip -K                                        \
                      | grep "Keygrip"                                         \
                      | tail -1                                                \
                      | sed 's/Keygrip = //'                                   \
                      | sed 's/ *//g')                                      && \
    echo "[info]  GPG_KEYGRIP=$GPG_KEYGRIP"                                 && \
    echo "[info] Importing key done."

# store gpg key's passphrase in agent
    echo "[info] gpg-agent preset passphrase ..." && \
    gpg-connect-agent                                                          \
        "PRESET_PASSPHRASE $GPG_KEYGRIP -1 $GPG_PASSPHRASE_HEX"            \
        /bye  && \
    echo "[info] gpg-agent preset passphrase done."
}


if [ -z "$NAMESPACES" ]; then
    NAMESPACES=$(kubectl get ns -o jsonpath="{.items[*].metadata.name}")
fi

RESOURCETYPES="${RESOURCETYPES:-"ingress deployment configmap svc rc ds networkpolicy statefulset cronjob pvc"}"
GLOBALRESOURCES="${GLOBALRESOURCES:-"namespace storageclass clusterrole clusterrolebinding customresourcedefinition"}"

# Initialize git repo
[ -z "$DRY_RUN" ] && [ -z "$GIT_REPO" ] && echo "Need to define GIT_REPO environment variable" && exit 1
GIT_REPO_PATH="${GIT_REPO_PATH:-"/backup/git"}"
GIT_PREFIX_PATH="${GIT_PREFIX_PATH:-"."}"
GIT_USERNAME="${GIT_USERNAME:-"kube-backup"}"
GIT_EMAIL="${GIT_EMAIL:-"kube-backup@example.com"}"
GIT_BRANCH="${GIT_BRANCH:-"master"}"
GITCRYPT_ENABLE="${GITCRYPT_ENABLE:-"false"}"
GITCRYPT_PRIVATE_KEY="${GITCRYPT_PRIVATE_KEY:-"/secrets/gpg-private.key"}"
GITCRYPT_SYMMETRIC_KEY="${GITCRYPT_SYMMETRIC_KEY:-"/secrets/symmetric.key"}"
GITCRYPT_PASSPHRASE="${GITCRYPT_PASSPHRASE:-""}"

if [[ ! -f /backup/.ssh/id_rsa ]]; then
    git config --global credential.helper '!aws codecommit credential-helper $@'
    git config --global credential.UseHttpPath true
fi
[ -z "$DRY_RUN" ] && git config --global user.name "$GIT_USERNAME"
[ -z "$DRY_RUN" ] && git config --global user.email "$GIT_EMAIL"

[ -z "$DRY_RUN" ] && (test ! -e "$GIT_REPO_PATH" || rm -rf "${GIT_REPO_PATH}")
[ -z "$DRY_RUN" ] && (git clone --depth 1 "$GIT_REPO" "$GIT_REPO_PATH" --branch "$GIT_BRANCH" || git clone "$GIT_REPO" "$GIT_REPO_PATH")

cd "$GIT_REPO_PATH"
[ -z "$DRY_RUN" ] && (git checkout "${GIT_BRANCH}" || git checkout -b "${GIT_BRANCH}")

mkdir -p "$GIT_REPO_PATH/$GIT_PREFIX_PATH"
cd "$GIT_REPO_PATH/$GIT_PREFIX_PATH"

if [ "$GITCRYPT_ENABLE" = "true" ]; then
    if [ -f "$GITCRYPT_PRIVATE_KEY" ]; then
        echo "[info] Importing private key ${GITCRYPT_PRIVATE_KEY}"
        initializeGPGAgent "$GITCRYPT_PRIVATE_KEY" "${GITCRYPT_PASSPHRASE}"
        echo "[info] GIT Crypt unlocking ..."
        git-crypt unlock
        echo "[info] GIT Crypt unlocking done."

        RESOURCETYPES="${RESOURCETYPES} secret"

    elif [ -f "$GITCRYPT_SYMMETRIC_KEY" ]; then
        git-crypt unlock "$GITCRYPT_SYMMETRIC_KEY"
    else
        echo "[ERROR] Please verify your env variables (GITCRYPT_PRIVATE_KEY or GITCRYPT_SYMMETRIC_KEY)"
        exit 1
    fi
fi

[ -z "$DRY_RUN" ] && git rm -r '*.yaml' --ignore-unmatch -f

# Start kubernetes state export
for resource in $GLOBALRESOURCES; do
    [ -d "$GIT_REPO_PATH/$GIT_PREFIX_PATH" ] || mkdir -p "$GIT_REPO_PATH/$GIT_PREFIX_PATH"
    echo "[info] Exporting resource: ${resource}" >/dev/stderr
    kubectl get -o=json "$resource" | jq --sort-keys \
        'del(
          .items[].metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
          .items[].metadata.annotations."control-plane.alpha.kubernetes.io/leader",
          .items[].metadata.uid,
          .items[].metadata.selfLink,
          .items[].metadata.resourceVersion,
          .items[].metadata.creationTimestamp,
          .items[].metadata.generation,
          .items[].data.timestamp
      )' | python -c 'import sys, yaml, json; yaml.safe_dump(json.load(sys.stdin), sys.stdout, default_flow_style=False)' >"$GIT_REPO_PATH/$GIT_PREFIX_PATH/${resource}.yaml"
done

for namespace in $NAMESPACES; do
    [ -d "$GIT_REPO_PATH/$GIT_PREFIX_PATH/${namespace}" ] || mkdir -p "$GIT_REPO_PATH/$GIT_PREFIX_PATH/${namespace}"

    for type in $RESOURCETYPES; do
        echo "[info] [${namespace}] Exporting resources: ${type}" >/dev/stderr

        label_selector=""
        if [[ "$type" == 'configmap' && -z "${INCLUDE_TILLER_CONFIGMAPS:-}" ]]; then
            label_selector="-l OWNER!=TILLER"
        fi

        # shellcheck disable=SC2034
        # shellcheck disable=SC2086 
        #  Note: the label selector is intented to be glopped
        
        kubectl --namespace="${namespace}" get "$type" $label_selector \
                -o custom-columns=SPACE:.metadata.namespace,KIND:..kind,NAME:.metadata.name \
                --no-headers | while read -r a b name; do
            [ -z "$name" ] && continue

        # Service account tokens cannot be exported
        if [[ "$type" == 'secret' && $(kubectl get -n "${namespace}" -o jsonpath="{.type}" secret "$name") == "kubernetes.io/service-account-token" ]]; then
            echo "[info] [${namespace}] Exporting resources: ${type}, ${name} skipped." >/dev/stderr
            continue
        fi
        echo "[info] [${namespace}] Exporting resources: ${type}, ${name}" >/dev/stderr

        kubectl --namespace="${namespace}" get -o=json "$type" "$name" | jq --sort-keys \
        'del(
            .metadata.annotations."control-plane.alpha.kubernetes.io/leader",
            .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
            .metadata.creationTimestamp,
            .metadata.generation,
            .metadata.resourceVersion,
            .metadata.selfLink,
            .metadata.uid,
            .data.timestamp,
            .spec.clusterIP,
            .status
        )' | python -c 'import sys, yaml, json; yaml.safe_dump(json.load(sys.stdin), sys.stdout, default_flow_style=False)' >"$GIT_REPO_PATH/$GIT_PREFIX_PATH/${namespace}/${name}.${type}.yaml"
        done
    done
done

[ -z "$DRY_RUN" ] || exit

cd "${GIT_REPO_PATH}"
git add .

if ! git diff-index --quiet HEAD --; then
    git commit -m "Automatic backup at $(date)"
    git push origin "${GIT_BRANCH}"
    echo "[info] Changes committed"
else
    echo "[info] No change"
fi
