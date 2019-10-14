#!/bin/bash

set -uex

((UID != 0)) && exec sudo $0 "$@"

exec &> >(tee /tmp/$(basename $0).log)

seconds_per_day=$((60 * 60 * 24))
base_dir="/etc/acme-tiny"
account_key="/etc/acme-tiny/account.key"

while (( $# )); do
    case "$1" in
        --account-key) account_key="$2"; shift ;;
        --account_key=*) account_key="${1#*=}" ;;
        *) argv+=("$1") ;;
    esac
    shift
done

now_seconds=$(date +%s)

renew_domain() {
    local domain=$1
    local domain_dir="${base_dir}/${domain}"
    local new_domain_dir="${domain_dir}.${now_seconds}"
    local fullchain_pem="${domain_dir}/fullchain.pem"
    local new_fullchain_pem="${new_domain_dir}/fullchain.pem"
    local new_privkey_pem="${new_domain_dir}/privkey.pem"
    local new_domain_csr="${new_domain_dir}/domain.csr"

    local not_after_seconds=$(date -d \
            "$(openssl x509 -in "$fullchain_pem" -noout -dates | grep -oP "^notAfter=\K.*")" \
        +%s)

    ((not_after_seconds - now_seconds > 7 * seconds_per_day)) && return

    mkdir -p $new_domain_dir && chmod 0700 $new_domain_dir

    # Generate a domain private key
    openssl genrsa 4096 > "$new_privkey_pem"

    # Create a certificate signing request (CSR) for your domain
    openssl req -new -sha256 -key "$new_privkey_pem" -subj "/CN=${domain}" > "$new_domain_csr"

    acme-tiny --account-key "$account_key" --csr "$new_domain_csr" --acme-dir /var/www/challenges/ > "$new_fullchain_pem"

    ln -nsf $new_domain_dir $domain_dir

    /etc/init.d/nginx nginx reload

    ls -dt ${domain_dir}.* | tail -n +2 | xargs rm -rf
}

for domain in "${argv[@]}"; do
    renew_domain $domain
done
