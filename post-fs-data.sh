#!/system/bin/sh
MODDIR=${0%/*}

# Power up pogo-pin hardware bus at earliest boot stage
for p in \
    "/sys/bus/platform/drivers/xiaomi-keyboard/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
    "/sys/devices/platform/soc/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
    "/sys/bus/platform/devices/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
    /sys/devices/platform/soc/*xiaomi_keyboard*/xiaomi_keyboard_conn_status; do
    if [ -f "$p" ]; then
        echo "enable_keyboard" > "$p" 2>/dev/null
        break
    fi
done

# PRE-BOOT HARDWARE PROTECTION:
# If keyboard is connected via USB bus (Vendor 3206), keep powered and bound.
# NEVER unbind at cold boot!
if [ -f "/sys/bus/usb/devices/1-1/idVendor" ]; then
    read -r vid < "/sys/bus/usb/devices/1-1/idVendor" 2>/dev/null
    if [ "$vid" = "3206" ]; then
        echo "on" > "/sys/bus/usb/devices/1-1/power/control" 2>/dev/null
        echo "-1" > "/sys/bus/usb/devices/1-1/power/autosuspend" 2>/dev/null
        for intf in /sys/bus/usb/devices/1-1:1.*; do
            if [ -d "$intf" ] && [ ! -d "/sys/bus/usb/drivers/usbhid/${intf##*/}" ]; then
                echo "${intf##*/}" > /sys/bus/usb/drivers/usbhid/bind 2>/dev/null
            fi
        done
    fi
fi
