#!/usr/bin/env bash

# TODO: Use hardware entropy generator TrueRNG
# http://ubld.it/forums/topic/mac-osx-seeding-prng-with-truerng/
# https://calomel.org/entropy_random_number_generators.html

GPG_BIN="gpg"

export LC_ALL= LANGUAGE=en
#export GNUPGHOME="$HOME/.gnupg"

function generate_master_key() {
  NAME_REAL="$1"
  NAME_COMMENT="$2"
  NAME_EMAIL="$3"
  PASSPHRASE="$4"
  KEY_LENGTH=2048
  SUBKEY_LENGTH=2048
  MASTERKEY_USAGE="cert sign"
  SUBKEY_USAGE="encrypt sign auth"
  EXPIRE_DATE=0

  cat >master <<EOF
     #%dry-run
     %echo Generating Master OpenPGP key
     Key-Type: RSA
     Key-Length: $KEY_LENGTH
     Key-Usage: $MASTERKEY_USAGE
     Subkey-Type: RSA
     Subkey-Length: $SUBKEY_LENGTH
     Subkey-Usage: $SUBKEY_USAGE
     Name-Real: $NAME_REAL
     Name-Comment: $NAME_COMMENT
     Name-Email: $NAME_EMAIL
     Expire-Date: $EXPIRE_DATE
     Handle: newcert
     Passphrase: $PASSPHRASE
     %commit
     %echo done
EOF
  KEYNAME=`$GPG_BIN --no-tty --quiet --display-charset utf-8 --batch --status-fd=1 --generate-key master | grep KEY_CREATED | cut -f4 -d' '`
  rm master
}

function get_key_info() {
  OFS=$IFS; IFS=$'\n'
  KEYS=(`$GPG_BIN --quiet --list-secret-keys --with-colons`)
  IFS=$OFS
  #echo "$KEYS"
  SECRET_KEY=()
  SUB_KEY=()
  UID_INFO=()

  for KEY_INFO in ${KEYS[@]} ; do
    OFS=$IFS; IFS=':'
    KEY_INFO=($KEY_INFO)
    IFS=$OFS

    if [[ "${KEY_INFO[0]}" == "sec" ]]; then
      SECRET_KEY=("${KEY_INFO[@]}")
    elif [[ "${KEY_INFO[0]}" == "ssb" ]]; then
      SUB_KEY=("${KEY_INFO[@]}")
    elif [[ "${KEY_INFO[0]}" == "uid" ]]; then
      UID_INFO=("${KEY_INFO[@]}")
    fi
  done
  SECRET_KEY_ID=${SECRET_KEY[4]}
  SUB_KEY_ID=${SUB_KEY[4]}
  echo "$SECRET_KEY_ID $SUB_KEY_ID"
}

function random_numbers() {
  LENGTH="$1"
  if [[ "$LENGTH" == "" ]]; then
    LENGTH=6
  fi
  dd if=/dev/random bs=1 count=$LENGTH 2>/dev/null | hexdump -v -e '/1 "%u"'|cut -c1-${LENGTH}
}

function random_chars() {
  LENGTH="$1"
  if [[ "$LENGTH" == "" ]]; then
    LENGTH=32
  fi
  dd if=/dev/random bs=1 count=$LENGTH 2>/dev/null | hexdump -v -e '/1 "%02X"'
}

function extract_secret_key() {
  ID="$1"
  OUTPUT_FILE="$2"
  PASSWORD="$3"

  make_passwd_file "$PASSWORD"
  $GPG_BIN \
      --passphrase-file "$PASSWD_FILE" \
      --pinentry-mode loopback \
      --batch --quiet --no-greeting \
      --export-secret-keys --armor "$ID" > "$OUTPUT_FILE"
  remove_passwd_file
}

