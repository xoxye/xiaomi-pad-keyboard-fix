ui_print "**********************************************"
ui_print "   Xiaomi Pad Keyboard Engine (v1.0.1)"
ui_print "             Author: xoxye"
ui_print "**********************************************"

DEVICE=$(getprop ro.product.device)
VENDOR_DEV=$(getprop ro.product.vendor.device)
[ -z "$VENDOR_DEV" ] && VENDOR_DEV=$(getprop ro.vendor.product.device)
SKU=$(getprop ro.boot.hardware.sku)

ui_print "- Checking device: $DEVICE (vendor: ${VENDOR_DEV:-$DEVICE})"

is_supported=0
for d in "$DEVICE" "$VENDOR_DEV" "$SKU"; do
    case "$d" in
        nabu|elish|enuma|dagu|pipa|liuqin|yudi)
            is_supported=1
            break
            ;;
    esac
done

has_node=0
for p in \
    "/sys/bus/platform/drivers/xiaomi-keyboard/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
    "/sys/devices/platform/soc/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status" \
    /sys/devices/platform/soc/*xiaomi_keyboard*/xiaomi_keyboard_conn_status; do
    if [ -f "$p" ]; then
        has_node=1
        break
    fi
done

if [ "$is_supported" -eq 1 ] || [ "$has_node" -eq 1 ]; then
    ui_print "- Compatible Xiaomi Pad hardware detected!"
else
    ui_print "! Notice: '$DEVICE' is not directly recognized (custom ROM / Pixel spoof)."
    ui_print "! Installation proceeding based on hardware detection."
fi

ui_print "- Post-Unlock Seamless Auto-Init (No Replugging Needed): ACTIVE"
ui_print "- Seamless Hotplug & Instant On-Screen Keyboard on Detach: ACTIVE"
ui_print "- Continuous Pogo-Pin Hardware Power: ACTIVE"
ui_print "- Instant Dynamic USB-HID Auto-Binding on Attach: ACTIVE"
ui_print "- Continuous USB Hardware Link (Zero Dropouts): ACTIVE"
ui_print "- Screen-Off Adaptive Backoff (8.0s sleep for Deep Sleep): ACTIVE"
ui_print "- Safe Process Management (Dedicated PID): ACTIVE"

# Create symlink for xiaomi-keyboard to eliminate duplicate binary (DRY)
# IMPORTANT: Create symlink BEFORE set_perm_recursive to ensure correct attributes
ln -sf kb "$MODPATH/system/bin/xiaomi-keyboard"

set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/system/bin/kb" 0 0 0755

ui_print "- Installation complete! Please reboot."
ui_print "**********************************************"
