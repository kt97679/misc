#!/bin/bash

# more information here: https://github.com/diafygi/acme-tiny

set -uex

((UID != 0)) && exec sudo $0 "$@"

exec &> >(tee /tmp/$(basename $0).log)

acme_dir="/var/www/challenges/"
seconds_per_day=$((60 * 60 * 24))
base_dir="/etc/acme-tiny"
account_key="${base_dir}/account.key"
check_expiration=true

now_seconds=$(date +%s)
certificate_updated=false

renew_domain() {
    local domain=$1
    local domain_dir="${base_dir}/${domain}"
    local new_domain_dir="${domain_dir}.${now_seconds}"
    local fullchain_pem="${domain_dir}/fullchain.pem"
    local new_fullchain_pem="${new_domain_dir}/fullchain.pem"
    local new_privkey_pem="${new_domain_dir}/privkey.pem"
    local new_domain_csr="${new_domain_dir}/domain.csr"
    local not_after_seconds=0
    [ -f "$fullchain_pem" ] && not_after_seconds=$(date -d \
            "$(openssl x509 -in "$fullchain_pem" -noout -dates | grep -oP "^notAfter=\K.*")" \
        +%s)
    $check_expiration && ((not_after_seconds - now_seconds > 7 * seconds_per_day)) && return
    mkdir -p $new_domain_dir && chmod 0700 $new_domain_dir
    # Generate a domain private key
    openssl genrsa 4096 > "$new_privkey_pem"
    # Create a certificate signing request (CSR) for your domain
    openssl req -new -sha256 -key "$new_privkey_pem" -subj "/CN=${domain}" > "$new_domain_csr"
    mkdir -p "$acme_dir"
    acme-tiny --account-key "$account_key" --csr "$new_domain_csr" --acme-dir "$acme_dir" > "$new_fullchain_pem"
    ln -nsf $new_domain_dir $domain_dir
    ls -dt ${domain_dir}.* | tail -n +2 | xargs rm -rf
    certificate_updated=true
}

usage() {
    echo "Usage: $0 [-f] [-d domain_name]"
    exit 1
}

mkdir -p $base_dir
[ -f "$account_key" ] || openssl genrsa 4096 > "$account_key"

new_domains=()
while (( $# )); do
    case ${1:-} in
        -f) check_expiration=false ;;
        -d) new_domains+=($2) && shift ;;
	*) echo "Error: unknown option \"$1\"" && usage ;;
    esac
    shift
done

cd $base_dir

for domain in *; do
    [ -L $domain ] || continue
    renew_domain $domain
done

for domain in ${new_domains[*]}; do
    renew_domain $domain
done

$certificate_updated && /etc/init.d/nginx reload
