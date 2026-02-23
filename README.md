# monitor.sh

Bash-скрипт для мониторинга ресурсов Linux-сервера.  
rebrain #bash - финальное задание

## Возможности

- CPU: загрузка процессора + топ-10 процессов по использованию CPU
- Memory: использование оперативной памяти + топ-10 процессов по потреблению RAM
- Disks: I/O статистика, свободное место на разделах, топ-10 процессов по дисковой активности
- Network: мониторинг трафика сетевых интерфейсов (через ifstat или /proc/net/dev)
- Load Average: вывод средней нагрузки на систему за 1/5/15 минут
- /proc: быстрый доступ к информации из cpuinfo, meminfo, loadavg
- Kill: отправка сигналов процессам (SIGTERM, SIGKILL и другие)
- Output: сохранение результатов мониторинга в файл

## Требования

Обязательные утилиты (обычно присутствуют в системе по умолчанию):
- ps, free, top, df, lsblk, awk, grep, sed

Опциональные утилиты:
- iostat (пакет sysstat) — для детальной статистики дискового I/O
- ifstat — для мониторинга сетевого трафика в реальном времени

Установка опциональных зависимостей (Debian/Ubuntu):
```bash
sudo apt install sysstat ifstat
```

## Скачать скрипт
wget https://raw.githubusercontent.com/Skripko-A/monitor.sh/main/monitor.sh

## Сделать исполняемым
```bash
chmod +x monitor.sh
```
## Переместить в директорию из PATH для глобального доступа
```bash
sudo mv monitor.sh /usr/local/bin/
```
### Показать справку
```bash
./monitor.sh --help
```
### Базовый мониторинг CPU и памяти
```bash
./monitor.sh -c -m
```
### Мониторинг конкретного диска с сохранением в файл
```bash
./monitor.sh -d sda -o report.txt
```
### Просмотр информации о процессоре из /proc
```bash
./monitor.sh --proc cpuinfo
```
### Отправить SIGKILL процессу с PID 1234
```bash
./monitor.sh --kill 9 1234
```
### Комплексный отчёт по всем параметрам
```bash
./monitor.sh -c -m -d -n -la -o full_report.log
```