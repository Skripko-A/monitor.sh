#!/usr/bin/env bash

OUTPUT_FILE=""
COMMANDS_TO_RUN=()
PROC_SUBCOMMAND=""
CPU_INTERVAL=1
DISK_DEVICE=""
NETWORK_INTERFACE=""
SIGNAL_NUMBER=15
TARGET_PID=""

# help
show_help() {
    cat << EOF
monitor.sh - Скрипт мониторинга ресурсов сервера

Использование:
  $(basename "$0") [ОПЦИИ] [АРГУМЕНТЫ]

Доступные команды:
  -p, --proc <subcmd>    Работа с /proc (доступные подкоманды: cpuinfo, meminfo, loadavg)
  -c, --cpu              Мониторинг загрузки CPU + топ-10 процессов
  -m, --memory           Мониторинг использования памяти + топ-10 процессов
  -d, --disks [<dev>]    Мониторинг дисков + топ-10 процессов по I/O
  -n, --network [<iface>] Мониторинг сети (опционально: имя интерфейса, например eth0)
  -la, --loadaverage     Вывод средней нагрузки на систему
  -k, --kill <pid>       Отправка сигнала процессу (по умолчанию SIGTERM)
      --kill <sig> <pid> Отправка конкретного сигнала (например, 9 для SIGKILL)
  -o, --output [<file>]  Сохранение результатов в файл (без аргумента - в текущую директорию)
  -h, --help             Вывод этой справки

Примеры:
  $(basename "$0") -c -m -d sda -o report.txt
  $(basename "$0") --proc cpuinfo
  $(basename "$0") -n eth0 --loadaverage
  $(basename "$0") --kill 1234          # SIGTERM процессу 1234
  $(basename "$0") --kill 9 5678        # SIGKILL процессу 5678
EOF
}

# ошибки
error_exit() {
    echo "ОШИБКА: $1" >&2
    exit 1
}

# проверка утилит
check_dependency() {
    if ! command -v "$1" &>/dev/null; then
        error_exit "Требуемая утилита '$1' не установлена. Установите пакет: $2"
    fi
}

# output
output_result() {
    local content="$1"
    local section="$2"
    
    echo "[$section] $(date '+%Y-%m-%d %H:%M:%S')"
    echo "$content"
    echo "--------------------------------------------------"
    
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "[$section] $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT_FILE"
        echo "$content" >> "$OUTPUT_FILE"
        echo "--------------------------------------------------" >> "$OUTPUT_FILE"
    fi
}

# cpu top 10
get_top_cpu() {
    ps -eo pid,user,%cpu,cmd --sort=-%cpu | head -11 | awk 'NR==1 {
        printf "%-8s %-15s %-6s %s\n", "PID", "USER", "%CPU", "COMMAND";
        printf "%-8s %-15s %-6s %s\n", "--------", "---------------", "------", "------------------------------------------------------------";
        next
    } {
        cmd = "";
        for (i = 4; i <= NF; i++) cmd = cmd $i " ";
        printf "%-8s %-15s %-6.1f %.58s\n", $1, $2, $3, cmd
    }'
}

# mem top 10
get_top_memory() {
    ps -eo pid,user,%mem,rss,cmd --sort=-rss | head -11 | awk 'NR==1 {
        printf "%-8s %-15s %-6s %-10s %s\n", "PID", "USER", "%MEM", "RSS(MB)", "COMMAND";
        printf "%-8s %-15s %-6s %-10s %s\n", "--------", "---------------", "------", "----------", "------------------------------------------------------------";
        next
    } {
        rss_mb = int($4 / 1024);
        cmd = "";
        for (i = 5; i <= NF; i++) cmd = cmd $i " ";
        printf "%-8s %-15s %-6.1f %-10d %.58s\n", $1, $2, $3, rss_mb, cmd
    }'
}

