#!/command/with-contenv bashio
set -e

# wait for webui.py to avoid interleaved log output
sleep 2

# read options
# you can pass in these variables if running without supervisor
if [ -n "${HASSIO_TOKEN:-}" ]; then
  CLIENT_ID="$(bashio::config 'client_id')"; export CLIENT_ID
  CLIENT_SECRET="$(bashio::config 'client_secret')"; export CLIENT_SECRET
  DOMAIN="$(bashio::config 'domain')"; export DOMAIN
  REGION="$(bashio::config 'region')"; export REGION
  DEBUG="$(bashio::config 'debug')"; export DEBUG
fi

export GNUPGHOME=/data/gnugpg
export PASSWORD_STORE_DIR=/data/password-store

generate_keypair() {
  # generate self signed SSL certificate
  bashio::log.info "Generating self-signed SSL certificates"
  openssl req -x509 -nodes -newkey ec \
      -pkeyopt ec_paramgen_curve:secp521r1 \
      -pkeyopt ec_param_enc:named_curve  \
      -subj "/CN=${HOSTNAME}" \
      -keyout /data/key.pem -out /data/cert.pem -sha256 -days 3650 \
      -addext "extendedKeyUsage = serverAuth" \
      -addext "keyUsage = digitalSignature, keyCertSign, keyAgreement"
  mkdir -p /share/tesla
  cp /data/cert.pem /share/AppData/tesla/selfsigned.pem

  # Generate keypair
  bashio::log.info "Generating keypair"
  /usr/bin/tesla-keygen -f -keyring-type pass -key-name myself create > /share/AppData/tesla/com.tesla.3p.public-key.pem
  cat /share/AppData/tesla/com.tesla.3p.public-key.pem
}

# run on first launch only
if ! pass > /dev/null 2>&1; then
  bashio::log.info "Setting up GnuPG and password-store"
  # shellcheck disable=SC2174
  mkdir -m 700 -p /data/gnugpg
  gpg --batch --passphrase '' --quick-gen-key myself default default
  gpg --list-keys
  pass init myself
  generate_keypair

# verify certificate is not from previous install
elif [ -f /share/AppData/tesla/com.tesla.3p.public-key.pem ] && [ -f /share/AppData/tesla/selfsigned.pem ]; then
  certPubKey="$(openssl x509 -noout -pubkey -in /share/AppData/tesla/selfsigned.pem)"
  keyPubKey="$(openssl pkey -pubout -in /data/key.pem)"
  if [ "${certPubKey}" == "${keyPubKey}" ]; then
    bashio::log.info "Found existing keypair"
  else
    bashio::log.warning "Existing certificate is invalid"
    generate_keypair
  fi
else
  generate_keypair
fi

# verify public key is accessible with valid TLS cert
bashio::log.info "Testing public key..."
if ! curl -sfD - "https://$DOMAIN/.well-known/appspecific/com.tesla.3p.public-key.pem"; then
  bashio::log.fatal "Fix public key before proceeding."
  exit 1
fi

if [ -z "$CLIENT_ID" ]; then
  bashio::log.notice "Request application access with Tesla, then fill in credentials and restart addon."
else
  if bashio::config.true regenerate_auth; then
    bashio::log.info "Running auth.py"
    python3 /app/auth.py
  fi
fi
