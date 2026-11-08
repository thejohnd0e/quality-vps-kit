# Quality VPS Kit

[EN](README.md) · **RU**

[![CI](https://github.com/thejohnd0e/quality-vps-kit/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/thejohnd0e/quality-vps-kit/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/github/license/thejohnd0e/quality-vps-kit)](LICENSE) [![Release](https://img.shields.io/github/v/release/thejohnd0e/quality-vps-kit?include_prereleases)](https://github.com/thejohnd0e/quality-vps-kit/releases) ![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white) ![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-A81D33?logo=debian&logoColor=white) ![Mode](https://img.shields.io/badge/mode-read--only-success)

Read-only оценка нового VPS **до** того, как вы сделаете из него VPN/proxy-сервер. Войдите под
root, запустите одну команду, получите читаемый отчёт и JSON для машин.

## Related Projects

Эти проекты дополняют друг друга: `qvk` сначала проверяет сервер, затем киты поднимают на нём
VPN/proxy-сервисы. Они независимы: `qvk` их не изменяет и не требует.

- [xray-vps-kit](https://github.com/thejohnd0e/xray-vps-kit): установщик и менеджер клиентов
  сервера **Xray VLESS + REALITY + Vision** по TCP.
- [awg-vps-kit](https://github.com/thejohnd0e/awg-vps-kit): установщик и менеджер клиентов
  сервера **AmneziaWG** по UDP.
- [hysteria-vps-kit](https://github.com/thejohnd0e/hysteria-vps-kit): установщик и менеджер клиентов
  сервера **Hysteria2** (QUIC поверх UDP).

`qvk` отвечает на вопросы: что это за сервер (CPU, память, виртуализация, MTU, NAT),
готов ли он к VPN (AES, BBR, UDP-буферы, занятые порты, `/dev/net/tun`), работает ли
его собственный выход в интернет (внешний IP, DNS, HTTPS, часы), как мир видит его IP
(ASN, префикс, консенсус по стране) и как на него реагируют популярные сервисы.

Это намеренно **не** платформа мониторинга: без демона, базы данных и панели, ничего
не устанавливается и не меняется.

## Быстрый старт

На свежем VPS под **root**:

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/quality-vps-kit/master/install.sh | bash
```

Скрипт скачивает зафиксированный релиз, проверяет SHA-256, запускает отчёт (около минуты)
и удаляет временные файлы. Ничего не устанавливается и настройки не меняются.
Опции передаются после `-s --`, например `... | bash -s -- run --lang ru` или `... | bash -s -- doctor`.

Чтобы сохранить JSON, которым безопасно делиться:

```bash
./qvk run --format json --output report.json --redact-ip
```

Хотите сначала прочитать код? Склонируйте репозиторий и запустите `./qvk doctor`, затем
`./qvk run`, либо скачайте tarball и `SHA256SUMS` со страницы
[Releases](https://github.com/thejohnd0e/quality-vps-kit/releases).

## Как читать отчёт

| Раздел | Что показывает |
|---|---|
| Система | CPU, память, диск, виртуализация, MTU, IPv4/IPv6, firewall, forwarding |
| Готовность к VPN | AES, `/dev/net/tun`, BBR, UDP-буферы, занятые порты |
| Сеть (измерено с этого VPS) | внешний IP и NAT, DNS, тайминги HTTPS, RTT до российских хостов, расхождение часов |
| Репутация IP | ASN, префикс, страна по данным нескольких сервисов (согласие, а не балл) |
| Реакция сервисов | отвечают ли популярные сайты, отказывают (403/429) или молчат при запросе с этого IP |
| Вердикты | `target_self_check`: исправен ли сам сервер. `client_reachability`: в v0.1 всегда `indeterminate` (нужен probe на стороне клиента) |

Каждая строка: `OK`, `ВНИМАНИЕ`, `ОШИБКА`, `ПРОПУЩ.` или `НЕИЗВ.`. `ВНИМАНИЕ` — совет, а не
поломка: например, «порт 443 занят» ожидаем на сервере, где VPN уже работает.

## Честные ограничения (прочитайте сначала)

- **Измерения делаются с VPS.** `qvk` не может сказать, доступен ли VPS **из вашей
  клиентской сети**, например из России. В v0.1 `client_reachability` всегда
  `indeterminate`. Клиентский probe запланирован на v0.2.
- Он никогда не пишет «заблокировано РКН» или «обход работает». HTTP 403/429 от сервиса
  — решение самого сервиса, а не доказательство сетевой фильтрации.
- Репутационные оценки приходят от отдельных провайдеров и не равны вероятности блокировки
  где-либо. `hosting=true` для VPS — норма.
- Неизвестное остаётся `null`/`unknown`/`skipped`; общего балла и «оценки» нет.

Подробности: [docs/methodology.md](docs/methodology.md) (на английском).

## Требования

Debian 12/13 или Ubuntu 22.04/24.04, amd64 или arm64, **root**. Нужны: `bash` (≥ 4.4),
coreutils, `curl`, `iproute2` (есть на минимальных образах). Остальное (`jq`, `ping`,
`ss`, `mtr`, `iperf3`, `dig`, `git`, …) необязательно: без них соответствующая проверка
получает `skipped`. `qvk` не устанавливает пакеты.

## Установка и запуск

Из релизного tarball (`git` не нужен). Скопируйте tarball и `SHA256SUMS` на VPS:

```bash
sha256sum -c SHA256SUMS
tar xzf quality-vps-kit-*.tar.gz
cd quality-vps-kit-*/
./qvk doctor
./qvk run --lang ru
```

Или из checkout: `git clone <url-репозитория> && cd quality-vps-kit && ./qvk run`.

Однострочник передаёт `install.sh` в `bash`; при желании прочитайте его заранее (он короткий). Собрать tarball:
`scripts/release.sh`.

## Использование

```text
qvk doctor                         платформа, права, утилиты (root не нужен)
qvk run [опции]                    выполнить проверки (нужен root)
qvk version | qvk --help
```

| Опция | Смысл |
|---|---|
| `--profile quick\|full` | `full` даёт 20 замеров RTT (чтобы был p95), path MTU, ICMP RTT и сравнение резолверов (нужны `tracepath`, `ping`, `dig`). Нагрузочных тестов в v0.1 нет |
| `--format human\|json` | по умолчанию human; при `--output` — json |
| `--output ФАЙЛ` | записать отчёт в `ФАЙЛ` (права 0600) |
| `--offline` | вообще без внешних запросов; сетевые проверки получают `skipped` |
| `--redact-ip` | заменить IP-адреса (а также префикс и reverse DNS) перед публикацией отчёта |
| `--lang en\|ru` | язык отчёта для человека; JSON всегда английский |
| `--endpoints ФАЙЛ` | свой список endpoint (по умолчанию `config/endpoints.tsv`) |

`--allow-load` и `--max-traffic-mb` предусмотрены для v0.2 и пока завершаются кодом 1.

Примеры:

```bash
./qvk run --lang ru                              # читаемый отчёт
./qvk run --format json --output report.json --redact-ip
./qvk run --profile full
./qvk run --offline                              # только локальные факты
```

Коды выхода: `0` отчёт сформирован (при любом вердикте) · `1` ошибка использования ·
`2` нет root или неподдерживаемая платформа · `3` внутренняя ошибка · `130` прервано.
Вердикт читайте из JSON (`summary.verdicts`), а не из кода выхода.

Необязательные ключи — **только через окружение**: `IPINFO_TOKEN`, `ABUSEIPDB_API_KEY`.

## Что и куда отправляется

Без `--offline` `qvk` обращается к echo-сервисам, RIPEstat, IPinfo, при наличии ключа —
к AbuseIPDB, а также к endpoint из `config/endpoints.tsv`; все они узнают публичный IP
VPS. Подробнее: [docs/security.md](docs/security.md).

## Пока не реализовано

Нагрузочные тесты (`--allow-load`), отчёты traceroute/`mtr`, контроллер
`qvkctl`, клиентские probe и `compare` (v0.2), реальные тесты VPN-туннелей (v0.3),
Markdown-отчёты, пользовательский файл критериев. План: [docs/roadmap.md](docs/roadmap.md).

## Тесты

`bash tests/run.sh` выполняет проверку синтаксиса, ShellCheck (если установлен), проверку
схемы и модульные тесты на фикстурах. Сети он не касается и root не требует. Тесты
запускались в Git Bash (Windows) и Debian 12 (WSL), а `qvk run --profile full` — под
настоящим root на лабораторной ВМ Debian 13. **Прогоны на VPS у хостеров — отдельный
ручной шаг**, CI их не покрывает.

## Лицензия

[MIT](LICENSE).
