#!/usr/bin/env bash
# Creates a throwaway CA and a server certificate for graph.microsoft.com and login.microsoftonline.com,
# used only by the fake Graph server on the CI runner.
set -euo pipefail
out="${1:?output directory}"
mkdir -p "$out"
cd "$out"

cat > ca.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = HelloID connector dry run test CA
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat > server.ext <<'EOF'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:graph.microsoft.com, DNS:login.microsoftonline.com
authorityKeyIdentifier = keyid
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3 -keyout ca.key -out ca.crt -config ca.cnf 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=graph.microsoft.com" 2>/dev/null
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3 -out server.crt -extfile server.ext 2>/dev/null
echo "Certificates written to $out"