# io top 10
get_top_io() {
    local tmpfile=$(mktemp 2>/dev/null || echo "/tmp/io_$$")
    for pid in /proc/[0-9]*; do
        if [[ -f "$pid/io" ]]; then
            local rbytes=$(grep -m1 "^rchar:" "$pid/io" 2>/dev/null | awk '{print $2}')
            local wbytes=$(grep -m1 "^wchar:" "$pid/io" 2>/dev/null | awk '{print $2}')
            # Корректная обработка пустых значений
            rbytes=${rbytes:-0}
            wbytes=${wbytes:-0}
            local total=$((rbytes + wbytes))
            local cmd=$(cat "$pid/comm" 2>/dev/null || echo "unknown")
            local user=$(stat -c '%U' "$pid" 2>/dev/null || echo "unknown")
            echo "$total $pid $user $cmd" >> "$tmpfile" 2>/dev/null
        fi
    done
    
    {
        echo "PID      USER            GB        COMMAND"
        echo "-------- --------------- --------- ------------------------------"
        sort -rn "$tmpfile" 2>/dev/null | head -10 | awk '{
            total_gb = $1 / 1024 / 1024 / 1024;
            pid = $2;
            sub(/.*\//, "", pid);
            printf "%-8s %-15s %-9.2f %.30s\n", pid, $3, total_gb, $4
        }'
    }
    
    rm -f "$tmpfile" 2>/dev/null
}

# Проверка аргументов
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--proc)
            COMMANDS_TO_RUN+=("proc")
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                PROC_SUBCOMMAND="$2"
                shift
            fi
            ;;
        -c|--cpu)
            COMMANDS_TO_RUN+=("cpu")
            ;;
        -m|--memory)
            COMMANDS_TO_RUN+=("memory")
            ;;
        -d|--disks)
            COMMANDS_TO_RUN+=("disks")
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                DISK_DEVICE="$2"
                shift
            fi
            ;;
        -n|--network)
            COMMANDS_TO_RUN+=("network")
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                NETWORK_INTERFACE="$2"
                shift
            fi
            ;;
        -la|--loadaverage)
            COMMANDS_TO_RUN+=("loadaverage")
            ;;
        -k|--kill)
            COMMANDS_TO_RUN+=("kill")
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                if [[ -n "$3" && "$3" =~ ^[0-9]+$ ]]; then
                    SIGNAL_NUMBER="$2"
                    TARGET_PID="$3"
                    shift 2
                else
                    TARGET_PID="$2"
                    shift
                fi
            else
                error_exit "Для --kill требуется указать PID процесса (и опционально номер сигнала)"
            fi
            ;;
        -o|--output)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                OUTPUT_FILE="$2"
                shift
            else
                OUTPUT_FILE="./monitor_$(date '+%Y%m%d_%H%M%S').log"
            fi
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error_exit "Неизвестная опция: '$1'. Используйте --help для справки."
            ;;
    esac
    shift
done

# Проверка зависимостей

if [[ " ${COMMANDS_TO_RUN[*]} " =~ " disks " ]] || [[ " ${COMMANDS_TO_RUN[*]} " =~ " cpu " ]]; then
    check_dependency iostat "sysstat"
fi

if [[ " ${COMMANDS_TO_RUN[*]} " =~ " network " ]]; then
    if ! command -v ifstat &>/dev/null; then
        echo "Предупреждение: утилита ifstat недоступна. Используется альтернативный метод через /proc/net/dev" >&2
    fi
fi

# Создание Output файла если указан
if [[ -n "$OUTPUT_FILE" ]]; then
    if ! touch "$OUTPUT_FILE" 2>/dev/null; then
        error_exit "Невозможно создать файл вывода: $OUTPUT_FILE"
    fi
    echo "Результаты мониторинга будут сохранены в: $OUTPUT_FILE"
    echo "=== Начало мониторинга: $(date) ===" > "$OUTPUT_FILE"
fi

# Выполнение команд

