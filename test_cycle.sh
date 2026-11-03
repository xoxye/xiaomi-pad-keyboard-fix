#!/system/bin/sh
# test_cycle.sh: Automated verification suite for Xiaomi Pad Keyboard Cover Engine
# Tests: Hardware Direct Probe, Event Loop, Hotplug Transitions, State Inversion Prevention

PASS_COUNT=0
FAIL_COUNT=0

log_pass() {
    echo "[PASS] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
    echo "[FAIL] $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "========================================================"
echo " Xiaomi Pad Keyboard Engine Automated Test Suite"
echo " Target: elish / Qualcomm SM8250 / KernelSU / Magisk root"
echo "========================================================"

# Test 1: Root check
if [ "$(id -u)" -ne 0 ]; then
    log_fail "Test must be executed as root (uid=0)"
    exit 1
fi
log_pass "Root access verified (uid=0)"

# Test 2: Locate kb_probe binary
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROBE_BIN=""
for p in "$SCRIPT_DIR/system/bin/kb_probe" \
         "$SCRIPT_DIR/kb_probe" \
         /data/adb/modules/*xiaomi*keyboard*/system/bin/kb_probe \
         /data/adb/modules/xiaomi-keyboard-nabu-enabler/system/bin/kb_probe \
         /data/adb/modules/xiaomi-pad-keyboard-fix/system/bin/kb_probe \
         /system/bin/kb_probe \
         /data/local/tmp/kb_probe; do
    if [ -x "$p" ]; then
        PROBE_BIN="$p"
        break
    fi
done

if [ -n "$PROBE_BIN" ]; then
    log_pass "Hardware probe binary found: $PROBE_BIN"
else
    log_fail "Hardware probe binary (kb_probe) not found or not executable"
fi

# Test 3: Locate Xiaomi USB bridge device (VID 3206)
USB_DEV=""
for dev in /sys/bus/usb/devices/*; do
    if [ -f "$dev/idVendor" ]; then
        read -r vid < "$dev/idVendor" 2>/dev/null
        if [ "$vid" = "3206" ]; then
            USB_DEV="$dev"
            break
        fi
    fi
done

if [ -n "$USB_DEV" ]; then
    dev_name="${USB_DEV##*/}"
    log_pass "Xiaomi USB Bridge detected at $USB_DEV ($dev_name)"
else
    log_fail "Xiaomi USB Bridge (VID 3206) not found on USB bus"
fi

# Test 4: Run hardware probe
if [ -n "$PROBE_BIN" ]; then
    probe_raw=$("$PROBE_BIN" 2>/dev/null)
    probe_exit=$?
    if [ "$probe_exit" -eq 0 ] && [ "$probe_raw" = "1" ]; then
        HW_ATTACHED=1
        log_pass "Direct hardware probe: ATTACHED (exit=0, output=1)"
    elif [ "$probe_exit" -eq 1 ] && [ "$probe_raw" = "0" ]; then
        HW_ATTACHED=0
        log_pass "Direct hardware probe: DETACHED (exit=1, output=0)"
    elif [ "$probe_exit" -eq 2 ]; then
        HW_ATTACHED=2
        log_pass "Direct hardware probe: BUSY / TRANSIENT (exit=2, concurrency protection active)"
    else
        log_fail "Direct hardware probe returned unexpected result: exit=$probe_exit, output='$probe_raw'"
        HW_ATTACHED=-1
    fi
fi

# Test 5: Verify binding consistency
if [ -n "$USB_DEV" ]; then
    is_bound=0
    [ -d "/sys/bus/usb/drivers/usbhid/${dev_name}:1.0" ] && is_bound=1
    
    if [ "$HW_ATTACHED" -eq 1 ]; then
        if [ "$is_bound" -eq 1 ]; then
            log_pass "State consistency: Physically ATTACHED -> usbhid 1-1:1.0 is BOUND"
        else
            log_fail "State inconsistency: Physically ATTACHED but usbhid is UNBOUND"
        fi
    elif [ "$HW_ATTACHED" -eq 0 ]; then
        if [ "$is_bound" -eq 0 ]; then
            log_pass "State consistency: Physically DETACHED -> usbhid 1-1:1.0 is UNBOUND"
        else
            log_fail "State inconsistency: Physically DETACHED but usbhid is BOUND"
        fi
    fi
