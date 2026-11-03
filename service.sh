#!/system/bin/sh
MODDIR=${0%/*}
LOGFILE="$MODDIR/service.log"
PIDFILE="/dev/run/xiaomi_kb.pid"

# Register dedicated PID file safely
mkdir -p /dev/run 2>/dev/null
echo "$$" > "$PIDFILE" 2>/dev/null || PIDFILE="$MODDIR/daemon.pid"
echo "$$" > "$PIDFILE" 2>/dev/null

log_msg() {
    if [ -f "$LOGFILE" ] && [ "$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)" -gt 250 ]; then
        tail -n 100 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv -f "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

setup_shell_permissions() {
    pm grant com.android.shell android.permission.POST_NOTIFICATIONS 2>/dev/null
    cmd appops set com.android.shell POST_NOTIFICATION allow 2>/dev/null
    cmd appops set com.android.shell SYSTEM_ALERT_WINDOW allow 2>/dev/null
    cmd appops set com.android.shell 10021 allow 2>/dev/null
}

notify_user() {
    title="$1"
    msg="$2"

    cmd vibrator_manager synced oneshot 80 2>/dev/null || \
    cmd vibrator_manager feedback -f 1 2>/dev/null || \
    cmd vibrator vibrate 80 "xiaomi_kb" 2>/dev/null

    cmd notification post -S bigtext -t "$title" "xiaomi_kb" "$msg" 2>/dev/null || \
    su -lp 2000 -c "cmd notification post -S bigtext -t '$title' 'xiaomi_kb' '$msg'" 2>/dev/null

    if [ -x "/data/data/com.termux/files/usr/bin/termux-toast" ]; then
        /data/data/com.termux/files/usr/bin/termux-toast -s "$title: $msg" 2>/dev/null &
    fi
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

is_usb_attached() {
    [ -n "$(get_usb_dev)" ]
}

bind_usbhid() {
    usb_dev=$(get_usb_dev)
    if [ -n "$usb_dev" ]; then
        if [ -f "$usb_dev/power/control" ]; then
            echo "on" > "$usb_dev/power/control" 2>/dev/null
            echo "-1" > "$usb_dev/power/autosuspend" 2>/dev/null
        fi
        dev_name="${usb_dev##*/}"
        for intf in /sys/bus/usb/devices/${dev_name}:1.*; do
            if [ -d "$intf" ] && [ ! -d "/sys/bus/usb/drivers/usbhid/${intf##*/}" ]; then
                echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null
            fi
        done
    fi
}

unbind_usbhid() {
    for intf in /sys/bus/usb/drivers/usbhid/*:1.*; do
        [ -e "$intf" ] && echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/unbind 2>/dev/null
    done
}

is_screen_on() {
    has_bl=0
    for bl in /sys/class/backlight/*/brightness; do
        if [ -f "$bl" ]; then
            has_bl=1
            read -r b < "$bl" 2>/dev/null
            if [ -n "$b" ] && [ "$b" -gt 0 ]; then
                return 0
            fi
        fi
    done
    if [ "$has_bl" -eq 1 ]; then
        return 1
    fi
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
[ -n "$NODE" ] && [ -f "$NODE" ] && echo "enable_keyboard" > "$NODE" 2>/dev/null

log_msg "Xiaomi Pad Keyboard Engine (v1.0.1 Dual-Sensor) started"

# ============================================================================
# ARCHITECTURE: POGO-PIN HARDWARE SENSOR + USB BINDING (NO MCU RESET PULSE)
# ============================================================================

# Read initial sensor state
init_raw=0
if [ -n "$NODE" ] && [ -f "$NODE" ]; then
    read -r init_raw < "$NODE" 2>/dev/null
    case "$init_raw" in 1*) init_raw=1 ;; *) init_raw=0 ;; esac
fi

if [ "$init_raw" = "1" ] && is_usb_attached; then
    current_state=1
    bind_usbhid
    log_msg "Initial: ATTACHED (pogo=1, USB present) -> bound, ready for typing"
else
    current_state=0
    unbind_usbhid
    log_msg "Initial: DETACHED (pogo=$init_raw) -> unbound, on-screen keyboard ready"
fi

unlock_done=0
zero_ticks=0

# MAIN CONTROL LOOP
while true; do

    # === ONE-TIME POST-UNLOCK INITIALIZATION ===
    if [ "$unlock_done" -eq 0 ]; then
        if [ "$(getprop sys.boot_completed)" = "1" ] || [ "$(getprop dev.bootcomplete)" = "1" ]; then
            unlock_done=1
            # Configure IME preference in background (never disrupt keyboard power!)
            ( setup_shell_permissions; settings put secure show_ime_with_hard_keyboard 1 2>/dev/null ) </dev/null >/dev/null 2>&1 &
            log_msg "Post-Unlock: boot completed, settings synchronized"
        fi
    fi

    # === READ HARDWARE POGO-PIN SENSOR ===
    raw=0
    if [ -n "$NODE" ] && [ -f "$NODE" ]; then
        read -r raw < "$NODE" 2>/dev/null
        case "$raw" in 1*) raw=1 ;; *) raw=0 ;; esac
    fi

    if [ "$raw" = "1" ]; then
        # POGO-PIN SENSOR: ATTACHED
        zero_ticks=0

        if [ "$current_state" -eq 0 ]; then
            # Transition from DETACHED -> ATTACHED
            if is_usb_attached; then
                current_state=1
                bind_usbhid
                log_msg "ATTACHED (pogo=1, USB detected) -> bound, physical keyboard active"
                notify_user "Keyboard Cover" "Keyboard connected"
            fi
        else
            # Already attached: auto-heal & prevent autosuspend
            usb_dev=$(get_usb_dev)
            if [ -n "$usb_dev" ]; then
                if [ -f "$usb_dev/power/control" ]; then
                    read -r pwr < "$usb_dev/power/control" 2>/dev/null
                    if [ "$pwr" != "on" ]; then
                        echo "on" > "$usb_dev/power/control" 2>/dev/null
                        echo "-1" > "$usb_dev/power/autosuspend" 2>/dev/null
                    fi
                fi
                dev_name="${usb_dev##*/}"
                for intf in /sys/bus/usb/devices/${dev_name}:1.*; do
                    if [ -d "$intf" ] && [ ! -d "/sys/bus/usb/drivers/usbhid/${intf##*/}" ]; then
                        echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null
                    fi
                done
            fi
        fi
    else
        # POGO-PIN SENSOR: DETACHED (raw=0)
        if [ "$current_state" -eq 1 ]; then
            zero_ticks=$((zero_ticks + 1))
            # 2 consecutive ticks (0.50s debounce) confirms physical detachment
            if [ "$zero_ticks" -ge 2 ]; then
                current_state=0
                unbind_usbhid
                # Re-ensure pogo pins are energized waiting for next attachment
                [ -n "$NODE" ] && [ -f "$NODE" ] && echo "enable_keyboard" > "$NODE" 2>/dev/null
                log_msg "DETACHED (pogo=0 x2) -> unbound, On-screen keyboard active"
                notify_user "Keyboard Cover" "Keyboard disconnected"
            fi
        else
            zero_ticks=0
        fi
    fi

    # === ADAPTIVE SLEEP: 0.25s screen on, 2.0s screen off ===
    if is_screen_on; then
        sleep 0.25
    else
        sleep 2.0
    fi
done
