#!/system/bin/sh
MODDIR=${0%/*}
LOGFILE="$MODDIR/service.log"
PIDFILE="/dev/xiaomi_kb.pid"

# Set process name for clean detection via pgrep
echo xiaomi_kb > /proc/self/comm 2>/dev/null

# --- 1. SINGLE-INSTANCE LOCK ---
if [ -f "$PIDFILE" ]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ] && [ "$old_pid" -ne "$$" ]; then
        kill -9 "$old_pid" 2>/dev/null
    fi
fi
echo "$$" > "$PIDFILE" 2>/dev/null || { PIDFILE="$MODDIR/daemon.pid"; echo "$$" > "$PIDFILE"; }

log_msg() {
    if [ -f "$LOGFILE" ] && [ "$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)" -gt 250 ]; then
        tail -n 100 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv -f "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

notify_user() {
    title="$1"
    msg="$2"
    cmd vibrator_manager synced oneshot 80 2>/dev/null || \
    cmd vibrator vibrate 80 "xiaomi_kb" 2>/dev/null
    cmd notification post -S bigtext -t "$title" "xiaomi_kb" "$msg" 2>/dev/null
}

find_node() {
    for p in \
        "/sys/bus/platform/drivers/xiaomi-keyboard/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
        "/sys/devices/platform/soc/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
        "/sys/bus/platform/devices/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
        /sys/devices/platform/soc/*xiaomi_keyboard*/xiaomi_keyboard_conn_status; do
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

get_usb_dev() {
    for dev in /sys/bus/usb/devices/*; do
        if [ -f "$dev/idVendor" ]; then
            read -r vid < "$dev/idVendor" 2>/dev/null
            if [ "$vid" = "3206" ]; then
                echo "$dev"
                return 0
            fi
        fi
    done
    return 1
}

# БЕЗОПАСНАЯ ПРОВЕРКА: привязан ли именно интерфейс клавиатуры Xiaomi VID 3206
is_kb_bound() {
    [ -z "$CACHED_USB_DEV" ] && CACHED_USB_DEV=$(get_usb_dev)
    if [ -n "$CACHED_USB_DEV" ]; then
        dev_name="${CACHED_USB_DEV##*/}"
        [ -d "/sys/bus/usb/drivers/usbhid/${dev_name}:1.0" ]
        return $?
    fi
    for intf in /sys/bus/usb/drivers/usbhid/*:1.0; do
        if [ -e "$intf" ]; then
            real_p=$(readlink -f "$intf" 2>/dev/null)
            if [ -n "$real_p" ] && [ -f "$real_p/../idVendor" ]; then
                read -r v < "$real_p/../idVendor" 2>/dev/null
                [ "$v" = "3206" ] && return 0
            fi
        fi
    done
    return 1
}

# БЕЗОПАСНЫЙ BIND: включает питание и вяжет ТОЛЬКО интерфейсы Xiaomi VID 3206
bind_keyboard() {
    CACHED_USB_DEV=$(get_usb_dev)
    if [ -n "$CACHED_USB_DEV" ]; then
        if [ -f "$CACHED_USB_DEV/power/control" ]; then
            echo "on" > "$CACHED_USB_DEV/power/control" 2>/dev/null
            echo "-1" > "$CACHED_USB_DEV/power/autosuspend" 2>/dev/null
        fi
        dev_name="${CACHED_USB_DEV##*/}"
        for intf in /sys/bus/usb/devices/${dev_name}:1.*; do
            if [ -d "$intf" ] && [ ! -d "/sys/bus/usb/drivers/usbhid/${intf##*/}" ]; then
                echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null
            fi
        done
    fi
}

# БЕЗОПАСНЫЙ UNBIND: отвязывает ТОЛЬКО интерфейсы Xiaomi VID 3206
# Сторонние USB-устройства (мыши, флешки, геймпады) гарантированно не затрагиваются!
unbind_keyboard() {
    if [ -n "$CACHED_USB_DEV" ]; then
        dev_name="${CACHED_USB_DEV##*/}"
        for intf in /sys/bus/usb/drivers/usbhid/${dev_name}:1.*; do
            [ -e "$intf" ] && echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/unbind 2>/dev/null
        done
    fi
    for intf in /sys/bus/usb/drivers/usbhid/*:1.*; do
        if [ -e "$intf" ]; then
            real_p=$(readlink -f "$intf" 2>/dev/null)
            if [ -n "$real_p" ] && [ -f "$real_p/../idVendor" ]; then
                read -r v < "$real_p/../idVendor" 2>/dev/null
                if [ "$v" = "3206" ]; then
                    echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/unbind 2>/dev/null
                fi
            fi
        fi
    done
}

is_screen_on() {
    for bl in /sys/class/backlight/*/brightness; do
        if [ -f "$bl" ]; then
            read -r b < "$bl" 2>/dev/null
            [ -n "$b" ] && [ "$b" -gt 0 ] && return 0
            return 1
        fi
    done
    for dpms_f in /sys/class/drm/*-DSI-*/dpms; do
        if [ -f "$dpms_f" ]; then
            read -r dpms_val < "$dpms_f" 2>/dev/null
            [ "$dpms_val" = "On" ] && return 0
            return 1
        fi
    done
    return 0
}

