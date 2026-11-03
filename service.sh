#!/system/bin/sh
MODDIR=${0%/*}
LOGFILE="$MODDIR/service.log"
PIDFILE="/dev/xiaomi_kb.pid"
PROBE_BIN="$MODDIR/system/bin/kb_probe"
if [ ! -x "$PROBE_BIN" ]; then
    for pb in "/data/adb/modules/xiaomi-keyboard-nabu-enabler/system/bin/kb_probe" \
              "/data/adb/modules/xiaomi-pad-keyboard-fix/system/bin/kb_probe" \
              "/system/bin/kb_probe" \
              "/data/local/tmp/kb_probe"; do
        if [ -x "$pb" ]; then
            PROBE_BIN="$pb"
            break
        fi
    done
fi

# Set process name for clean detection via pgrep
echo xiaomi_kb > /proc/self/comm 2>/dev/null

# --- 1. SINGLE-INSTANCE LOCK ---
if [ -f "$PIDFILE" ]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ] && [ "$old_pid" -ne "$$" ]; then
        old_comm=$(cat "/proc/$old_pid/comm" 2>/dev/null)
        if [ "$old_comm" = "xiaomi_kb" ] || grep -q "service.sh" "/proc/$old_pid/cmdline" 2>/dev/null; then
            kill -9 "$old_pid" 2>/dev/null
        fi
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

# АППАРАТНАЯ ПРОВЕРКА ПОДКЛЮЧЕНИЯ ЧЕХЛА (Hardware Direct Query):
# Опрашивает USB-мост (VID 3206) через вендорный протокол Xiaomi (Interface 2, commandGetConnectState).
# Возвращает 0 если чехол физически соединен с pogo-пинами, 1 если отключен.
check_hardware_attached() {
    if [ -x "$PROBE_BIN" ]; then
        "$PROBE_BIN" >/dev/null 2>&1
        return $?
    fi
    # Fallback на системную ноду, если бинарник недоступен
    if [ -n "$NODE" ] && [ -f "$NODE" ]; then
        read -r raw < "$NODE" 2>/dev/null
        case "$raw" in 1*) return 0 ;; *) return 1 ;; esac
    fi
    return 1
}

# БЕЗОПАСНАЯ ПРОВЕРКА: привязан ли интерфейс клавиатуры Xiaomi VID 3206
is_kb_bound() {
    [ -n "$CACHED_USB_DEV" ] && [ ! -d "$CACHED_USB_DEV" ] && CACHED_USB_DEV=""
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

# БЕЗОПАСНЫЙ BIND: включает питание и вяжет ТОЛЬКО интерфейсы Xiaomi VID 3206 (кроме 1.2)
bind_keyboard() {
    CACHED_USB_DEV=$(get_usb_dev)
    if [ -n "$CACHED_USB_DEV" ]; then
        if [ -f "$CACHED_USB_DEV/power/control" ]; then
            echo "on" > "$CACHED_USB_DEV/power/control" 2>/dev/null
            echo "-1" > "$CACHED_USB_DEV/power/autosuspend" 2>/dev/null
        fi
        dev_name="${CACHED_USB_DEV##*/}"
        for intf in /sys/bus/usb/devices/${dev_name}:1.*; do
            case "$intf" in
                *:1.2) continue ;; # Interface 2 reserved for kb_probe hardware protocol
            esac
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
    CACHED_USB_DEV=""
}

