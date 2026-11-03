#!/system/bin/sh
MODDIR=${0%/*}

# Power up and handshake pogo-pin hardware bus at earliest boot stage
for p in \
    "/sys/bus/platform/drivers/xiaomi-keyboard/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
    "/sys/devices/platform/soc/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
    "/sys/bus/platform/devices/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
    /sys/devices/platform/soc/*xiaomi_keyboard*/xiaomi_keyboard_conn_status; do
    if [ -f "$p" ]; then
        echo "disable_keyboard" > "$p" 2>/dev/null
        sleep 0.1
        echo "enable_keyboard" > "$p" 2>/dev/null
        break
    fi
done

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

# PRE-BOOT HARDWARE PROTECTION:
# If keyboard is connected via USB bus (Vendor 3206), keep powered and bound.
# NEVER unbind at cold boot!
USB_DEV=$(get_usb_dev)
if [ -n "$USB_DEV" ]; then
    echo "on" > "$USB_DEV/power/control" 2>/dev/null
    echo "-1" > "$USB_DEV/power/autosuspend" 2>/dev/null
    dev_name="${USB_DEV##*/}"
    for intf in /sys/bus/usb/devices/${dev_name}:1.*; do
        if [ -d "$intf" ] && [ ! -d "/sys/bus/usb/drivers/usbhid/${intf##*/}" ]; then
            echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null
        fi
    done
fi