NODE=$(find_node)
CACHED_USB_DEV=$(get_usb_dev)
log_msg "Xiaomi Pad Keyboard Engine daemon started (PID: $$)"

# --- 2. STARTUP & COLD BOOT SYNCHRONIZATION ---
# В ядре Xiaomi драйвер soc:xiaomi_keyboard при старте питания производит импульсы,
# оставляющие conn_status = 0 при холодной загрузке.
# Если USB-мост VID 3206 присутствует, мы сразу привязываем клавиатуру,
# обеспечивая мгновенную доступность ввода на экране блокировки.

raw="0"
if [ -n "$NODE" ] && [ -f "$NODE" ]; then
    read -r raw < "$NODE" 2>/dev/null
    case "$raw" in 1*) raw="1" ;; *) raw="0" ;; esac
fi

# На старте всегда связываем для готовности экрана блокировки
if [ -n "$CACHED_USB_DEV" ]; then
    bind_keyboard
    IS_BOUND=1
    log_msg "Startup: Physical keyboard present (VID 3206, sensor=$raw) -> bound, ready for lockscreen"
else
    unbind_keyboard
    IS_BOUND=0
    log_msg "Startup: Keyboard not present -> idle, on-screen keyboard active"
fi

# Режим защиты ранней загрузки (Boot Immunity Window):
# Предотвращает ложный unbind на первых секундах до завершения старта системы
boot_immune=1
boot_start_time=$(date +%s 2>/dev/null || echo 0)

LAST_STABLE_RAW="$raw"
PENDING_RAW="$raw"
DEBOUNCE_COUNT=0
unlock_done=0

while true; do
    # Синхронизация после завершения загрузки системы
    if [ "$unlock_done" -eq 0 ]; then
        if [ "$(getprop sys.boot_completed)" = "1" ] || [ "$(getprop dev.bootcomplete)" = "1" ]; then
            unlock_done=1
            pm grant com.android.shell android.permission.POST_NOTIFICATIONS 2>/dev/null
            cmd appops set com.android.shell POST_NOTIFICATION allow 2>/dev/null
            log_msg "Post-Unlock: boot completed, subsystem ready"
        fi
    fi

    # Снятие иммунитета загрузки через 10 секунд после старта демона или при явном sensor=1
    if [ "$boot_immune" -eq 1 ]; then
        now_time=$(date +%s 2>/dev/null || echo 0)
        elapsed=$((now_time - boot_start_time))
        if [ "$elapsed" -ge 10 ] || [ "$raw" = "1" ]; then
            boot_immune=0
            log_msg "Boot Immunity expired (elapsed=${elapsed}s, sensor=$raw), active management enabled"
        fi
    fi

    # Считывание сырого состояния сенсора pogo-pin
    current_raw="0"
    if [ -n "$NODE" ] && [ -f "$NODE" ]; then
        read -r current_raw < "$NODE" 2>/dev/null
        case "$current_raw" in 1*) current_raw="1" ;; *) current_raw="0" ;; esac
    fi

    # Фильтрация дребезга контактов (Debounce Filter: 2 последовательных тика по 0.25с = 0.5с)
    if [ "$current_raw" != "$LAST_STABLE_RAW" ]; then
        if [ "$current_raw" = "$PENDING_RAW" ]; then
            DEBOUNCE_COUNT=$((DEBOUNCE_COUNT + 1))
            if [ "$DEBOUNCE_COUNT" -ge 2 ]; then
                LAST_STABLE_RAW="$current_raw"
                DEBOUNCE_COUNT=0

                # АБСОЛЮТНАЯ ПРЯМАЯ ЛОГИКА (БЕЗ ТРИГГЕРОВ / ИНВЕРСИЙ):
                # 1 = ФИЗИЧЕСКИ ПОДКЛЮЧЕН -> ВСЕГДА BIND!
                # 0 = ФИЗИЧЕСКИ ОТКЛЮЧЕН -> ВСЕГДА UNBIND!
                if [ "$LAST_STABLE_RAW" = "1" ]; then
                    if [ "$IS_BOUND" -eq 0 ]; then
                        bind_keyboard
                        IS_BOUND=1
                        log_msg "TRANSITION: ATTACHED (sensor=1) -> bound, physical keyboard active"
                        notify_user "Keyboard Cover" "Keyboard connected"
                    fi
                else
                    if [ "$boot_immune" -eq 0 ] && [ "$IS_BOUND" -eq 1 ]; then
                        unbind_keyboard
                        IS_BOUND=0
                        log_msg "TRANSITION: DETACHED (sensor=0) -> unbound, on-screen keyboard active"
                        notify_user "Keyboard Cover" "Keyboard disconnected"
                    fi
                fi
            fi
        else
            PENDING_RAW="$current_raw"
            DEBOUNCE_COUNT=1
        fi
    else
        PENDING_RAW="$current_raw"
        DEBOUNCE_COUNT=0
    fi

    if is_screen_on; then
        sleep 0.25
    else
        sleep 3.0
    fi
done