is_screen_on() {
    for bl in /sys/class/backlight/*/brightness; do
        if [ -f "$bl" ]; then
            read -r b < "$bl" 2>/dev/null
            [ -n "$b" ] && [ "$b" -gt 0 ] && return 0
        fi
    done
    for dpms_f in /sys/class/drm/*-DSI-*/dpms; do
        if [ -f "$dpms_f" ]; then
            read -r dpms_val < "$dpms_f" 2>/dev/null
            [ "$dpms_val" = "On" ] && return 0
        fi
    done
    [ -e /sys/class/backlight/* ] || [ -e /sys/class/drm/*-DSI-* ] && return 1
    return 0
}

NODE=$(find_node)
[ -n "$NODE" ] && [ -f "$NODE" ] && echo "enable_keyboard" > "$NODE" 2>/dev/null

# Wait up to 3 seconds for USB device to enumerate if early boot
for w in 1 2 3 4 5 6; do
    CACHED_USB_DEV=$(get_usb_dev)
    [ -n "$CACHED_USB_DEV" ] && break
    sleep 0.5
done

log_msg "Xiaomi Pad Keyboard Engine daemon started (PID: $$)"
log_msg "Probe binary: $PROBE_BIN (executable: $([ -x "$PROBE_BIN" ] && echo YES || echo NO))"

# --- 2. STARTUP HARDWARE INITIALIZATION ---
# Прямой аппаратный опрос контроллера чехла:
# Безошибочно определяет наличие чехла даже при холодной загрузке!
if check_hardware_attached; then
    bind_keyboard
    IS_BOUND=1
    log_msg "Startup: Keyboard cover physically ATTACHED -> bound, ready for lockscreen"
else
    unbind_keyboard
    IS_BOUND=0
    log_msg "Startup: Keyboard cover NOT attached -> unbound, on-screen keyboard active"
fi

LAST_RAW="0"
if [ -n "$NODE" ] && [ -f "$NODE" ]; then
    read -r LAST_RAW < "$NODE" 2>/dev/null
    case "$LAST_RAW" in 1*) LAST_RAW="1" ;; *) LAST_RAW="0" ;; esac
fi

unlock_done=0
tick=0
last_screen_state=1
last_notify_time=0

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

    screen_now=0
    if is_screen_on; then
        screen_now=1
    fi

    # Считывание сырого состояния прерывания ядра
    current_raw="0"
    if [ -n "$NODE" ] && [ -f "$NODE" ]; then
        read -r current_raw < "$NODE" 2>/dev/null
        case "$current_raw" in 1*) current_raw="1" ;; *) current_raw="0" ;; esac
    fi

    tick=$((tick + 1))
    need_check=0

    # Триггер 1: произошло аппаратное прерывание на шине (изменение conn_status)
    if [ "$current_raw" != "$LAST_RAW" ]; then
        need_check=1
        LAST_RAW="$current_raw"
    # Триггер 2: экран включился (мгновенная синхронизация при пробуждении)
    elif [ "$screen_now" -eq 1 ] && [ "$last_screen_state" -eq 0 ]; then
        need_check=1
    # Триггер 3: периодический heartbeat (только при включенном экране каждые 2 сек)
    elif [ "$screen_now" -eq 1 ] && [ "$tick" -ge 8 ]; then
        need_check=1
        tick=0
    fi
    last_screen_state="$screen_now"

    if [ "$need_check" -eq 1 ]; then
        if check_hardware_attached; then
            # Чехол физически подключен к pogo-пинам
            if [ "$IS_BOUND" -eq 0 ] || ! is_kb_bound; then
                bind_keyboard
                IS_BOUND=1
                log_msg "TRANSITION: ATTACHED (hardware probe confirmed) -> bound, physical keyboard active"
                now_s=$(date +%s 2>/dev/null || echo 0)
                if [ $((now_s - last_notify_time)) -ge 2 ]; then
                    last_notify_time=$now_s
                    (notify_user "Keyboard Cover" "Keyboard connected") &
                fi
            fi
        else
            # Чехол физически отсоединен от pogo-пинов
            if [ "$IS_BOUND" -eq 1 ] || is_kb_bound; then
                unbind_keyboard
                IS_BOUND=0
                log_msg "TRANSITION: DETACHED (hardware probe confirmed) -> unbound, on-screen keyboard active"
                now_s=$(date +%s 2>/dev/null || echo 0)
                if [ $((now_s - last_notify_time)) -ge 2 ]; then
                    last_notify_time=$now_s
                    (notify_user "Keyboard Cover" "Keyboard disconnected") &
                fi
            fi
        fi
    fi

    if [ "$screen_now" -eq 1 ]; then
        sleep 0.25
    else
        # При выключенном экране спим долго (10 сек) без лишних пробуждений, сохраняя Deep Sleep
        sleep 10.0
    fi
done