function create_info_yaml() {
  YAML_NAME="$1"
  KEYNAME=`basename "$2"`
  FIRST_NAME=`echo "$3" | cut -f1 -d' '`
  LAST_NAME=`echo "$3" | cut -f2 -d' '`
  LOGIN="$4"
  KEY_PASSWORD="$5"
  USER_PINCODE="$6"
  if [[ $USER_PINCODE == "" ]]; then
    USER_PINCODE=123456
  fi
  ADMIN_PINCODE="$7"
  if [[ $ADMIN_PINCODE == "" ]]; then
    ADMIN_PINCODE=12345678
  fi
  URL="$8"
  LANGUAGE="$9"
  if [[ "$LANGUAGE" == "" ]]; then
    LANGUAGE="en"
  fi

  cat >$YAML_NAME <<EOF
secret: $KEYNAME
firstname: $FIRST_NAME
lastname: $LAST_NAME
login: $LOGIN
language: $LANGUAGE
url: $URL
user_pincode: $USER_PINCODE
admin_pincode: $ADMIN_PINCODE
password: $KEY_PASSWORD
EOF
}

# Pass a second value to change chaching time hwen it restarts
function kill_gpg_agent() {
  # Stupidly the only solution to stop GPG agent caching passwords is to kill it, not to worry it will restart automatically
  # https://unix.stackexchange.com/questions/193588/how-can-i-tell-gpg-that-i-do-not-want-password-caching-for-a-specific-program
  if [[ $1 == "" ]]; then
    pkill gpg-agent
  else
    pkill gpg-agent && gpg-agent --default-cache-ttl $1 --use-standard-socket --daemon
  fi
}

function make_passwd_file() {
  PASSWD_FILE=`mktemp /tmp/gpg.XXXXXXXXXX` || { echo "Unable to make temp file!"; exit 1; }
  echo -e $1>"${PASSWD_FILE}"
  kill_gpg_agent
}

function remove_passwd_file() {
  [ -f "$PASSWD_FILE" ] && rm "$PASSWD_FILE"
}

export GNUPGHOME="$(mktemp -d)"

[[ "$1" != "" ]] && NAME=$1 || { read -p 'Name (First Last): ' NAME; }
[[ "$2" != "" ]] && EMAIL=$2 || { read -p 'Email: ' EMAIL; }
[[ "$3" != "" ]] && COMMENT=$3 || { read -p 'Comment: ' COMMENT; }

# Some user defined fields
OUTDIR="keys"
ADMIN_KEY=`random_numbers 8`
USER_KEY=123456
KEY_PASSWORD=`random_chars 32`

KEYNAME_SCHEME=`echo "$NAME" |  tr '[:upper:]' '[:lower:]' | tr ' ' '_'`
MASTERKEY_NAME="$OUTDIR/${KEYNAME_SCHEME}_master.asc"
SUBKEY_NAME="$OUTDIR/${KEYNAME_SCHEME}_sub.asc"
YAML_NAME="$OUTDIR/${KEYNAME_SCHEME}.yaml"

mkdir -p "$OUTDIR"
echo "# Generating Keys"
generate_master_key "$NAME" "$COMMENT" "$EMAIL" "$KEY_PASSWORD"
KEY_IDS=(`get_key_info`)

# Extract Master Key
echo "# Extracting Master Key"
extract_secret_key "${KEY_IDS[0]}" "$MASTERKEY_NAME" "$KEY_PASSWORD"

# Extract Sub Key
echo "# Extracting Sub Key"
extract_secret_key "${KEY_IDS[1]}" "$SUBKEY_NAME" "$KEY_PASSWORD"

# Generate Symetrically signed test file

echo "# Generating Sub Key Test File"


# Generate the Info YAML
echo "# Generating Info YAML"
create_info_yaml "$YAML_NAME" "$SUBKEY_NAME" "$NAME" "$EMAIL" "$KEY_PASSWORD" "$USER_KEY" "$ADMIN_KEY"

echo "# Deleting Keys from Keyring"
delete_key "${KEY_IDS[0]}"
delete_key "${KEY_IDS[1]}"

echo "# All Done"
