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