# итерация по списку команд
for cmd in "${COMMANDS_TO_RUN[@]}"; do
    case "$cmd" in
        proc)

            if [[ -z "$PROC_SUBCOMMAND" ]]; then
                output_result "Доступные подкоманды для --proc:
  cpuinfo   - информация о процессоре
  meminfo   - информация о памяти
  loadavg   - средняя нагрузка" "PROC HELP"
                continue
            fi
            
            case "$PROC_SUBCOMMAND" in
                cpuinfo)
                    if [[ -f /proc/cpuinfo ]]; then
                        output_result "$(grep -m 4 'model name\|cpu MHz\|cache size\|cores' /proc/cpuinfo | head -20)" "PROC CPUINFO"
                    else
                        error_exit "Файл /proc/cpuinfo недоступен"
                    fi
                    ;;
                meminfo)
                    if [[ -f /proc/meminfo ]]; then
                        output_result "$(grep -E '^(MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo)" "PROC MEMINFO"
                    else
                        error_exit "Файл /proc/meminfo недоступен"
                    fi
                    ;;
                loadavg)
                    if [[ -f /proc/loadavg ]]; then
                        output_result "$(cat /proc/loadavg)" "PROC LOADAVG"
                    else
                        error_exit "Файл /proc/loadavg недоступен"
                    fi
                    ;;
                *)
                    error_exit "Неизвестная подкоманда для --proc: '$PROC_SUBCOMMAND'. Доступны: cpuinfo, meminfo, loadavg"
                    ;;
            esac
            ;;
            
        cpu)
            # мониторинг cpu через top
            cpu_stats=$(top -bn1 | grep "Cpu(s)" | awk '{printf "Загрузка CPU: %.1f%% (пользователь: %.1f%%, системные: %.1f%%)\n", $2+$4, $2, $4}')
            
            # cpu top 10
            cpu_stats+=$'\n'"Топ-10 процессов по использованию CPU:"$'\n'
            cpu_stats+="$(get_top_cpu)"
            
            output_result "$cpu_stats" "CPU USAGE"
            ;;
            
        memory)
            # mem
            mem_output=$(free -h | awk 'NR==1 {
                printf "%-10s %10s %10s %10s %10s %10s\n", $1, $2, $3, $4, $5, $6;
                printf "%-10s %10s %10s %10s %10s %10s\n", "----------", "----------", "----------", "----------", "----------", "----------";
            }
            NR==2 {
                printf "%-10s %10s %10s %10s %10s %10s\n", $1, $2, $3, $4, $5, $6;
            }
            NR==3 {
                printf "%-10s %10s %10s %10s %10s %10s\n", $1, $2, $3, $4, $5, $6;
            }')
            
            # mem top 10
            mem_output+=$'\n\n'"Топ-10 процессов по использованию памяти (RSS):"$'\n'
            mem_output+="$(get_top_memory)"
            
            output_result "$mem_output" "MEMORY USAGE"
            ;;
            
        disks)
            # список дисков
            devices=()
            if [[ -n "$DISK_DEVICE" ]]; then
                devices=("$DISK_DEVICE")
            else

                mapfile -t devices < <(lsblk -d -n -o NAME | grep -E '^[sv]d[a-z]+$|^[h]d[a-z]+$|nvme[0-9]+n[0-9]+$' | head -3)
            fi
            
            disk_output=""
            for dev in "${devices[@]}"; do
                if [[ -b "/dev/$dev" ]] || [[ -b "/dev/${dev}1" ]] || [[ "$dev" =~ nvme ]]; then
                    # iostat
                    iostat_data=$(iostat -x -k 1 1 "/dev/$dev" 2>/dev/null | grep "$dev" | awk '{printf "Устройство: %s | Чтение: %.2f МБ/с | Запись: %.2f МБ/с | IOPS(r): %.0f | IOPS(w): %.0f | %%util: %.1f%%\n", $1, $6/1024, $7/1024, $4, $5, $NF}')
                    if [[ -n "$iostat_data" ]]; then
                        disk_output+="$iostat_data"$'\n'
                    fi
                fi
            done
            
            # free space
            disk_output+=$'\n'"Свободное место на дисках:"$'\n'
            disk_output+="$(df -h -x tmpfs -x devtmpfs -x squashfs | awk 'NR==1 {
                printf "%-20s %8s %8s %8s %5s %s\n", "ФС", "Всего", "Исп.", "Своб.", "Исп.%", "Точка_монтирования";
                printf "%-20s %8s %8s %8s %5s %s\n", "--------------------", "--------", "--------", "--------", "-----", "----------";
                next
            }
            $6 !~ /boot|efi/ {
                printf "%-20s %8s %8s %8s %5s %s\n", $1, $2, $3, $4, $5, $6;
            }')"
            
            # io top 10
            disk_output+=$'\n\n'"Топ-10 процессов по дисковому I/O (суммарно чтение+запись за сессию):"$'\n'
            disk_output+="$(get_top_io)"
            
            output_result "$disk_output" "DISK USAGE & IOPS"
            ;;
            
        network)
            net_output=""
            if command -v ifstat &>/dev/null && [[ -n "$NETWORK_INTERFACE" ]]; then
                # ifstat
                net_stats=$(ifstat -i "$NETWORK_INTERFACE" 1 1 2>/dev/null | tail -2 | head -1)
                if [[ -n "$net_stats" ]]; then
                    rx_kb=$(echo "$net_stats" | awk '{print $1}')
                    tx_kb=$(echo "$net_stats" | awk '{print $2}')
                    rx_mbps=$(awk "BEGIN {printf \"%.2f\", $rx_kb * 8 / 1024}")
                    tx_mbps=$(awk "BEGIN {printf \"%.2f\", $tx_kb * 8 / 1024}")
                    net_output="Интерфейс: $NETWORK_INTERFACE | Вход: ${rx_mbps} Мбит/с | Выход: ${tx_mbps} Мбит/с"
                fi
            else
                # /proc/net/dev
                interfaces=()
                if [[ -n "$NETWORK_INTERFACE" ]]; then
                    interfaces=("$NETWORK_INTERFACE")
                else
                    # активные интерфейсы сети
                    mapfile -t interfaces < <(grep -v "lo\|face\|Inter" /proc/net/dev | awk '{if ($2>0 || $10>0) print $1}' | tr -d ':' | head -3)
                fi
                
                for iface in "${interfaces[@]}"; do
                    if grep -q "^ *$iface:" /proc/net/dev 2>/dev/null; then
                        stats_line=$(grep "^ *$iface:" /proc/net/dev | sed 's/^[ \t]*//')
                        rx_bytes=$(echo "$stats_line" | awk -F'[: ]+' '{print $2}')
                        tx_bytes=$(echo "$stats_line" | awk -F'[: ]+' '{print $10}')
                        rx_gb=$(awk "BEGIN {printf \"%.2f\", $rx_bytes / 1024 / 1024 / 1024}")
                        tx_gb=$(awk "BEGIN {printf \"%.2f\", $tx_bytes / 1024 / 1024 / 1024}")
                        net_output+="Интерфейс: $iface | Принято: ${rx_gb} ГБ | Передано: ${tx_gb} ГБ"$'\n'
                    fi
                done
            fi
            
            if [[ -z "$net_output" ]]; then
                net_output="Не найдено активных сетевых интерфейсов для мониторинга"
            fi
            
            output_result "$net_output" "NETWORK USAGE"
            ;;
            
        loadaverage)
            loadavg=$(uptime | grep -o 'load average: .*' | sed 's/load average: //')
            output_result "Средняя нагрузка (1/5/15 мин): $loadavg" "LOAD AVERAGE"
            ;;
            
        kill)
            if ! kill -"$SIGNAL_NUMBER" "$TARGET_PID" 2>/dev/null; then
                error_exit "Не удалось отправить сигнал $SIGNAL_NUMBER процессу $TARGET_PID (проверьте существование процесса и права)"
            fi
            output_result "Сигнал $SIGNAL_NUMBER успешно отправлен процессу $TARGET_PID" "PROCESS SIGNAL"
            ;;
            
        *)
            error_exit "Внутренняя ошибка: неизвестная команда '$cmd'"
            ;;
    esac
done

if [[ -n "$OUTPUT_FILE" ]]; then
    echo "=== Завершение мониторинга: $(date) ===" >> "$OUTPUT_FILE"
    echo "Результаты сохранены в $OUTPUT_FILE"
fi

exit 0
