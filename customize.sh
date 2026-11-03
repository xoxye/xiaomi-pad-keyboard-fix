ui_print "**********************************************"
ui_print "   Xiaomi Pad Keyboard Engine (v1.0.0)"
ui_print "             Author: xoxye"
ui_print "**********************************************"

DEVICE=$(getprop ro.product.device)
ui_print "- Checking device: $DEVICE"
case "$DEVICE" in
    nabu|elish|dagu|pipa|liuqin|yudi)
        ui_print "- Device supported!"
        ;;
    *)
        ui_print "! Warning: '$DEVICE' is not recognized as Xiaomi Pad 5/6."
        ui_print "! Installation might not take effect."
        ;;
esac

ui_print "- Post-Unlock Seamless Auto-Init (No Replugging Needed): ACTIVE"
ui_print "- Seamless Hotplug & Instant On-Screen Keyboard on Detach: ACTIVE"
ui_print "- Continuous Pogo-Pin Hardware Power: ACTIVE"
ui_print "- Instant USB-HID Auto-Binding on Attach: ACTIVE"
ui_print "- Continuous USB Hardware Link (Zero Dropouts): ACTIVE"
ui_print "- On-Screen Keyboard Summon Button Available: ACTIVE"
ui_print "- Screen-Off Adaptive Backoff (2.0s sleep): ACTIVE"
ui_print "- Haptic Vibration Feedback: ACTIVE"
ui_print "- Native HyperOS / AOSP Notifications: ACTIVE"

set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/system/bin/kb" 0 0 0755

# Create symlink for xiaomi-keyboard to eliminate duplicate binary (DRY)
ln -sf kb "$MODPATH/system/bin/xiaomi-keyboard"

ui_print "- Installation complete! Please reboot."
ui_print "**********************************************"
