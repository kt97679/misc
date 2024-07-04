#!/bin/bash
sudo -E apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo -E curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo -E apt-get update
sudo -E apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo groupadd docker
sudo usermod -aG docker $SUDO_USER
mkdir -p ~/.docker
cat <<CONFIG_JSON >~/.docker/config.json
{
  "proxies": {
    "default": {
      "httpProxy": "http://10.0.2.2:3128/",
      "httpsProxy": "http://10.0.2.2:3128/"
    }
  }
}
CONFIG_JSON
sudo mkdir -p /etc/systemd/system/docker.service.d/
sudo cat <<PROXY_CONF >/etc/systemd/system/docker.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://10.0.2.2:3128/"
Environment="HTTPS_PROXY=http://10.0.2.2:3128/"
Environment="NO_PROXY=localhost,127.0.0.1"
PROXY_CONF
sudo systemctl daemon-reload
sudo systemctl restart docker
docker run hello-world
