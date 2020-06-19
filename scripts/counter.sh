#!/bin/bash

echo "Vault address: ${VAULT_ADDR}"
# Set namespace to root if nothing
VAULT_NAMESPACE=${VAULT_NAMESPACE:-"root/"}

function vault_curl() {
  curl -sk \
  ${CURL_VERBOSE:+"-v"} \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --header "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  --cert   "$VAULT_CLIENT_CERT" \
  --key    "$VAULT_CLIENT_KEY" \
  --cacert "$VAULT_CACERT" \
  "$@"
}

function print_things() {
  VAULT_NAMESPACE=$1

  NAMES=$(vault_curl \
    --request LIST \
    $VAULT_ADDR/v1/identity/entity/name | \
    jq -r '.["data"]["keys"]')

  [[ $NAMES != 'null' ]] && echo "Entity names: $NAMES"
  for name in $NAMES
  do
      [[ $name != 'null' ]] && [[ $name != ']' ]] && [[ $name != '[' ]] \
          && n=$(echo $name | sed -e s/'"'/''/g -e s/','/''/ ) \
          && echo "Printing entity with name: $n" \
          && vault_curl $VAULT_ADDR/v1/identity/entity/name/$n | jq .
  done

  AUTH_METHODS=$(vault_curl $VAULT_ADDR/v1/sys/auth | jq '.["data"] | keys[]' | tr -d '\n' | sed s/'\/"'/'\/",'/g)
  echo "Auth Methods: [$AUTH_METHODS]"
  
  # Roles
  TOTAL_ROLES=0
  for mount in $(vault_curl \
   $VAULT_ADDR/v1/sys/auth | \
   jq -r '.? | .["data"] | keys[]');
  do

   users=$(vault_curl \
     --request LIST \
     $VAULT_ADDR/v1/auth/${mount}users | \
               jq -r '.["data"]["keys"]')

    [[ ! -z $users ]] && [[ $users != 'null' ]]  && echo "Users for mount $mount: $users"
   
   roles=$(vault_curl \
     --request LIST \
     $VAULT_ADDR/v1/auth/${mount}roles | \
     jq -r '.["data"]["keys"]')

    [[ ! -z $roles ]] && [[ $roles != 'null' ]]  && echo "Roles for mount $mount: $roles"
   
  done

  # Tokens
  TOTAL_TOKENS_RAW=$(vault_curl \
   --request LIST \
   $VAULT_ADDR/v1/auth/token/accessors
  )

    for accessor in $(echo $TOTAL_TOKENS_RAW | jq -r '.? | .["data"]["keys"] | join("\n")');
    do
        if [[ $PRINT_TOKEN_META = 1 ]]; then
           token=$(vault_curl --request POST -d "{ \"accessor\": \"${accessor}\" }" \
             $VAULT_ADDR/v1/auth/token/lookup-accessor | jq '.data' ) && echo "Token accessor $accessor: $token"
        else
            echo "Token accessor $accessor: skip printing metadata (set PRINT_TOKEN_META=1)"
        fi
    done      

}

function count_things() {
  VAULT_NAMESPACE=$1

  TOTAL_ENTITIES=$(vault_curl \
    --request LIST \
    $VAULT_ADDR/v1/identity/entity/id | \
    jq -r '.? | .["data"]["keys"] | length')

  # Roles
  TOTAL_ROLES=0
  for mount in $(vault_curl \
   $VAULT_ADDR/v1/sys/auth | \
   jq -r '.? | .["data"] | keys[]');
  do
   users=$(vault_curl \
     --request LIST \
     $VAULT_ADDR/v1/auth/${mount}users | \
     jq -r '.? | .["data"]["keys"] | length')
   roles=$(vault_curl \
     --request LIST \
     $VAULT_ADDR/v1/auth/${mount}roles | \
     jq -r '.? | .["data"]["keys"] | length')
   TOTAL_ROLES=$((TOTAL_ROLES + users + roles))
  done

  # Tokens
  TOTAL_TOKENS_RAW=$(vault_curl \
   --request LIST \
   $VAULT_ADDR/v1/auth/token/accessors
  )
  TOTAL_TOKENS=$(echo $TOTAL_TOKENS_RAW | jq -r '.? | .["data"]["keys"] | length')
  TOTAL_ORPHAN_TOKENS=0
  for accessor in $(echo $TOTAL_TOKENS_RAW | \
   jq -r '.? | .["data"]["keys"] | join("\n")');
  do
   token=$(vault_curl \
     --request POST \
     -d "{ \"accessor\": \"${accessor}\" }" \
     $VAULT_ADDR/v1/auth/token/lookup-accessor | \
     jq -r '.? | .| [select(.data.path == "auth/token/create")] | length')
   TOTAL_ORPHAN_TOKENS=$((TOTAL_ORPHAN_TOKENS + $token))
  done

  echo "$TOTAL_ENTITIES,$TOTAL_ROLES,$TOTAL_TOKENS,$TOTAL_ORPHAN_TOKENS"
}

function output() {
  # Transform comma-separated list into output
  array=($(echo $1 | sed 's/,/ /g'))
  echo "Total entities: ${array[0]}"
  echo "Total users/roles: ${array[1]}"
  echo "Total tokens: ${array[2]}"
  echo "Total orphan tokens: ${array[3]}"
}

function drill_in() {
  # Run counts where we stand
  VAULT_NAMESPACE=$1

  echo "Namespace: $1"
  counts=$(count_things $1)
  output $counts

  print_things $1
  
  # Pull all namespaces from current position, if any
  NAMESPACE_LIST=$(vault_curl \
    --request LIST \
    $VAULT_ADDR/v1/sys/namespaces | \
    jq -r '.? | .["data"]["keys"] | @tsv')

  if [ ! -z "$NAMESPACE_LIST" ]
  then
    echo "$1 child namespaces: $NAMESPACE_LIST"
    for ns in $NAMESPACE_LIST; do
      drill_in $ns
    done
  fi
}

drill_in $VAULT_NAMESPACE
