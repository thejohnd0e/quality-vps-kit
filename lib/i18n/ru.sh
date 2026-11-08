# shellcheck shell=bash
# Russian message catalog. Missing keys fall back to English.
# shellcheck disable=SC2034

declare -gA QVK_MSG_RU
QVK_MSG_RU=(
  [usage]='Использование: qvk <команда> [опции]

Read-only оценка нового VPS перед использованием в качестве VPN/proxy-сервера.
Запускайте от root сразу после входа по SSH.

Команды:
  doctor        Поддержка платформы, права и доступные утилиты (root не нужен)
  run           Выполнить проверки и сформировать отчёт (нужен root)
  version       Показать версию
  help          Показать эту справку

Опции run:
  --profile quick|full    Профиль проверки (по умолчанию quick). В v0.1 "full" без нагрузочных тестов
  --format human|json     Формат вывода (по умолчанию human, при --output — json)
  --output ФАЙЛ           Записать отчёт в ФАЙЛ (права 0600) вместо stdout
  --offline               Не обращаться ни к каким внешним интернет-ресурсам
  --redact-ip             Заменить IP-адреса в отчёте стабильными метками
  --allow-load            Нагрузочные тесты: не реализовано в v0.1
  --max-traffic-mb N      Лимит трафика нагрузочных тестов: не реализовано в v0.1

Общие опции:
  --lang en|ru            Язык человекочитаемого вывода (JSON всегда на английском)
  -h, --help              Справка

Коды выхода: 0 отчёт сформирован (при любом вердикте), 1 ошибка использования,
2 нет root или неподдерживаемая платформа, 3 внутренняя ошибка, 130 прервано.'

  [err.unknown_command]='неизвестная команда: %s (см. "qvk --help")'
  [err.unknown_option]='неизвестная опция для "%s": %s'
  [err.missing_value]='опции %s нужно значение'
  [err.bad_value]='недопустимое значение %s: %s (ожидается: %s)'
  [err.load_not_implemented]='нагрузочные тесты не реализованы в v0.1 (--allow-load / --max-traffic-mb); запланированы на v0.2'
  [err.not_root]='"qvk run" нужно запускать от root (вход "ssh root@<vps>"); текущий uid: %s'
  [err.unsupported_platform]='неподдерживаемая платформа: %s (поддерживаются Debian 12/13, Ubuntu 22.04/24.04 на amd64/arm64)'
  [err.bash_too_old]='bash %s слишком старый; нужен bash >= 4.4'
  [err.missing_required]='нет обязательных утилит: %s (qvk не устанавливает пакеты; см. "qvk doctor")'

  [doctor.title]='qvk doctor: %s %s'
  [doctor.section.platform]='Платформа'
  [doctor.section.required]='Обязательные утилиты'
  [doctor.section.optional]='Необязательные утилиты'
  [doctor.section.devices]='Устройства'
  [doctor.os]='ОС'
  [doctor.arch]='Архитектура'
  [doctor.bash]='Bash'
  [doctor.privileges]='Права'
  [doctor.supported]='поддерживается'
  [doctor.unsupported]='не поддерживается'
  [doctor.unknown_os]='неизвестно (нет читаемого os-release)'
  [doctor.bash_old]='слишком старый, нужен bash >= 4.4'
  [doctor.root]='root'
  [doctor.not_root]='не root (uid %s): "qvk run" откажется работать; войдите под root'
  [doctor.found]='есть'
  [doctor.missing]='нет'
  [doctor.tun_present]='есть'
  [doctor.tun_absent]='нет (нужен большинству VPN-серверов)'
  [doctor.install_hint]='qvk не устанавливает пакеты. Чтобы добавить недостающие обязательные утилиты:
  apt-get install -y %s'
  [doctor.ready]='Итог: готово к "qvk run"'
  [doctor.not_ready]='Итог: не готово'
  [doctor.ready_need_root]='Итог: платформа готова; для проверок войдите под root'

  [opt.jq]='валидация и форматирование JSON'
  [opt.iconv]='очистка невалидного UTF-8 в отчётах'
  [opt.ping]='ICMP RTT'
  [opt.tracepath]='path MTU и маршрут (профиль full)'
  [opt.mtr]='статистика потерь по маршруту'
  [opt.iperf3]='тесты пропускной способности (v0.2)'
  [opt.dig]='расширенные проверки DNS'
  [opt.ss]='слушающие порты'
  [opt.chronyc]='статус синхронизации часов'
  [opt.timedatectl]='статус синхронизации часов'
  [opt.systemd-detect-virt]='тип виртуализации'
  [opt.git]='обновление checkout'

  [report.title]='Отчёт quality-vps-kit'
  [report.run_id]='ID прогона'
  [report.profile]='Профиль'
  [report.started]='Начало'
  [report.finished]='Окончание'
  [report.os]='ОС'
  [report.arch]='Архитектура'
  [report.kernel]='Ядро'
  [report.offline]='Офлайн-режим'
  [report.verdicts]='Вердикты'
  [report.area.target_self_check]='Самопроверка VPS'
  [report.area.client_reachability]='Доступность из клиентской сети'
  [report.missing]='не хватает данных: %s'
  [report.saved]='Отчёт сохранён в %s'
  [progress.inventory]='сбор сведений о системе (около 2 с)...'
  [report.section.system]='Система'
  [report.section.readiness]='Готовность к VPN'
  [report.virt]='Виртуализация'
  [report.container]='контейнер'
  [report.cpu]='CPU'
  [report.vcpus]='%s vCPU'
  [report.memory]='Память'
  [report.mem_value]='всего %s МБ, доступно %s МБ, swap %s МБ'
  [report.disk]='Диск /'
  [report.disk_value]='всего %s МБ, свободно %s МБ'
  [report.load]='Нагрузка (LA)'
  [report.steal]='CPU steal'
  [report.steal_value]='%s%% (один замер %s с; не вердикт)'
  [report.iface]='Интерфейс'
  [report.ipv4]='IPv4'
  [report.ipv6]='IPv6'
  [report.no_v6_route]='нет IPv6-маршрута по умолчанию'
  [report.ntp]='Синхронизация NTP'
  [report.firewall]='Firewall'
  [report.tables]='таблиц: %s'
  [report.rules]='правил: %s'
  [report.ip_forward]='IP forwarding'
  [report.wireguard]='Модуль WireGuard'
  [report.none]='нет'
  [unknown]='неизвестно'
  [verdict.suitable]='пригоден'
  [verdict.unsuitable]='непригоден'
  [verdict.indeterminate]='не определено'
  [yes]='да'
  [no]='нет'

  [status.pass]='OK'
  [status.warn]='ВНИМАНИЕ'
  [status.fail]='ОШИБКА'
  [status.unknown]='НЕИЗВ.'
  [status.skipped]='ПРОПУЩ.'
  [status.error]='СБОЙ'

  [test.cpu_crypto_accel]='Аппаратный AES'
  [test.tun_device]='/dev/net/tun'
  [test.tcp_bbr_available]='TCP BBR'
  [test.udp_buffer_size]='UDP-буферы'
  [test.listening_ports]='Порты для VPN'

  [rd.unknown]='определить не удалось'
  [rd.aes_yes]='есть'
  [rd.aes_no]='нет: TLS/QUIC упирается в CPU, лучше ChaCha20-Poly1305'
  [rd.tun_yes]='есть'
  [rd.tun_no]='нет: userspace-VPN (amneziawg-go, wireguard-go) не запустятся; для Xray и WireGuard в ядре он не нужен'
  [rd.bbr_yes]='доступен (сейчас: %s)'
  [rd.bbr_no]='недоступен в этом ядре'
  [rd.udpbuf_ok]='rmem_max %s МБ, wmem_max %s МБ'
  [rd.udpbuf_low]='rmem_max %s КБ, wmem_max %s КБ: мало для QUIC/Hysteria. qvk не меняет: sysctl -w net.core.rmem_max=%s net.core.wmem_max=%s'
  [rd.ports_free]='свободны: %s'
  [rd.ports_busy]='заняты: %s'

  [reason.not_implemented]='сетевые проверки в этой сборке ещё не реализованы; собраны только сведения о системе и готовности к VPN'
  [reason.no_probe]='standalone-запуск не может проверить доступность из клиентской сети; нужен клиентский probe (v0.2)'
)
