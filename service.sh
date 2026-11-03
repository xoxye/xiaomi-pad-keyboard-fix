#!/system/bin/sh
MODDIR=${0%/*}
LOGFILE="$MODDIR/service.log"
DPMS_NODE="/sys/class/drm/card0-DSI-1/dpms"

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

is_usb_attached() {
    if [ -f "/sys/bus/usb/devices/1-1/idVendor" ]; then
        read -r vid < "/sys/bus/usb/devices/1-1/idVendor" 2>/dev/null
        [ "$vid" = "3206" ] && return 0
    fi
    return 1
}

bind_usbhid() {
    if [ -f "/sys/bus/usb/devices/1-1/power/control" ]; then
        echo "on" > "/sys/bus/usb/devices/1-1/power/control" 2>/dev/null
        echo "-1" > "/sys/bus/usb/devices/1-1/power/autosuspend" 2>/dev/null
    fi
    for intf in /sys/bus/usb/devices/1-1:1.*; do
        if [ -d "$intf" ] && [ ! -d "/sys/bus/usb/drivers/usbhid/${intf##*/}" ]; then
            echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null
        fi
    done
}

unbind_usbhid() {
    for intf in /sys/bus/usb/drivers/usbhid/1-1:1.*; do
        if [ -e "$intf" ]; then
            echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/unbind 2>/dev/null
        fi
    done
}

NODE=$(find_node)
[ -n "$NODE" ] && [ -f "$NODE" ] && echo "enable_keyboard" > "$NODE" 2>/dev/null

log_msg "Xiaomi Pad Keyboard Engine (v1.0.0 Seamless Master) started"

# ============================================================================
# ARCHITECTURE: SINGLE-PROCESS (all variables shared - no subshell isolation)
# ============================================================================

# INITIAL STATE: keep keyboard bound if USB present, protect until unlock
if is_usb_attached; then
    current_state=1
    bind_usbhid
    log_msg "Initial: ATTACHED (USB 1-1 vendor 3206) -> bound, pre-unlock protection"
else
    current_state=0
    unbind_usbhid
    log_msg "Initial: DETACHED -> unbound, on-screen keypad ready"
fi

# State variables (monolithic single-process memory)
unlock_done=0   # Set to 1 after sys.boot_completed=1
settle=0        # Post-unlock IRQ-bounce immunity countdown (ticks)
zero_ticks=0    # Consecutive raw=0 readings for debounce

# MAIN CONTROL LOOP
while true; do

    # === ONE-TIME POST-UNLOCK INITIALIZATION ===
    if [ "$unlock_done" -eq 0 ]; then
        if [ "$(getprop sys.boot_completed)" = "1" ] || [ "$(getprop dev.bootcomplete)" = "1" ]; then
            unlock_done=1

            # Background: shell permissions & IME setting (non-blocking)
            ( setup_shell_permissions; settings put secure show_ime_with_hard_keyboard 1 2>/dev/null ) </dev/null >/dev/null 2>&1 &

            if is_usb_attached; then
                # Refresh MCU power to reset handshake after storage decryption
                if [ -n "$NODE" ] && [ -f "$NODE" ]; then
                    echo "disable_keyboard" > "$NODE" 2>/dev/null
                    sleep 0.15
                    echo "enable_keyboard" > "$NODE" 2>/dev/null
                fi
                sleep 1.5
                bind_usbhid
                current_state=1
                settle=40   # 10s non-cancellable immunity window (prevents unbind during post-boot transients)
                zero_ticks=0
                log_msg "Post-Unlock: MCU pulse + HID rebound -> ready (settle=10s)"
                notify_user "Keyboard Cover" "Keyboard is ready for use"
            else
                unbind_usbhid
                current_state=0
                settle=0
                log_msg "Post-Unlock: no keyboard -> On-screen keyboard active"
            fi
        fi
    fi

    # === READ HARDWARE POGO-PIN IRQ / SENSOR ===
    raw=0
    if [ -n "$NODE" ] && [ -f "$NODE" ]; then
        read -r raw < "$NODE" 2>/dev/null
        case "$raw" in 1*) raw=1 ;; *) raw=0 ;; esac
    fi

    if [ "$raw" = "1" ]; then
        # === KEYBOARD ACTIVE (IRQ confirmed) ===
        zero_ticks=0

        if [ "$current_state" -eq 0 ]; then
            # INSTANT CONNECT (< 0.25s)
            current_state=1
            bind_usbhid
            settings put secure show_ime_with_hard_keyboard 1 2>/dev/null
            log_msg "ATTACHED (raw=1) -> bound, physical keyboard active"
            notify_user "Keyboard Cover" "Keyboard connected (on-screen keyboard available)"
        else
            # MAINTAIN ACTIVE LINK & AUTO-HEAL
            if [ -f "/sys/bus/usb/devices/1-1/power/control" ]; then
                read -r pwr < "/sys/bus/usb/devices/1-1/power/control" 2>/dev/null
                if [ "$pwr" != "on" ]; then
                    echo "on" > "/sys/bus/usb/devices/1-1/power/control" 2>/dev/null
                    echo "-1" > "/sys/bus/usb/devices/1-1/power/autosuspend" 2>/dev/null
                fi
            fi
            for intf in /sys/bus/usb/devices/1-1:1.*; do
                if [ -d "$intf" ] && [ ! -d "/sys/bus/usb/drivers/usbhid/${intf##*/}" ]; then
                    echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null
                fi
            done
        fi
    else
        # === RAW = 0 (detached OR post-boot/post-pulse transient) ===

        # UNBIND DECISION: only after unlock AND settle expired
        if [ "$unlock_done" -eq 1 ] && [ "$settle" -le 0 ]; then
            zero_ticks=$((zero_ticks + 1))

            # 3 consecutive ticks (0.75s debounce) = confirmed physical detachment
            if [ "$current_state" -eq 1 ] && [ "$zero_ticks" -ge 3 ]; then
                current_state=0
                unbind_usbhid
                settings put secure show_ime_with_hard_keyboard 1 2>/dev/null
                log_msg "DETACHED (raw=0 x3) -> unbound, On-screen keyboard active"
                notify_user "Keyboard Cover" "Keyboard disconnected (on-screen keyboard active)"
            fi
        fi

        # KEEP POGO PINS POWERED (waiting for attachment)
        if [ -n "$NODE" ] && [ -f "$NODE" ]; then
            echo "enable_keyboard" > "$NODE" 2>/dev/null
        fi
    fi

    # COUNT DOWN SETTLE IMMUNITY TIMER (unconditionally every tick)
    if [ "$settle" -gt 0 ]; then
        settle=$((settle - 1))
    fi

    # === ADAPTIVE SLEEP: 0.25s screen on, 2.0s screen off ===
    dpms="On"
    [ -f "$DPMS_NODE" ] && read -r dpms < "$DPMS_NODE" 2>/dev/null
    if [ "$dpms" = "Off" ]; then
        sleep 2
    else
        sleep 0.25
    fi
done