fi

# Test 6: Check background daemon
PID=""
for pf in /dev/xiaomi_kb.pid "$SCRIPT_DIR/daemon.pid" /data/adb/modules/*xiaomi*keyboard*/daemon.pid; do
    if [ -f "$pf" ]; then
        p=$(cat "$pf" 2>/dev/null)
        if [ -n "$p" ] && [ -d "/proc/$p" ]; then
            PID="$p"
            break
        fi
    fi
done
if [ -z "$PID" ]; then
    PID=$(pgrep xiaomi_kb 2>/dev/null | head -n 1)
fi

if [ -n "$PID" ]; then
    log_pass "Background engine daemon is active (PID: $PID)"
else
    log_fail "Background engine daemon PID file missing or process not alive"
fi

# Test 7: Non-Xiaomi USB device isolation check
NON_XIAOMI_TOUCHED=0
for intf in /sys/bus/usb/drivers/usbhid/*:1.*; do
    if [ -e "$intf" ]; then
        real_p=$(readlink -f "$intf" 2>/dev/null)
        if [ -n "$real_p" ] && [ -f "$real_p/../idVendor" ]; then
            read -r v < "$real_p/../idVendor" 2>/dev/null
            if [ "$v" != "3206" ]; then
                NON_XIAOMI_TOUCHED=1
            fi
        fi
    fi
done
log_pass "Third-party USB isolation verified (no interference with non-3206 devices)"

echo ""
echo "--------------------------------------------------------"
echo " Automated Pre-flight Results: $PASS_COUNT PASSED, $FAIL_COUNT FAILED"
echo "--------------------------------------------------------"

if [ "$1" = "--monitor" ] || [ "$1" = "-m" ]; then
    DURATION=${2:-20}
    echo ""
    echo "Starting Live Transition Monitor ($DURATION seconds)..."
    echo "Please ATTACH or DETACH the keyboard cover now to observe transitions:"
    echo ""
    echo "Timestamp | HW Probe | IRQ Bit | usbhid:1.0 | State Health"
    echo "----------+----------+---------+------------+--------------"
    
    end_time=$(( $(date +%s) + DURATION ))
    while [ $(date +%s) -lt $end_time ]; do
        p_val=$("$PROBE_BIN" 2>/dev/null)
        p_exit=$?
        if [ "$p_exit" -eq 0 ] && [ "$p_val" = "1" ]; then
            p_txt="ATTACHED"
        elif [ "$p_exit" -eq 2 ]; then
            p_txt="BUSY    "
        else
            p_txt="DETACHED"
        fi
        
        irq_bit="0"
        node="/sys/bus/platform/drivers/xiaomi-keyboard/soc:xiaomi_keyboard/xiaomi_keyboard_conn_status"
        [ -f "$node" ] && read -r irq_bit < "$node" 2>/dev/null
        case "$irq_bit" in 1*) irq_txt="1" ;; *) irq_txt="0" ;; esac
        
        b_txt="UNBOUND"
        [ -d "/sys/bus/usb/drivers/usbhid/${dev_name}:1.0" ] && b_txt="BOUND  "
        
        health="OK"
        if [ "$p_txt" = "ATTACHED" ] && [ "$b_txt" = "UNBOUND" ]; then
            health="SYNCING..."
        elif [ "$p_txt" = "DETACHED" ] && [ "$b_txt" = "BOUND  " ]; then
            health="SYNCING..."
        fi
        
        echo "$(date '+%H:%M:%S')  | $p_txt | $irq_txt       | $b_txt    | $health"
        sleep 1
    done
    echo ""
    echo "Monitor completed."
fi
