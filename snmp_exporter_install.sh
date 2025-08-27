#!/bin/bash
# Instalação do Prometheus SNMP Exporter v0.29.0 em Debian 12 (Bookworm)
# - Baixa e instala snmp_exporter em /opt/snmp_exporter e symlink em /usr/local/bin
# - Cria serviço systemd
# - Baixa snmp.yml indicado
# - Habilita repositórios Debian (contrib/non-free/non-free-firmware)
# - Instala snmp e snmp-mibs-downloader e habilita MIBs
# - Idempotente

set -euo pipefail

SNMP_EXPORTER_VER="0.29.0"
SNMP_EXPORTER_TGZ="snmp_exporter-${SNMP_EXPORTER_VER}.linux-amd64.tar.gz"
SNMP_EXPORTER_URL="https://github.com/prometheus/snmp_exporter/releases/download/v${SNMP_EXPORTER_VER}/${SNMP_EXPORTER_TGZ}"

INSTALL_DIR="/opt/snmp_exporter"
BIN_SYMLINK="/usr/local/bin/snmp_exporter"
ETC_PROM="/etc/prometheus"
SNMP_YML="${ETC_PROM}/snmp.yml"
SNMP_YML_URL="https://raw.githubusercontent.com/evertonpasqual/prometheus/24098401f7778ecaea1a86767d30c96a84f4e761/snmp.yml"
SERVICE_FILE="/etc/systemd/system/snmp_exporter.service"

PROM_USER="prometheus"
PROM_GROUP="prometheus"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Comando obrigatório não encontrado: $1"; exit 1; }
}

echo ">>> Instalando dependências básicas..."
apt update -y
apt install -y wget curl tar coreutils

require_cmd wget
require_cmd tar

echo ">>> Criando usuário/grupo prometheus (se necessário)..."
if ! id -u "${PROM_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /bin/false "${PROM_USER}"
fi

echo ">>> Criando diretórios..."
mkdir -p "${ETC_PROM}"

echo ">>> Baixando snmp_exporter v${SNMP_EXPORTER_VER}..."
cd /tmp
if [ ! -s "${SNMP_EXPORTER_TGZ}" ]; then
  wget -q -O "${SNMP_EXPORTER_TGZ}" "${SNMP_EXPORTER_URL}"
fi

echo ">>> Extraindo e movendo para ${INSTALL_DIR}..."
TMP_UNPACK_DIR="/tmp/snmp_exporter_unpack"
rm -rf "${TMP_UNPACK_DIR}"
mkdir -p "${TMP_UNPACK_DIR}"
tar -xzf "${SNMP_EXPORTER_TGZ}" -C "${TMP_UNPACK_DIR}"

# Detecta o diretório extraído
ROOT_DIR="$(find "${TMP_UNPACK_DIR}" -maxdepth 1 -type d -name "snmp_exporter-*.linux-amd64" | head -n1)"
if [ -z "${ROOT_DIR}" ] || [ ! -x "${ROOT_DIR}/snmp_exporter" ]; then
  echo "Falha ao localizar binário snmp_exporter na extração."
  exit 1
fi

# Instala em /opt/snmp_exporter (substitui atômico)
rm -rf "${INSTALL_DIR}"
mv "${ROOT_DIR}" "${INSTALL_DIR}"
chown -R "${PROM_USER}:${PROM_GROUP}" "${INSTALL_DIR}"

echo ">>> Criando symlink do binário em ${BIN_SYMLINK}..."
ln -sf "${INSTALL_DIR}/snmp_exporter" "${BIN_SYMLINK}"
chown -h "${PROM_USER}:${PROM_GROUP}" "${BIN_SYMLINK}"

echo ">>> Baixando snmp.yml para ${SNMP_YML}..."
wget -q -O "${SNMP_YML}" "${SNMP_YML_URL}"
chown "${PROM_USER}:${PROM_GROUP}" "${SNMP_YML}"
chmod 0644 "${SNMP_YML}"

echo ">>> Criando serviço systemd em ${SERVICE_FILE}..."
cat > "${SERVICE_FILE}" <<'UNIT'
[Unit]
Description=Prometheus SNMP Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/snmp_exporter \
  --config.file=/etc/prometheus/snmp.yml
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

echo ">>> Habilitando componentes APT (contrib, non-free, non-free-firmware) para Bookworm..."
# Garante que as três linhas padrão existam com componentes completos
# Nota: ajusta se já houver; mantém idempotência
SOURCES_FILE="/etc/apt/sources.list"
for LINE in \
"deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" \
"deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware" \
"deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware"
do
  grep -qF "$LINE" "$SOURCES_FILE" || echo "$LINE" >> "$SOURCES_FILE"
done

echo ">>> apt update e instalação de snmp e snmp-mibs-downloader..."
apt update -y
apt install -y snmp snmp-mibs-downloader

echo ">>> Habilitando MIBs no cliente SNMP (comentando 'mibs :')..."
SNMP_CONF="/etc/snmp/snmp.conf"
if [ -f "${SNMP_CONF}" ]; then
  sed -i 's/^\s*mibs\s*:.*/# mibs :/' "${SNMP_CONF}" || true
fi

echo ">>> Recarregando e iniciando serviço snmp_exporter..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now snmp_exporter
systemctl restart snmp_exporter

echo "=========================================================="
echo "✅ snmp_exporter ${SNMP_EXPORTER_VER} instalado e em execução!"
echo "Binário: ${BIN_SYMLINK}"
echo "Instalação: ${INSTALL_DIR}"
echo "Config: ${SNMP_YML}"
echo "Serviço: systemctl status snmp_exporter"
echo "=========================================================="
