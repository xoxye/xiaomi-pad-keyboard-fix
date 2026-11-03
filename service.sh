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

# БЕЗОПАСНЫЙ BIND: включает питание и вяжет только интерфейсы Xiaomi VID 3206
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

# --- 2. STARTUP & BOOT STATE INITIALIZATION ---
# Never send disable_keyboard at startup - it bounces regulator rails during boot!
# If USB device VID 3206 is already present, keyboard is physically connected and recognized.
raw="0"
if [ -n "$NODE" ] && [ -f "$NODE" ]; then
    read -r raw < "$NODE" 2>/dev/null
    case "$raw" in 1*) raw="1" ;; *) raw="0" ;; esac
fi

if [ -n "$CACHED_USB_DEV" ]; then
    bind_keyboard
    log_msg "Startup: Physical keyboard detected on USB (${CACHED_USB_DEV##*/}) -> bound"
    # Auto-synchronize sensor if desynchronized by early-boot regulator bounce
    if [ "$raw" = "0" ] && [ -n "$NODE" ]; then
        echo "reset" > "$NODE" 2>/dev/null
        sleep 0.2
        read -r raw < "$NODE" 2>/dev/null
        case "$raw" in 1*) raw="1" ;; *) raw="0" ;; esac
        log_msg "Startup: Sensor calibrated via IC reset -> pogo=$raw"
    fi
elif [ "$raw" = "1" ]; then
    # Sensor shows contact, trigger dock reset to wake MCU if needed
    [ -n "$NODE" ] && echo "reset" > "$NODE" 2>/dev/null
    sleep 0.3
    CACHED_USB_DEV=$(get_usb_dev)
    if [ -n "$CACHED_USB_DEV" ]; then
        bind_keyboard
        log_msg "Startup: Keyboard detected after reset (${CACHED_USB_DEV##*/}) -> bound"
    else
        unbind_keyboard
        log_msg "Startup: Sensor=1 but USB device absent -> unbound"
    fi
else
    unbind_keyboard
    log_msg "Startup: Keyboard not docked -> unbound, on-screen keyboard active"
fi

zero_ticks=0
one_ticks=0
unlock_done=0

while true; do
    # Post-boot unlock synchronization
    if [ "$unlock_done" -eq 0 ]; then
        if [ "$(getprop sys.boot_completed)" = "1" ] || [ "$(getprop dev.bootcomplete)" = "1" ]; then
            unlock_done=1
            pm grant com.android.shell android.permission.POST_NOTIFICATIONS 2>/dev/null
            cmd appops set com.android.shell POST_NOTIFICATION allow 2>/dev/null
            
            # Re-check and calibrate sensor state once userspace boot has completed
            CACHED_USB_DEV=$(get_usb_dev)
            if [ -n "$CACHED_USB_DEV" ]; then
                read -r post_raw < "$NODE" 2>/dev/null
                case "$post_raw" in 1*) post_raw="1" ;; *) post_raw="0" ;; esac
                if [ "$post_raw" = "0" ] && [ -n "$NODE" ]; then
                    echo "reset" > "$NODE" 2>/dev/null
                    sleep 0.2
                    log_msg "Post-Unlock: Re-synchronized sensor to 1 via IC reset"
                fi
                bind_keyboard
            fi
            log_msg "Post-Unlock: boot completed, subsystem ready"
        fi
    fi

    # 1. Чтение статуса с сенсора pogo-pin
    raw="0"
    if [ -n "$NODE" ] && [ -f "$NODE" ]; then
        read -r raw < "$NODE" 2>/dev/null
        case "$raw" in 1*) raw="1" ;; *) raw="0" ;; esac
    fi

    # 2. Проверка USB-шины
    USB_PRESENT=0
    CACHED_USB_DEV=$(get_usb_dev)
    [ -n "$CACHED_USB_DEV" ] && USB_PRESENT=1

    if [ "$raw" = "1" ]; then
        # ATTACHED: Чехол пристёгнут в рабочее положение
        zero_ticks=0
        if ! is_kb_bound; then
            one_ticks=$((one_ticks + 1))
            if [ "$one_ticks" -ge 1 ]; then
                if [ "$USB_PRESENT" -eq 0 ] && [ -n "$NODE" ]; then
                    # Если сенсор активен, но USB еще не определился - будим MCU
                    echo "reset" > "$NODE" 2>/dev/null
                    sleep 0.2
                fi
                bind_keyboard
                log_msg "TRANSITION: ATTACHED (pogo=1) -> bound, physical keyboard active"
                notify_user "Keyboard Cover" "Keyboard connected"
            fi
        else
            one_ticks=0
        fi
    else
        # DETACHED: Чехол отстёгнут (raw=0)
        one_ticks=0
        if is_kb_bound; then
            zero_ticks=$((zero_ticks + 1))
            # Дебаунс 0.5с (2 тика по 0.25с) для фильтрации дребезга контактов
            if [ "$zero_ticks" -ge 2 ]; then
                unbind_keyboard
                log_msg "TRANSITION: DETACHED (pogo=0 x2) -> unbound, on-screen keyboard active"
                notify_user "Keyboard Cover" "Keyboard disconnected"
            fi
        else
            zero_ticks=0
        fi
    fi

    if is_screen_on; then
        sleep 0.25
    else
        sleep 4.0
    fi
done
