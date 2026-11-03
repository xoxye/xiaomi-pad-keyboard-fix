#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

static int find_xiaomi_usb_path(char *path, size_t max_len) {
    DIR *dir = opendir("/sys/bus/usb/devices");
    if (!dir) return -1;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        char vid_p[256];
        snprintf(vid_p, sizeof(vid_p), "/sys/bus/usb/devices/%s/idVendor", ent->d_name);
        FILE *fv = fopen(vid_p, "r");
        if (fv) {
            char vid[16] = {0};
            if (fgets(vid, sizeof(vid), fv) && strncmp(vid, "3206", 4) == 0) {
                fclose(fv);
                char bus_p[256], dev_p[256];
                snprintf(bus_p, sizeof(bus_p), "/sys/bus/usb/devices/%s/busnum", ent->d_name);
                snprintf(dev_p, sizeof(dev_p), "/sys/bus/usb/devices/%s/devnum", ent->d_name);
                FILE *fb = fopen(bus_p, "r");
                FILE *fd_f = fopen(dev_p, "r");
                if (fb && fd_f) {
                    int b = 0, d = 0;
                    if (fscanf(fb, "%d", &b) == 1 && fscanf(fd_f, "%d", &d) == 1) {
                        snprintf(path, max_len, "/dev/bus/usb/%03d/%03d", b, d);
                        fclose(fb);
                        fclose(fd_f);
                        closedir(dir);
                        return 0;
                    }
                }
                if (fb) fclose(fb);
                if (fd_f) fclose(fd_f);
            } else {
                fclose(fv);
            }
        }
    }
    closedir(dir);
    return -1;
}

int main(int argc, char **argv) {
    int verbose = 0;
    if (argc > 1 && (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--verbose") == 0)) {
        verbose = 1;
    }

    // Cooperative lock between concurrent probes (daemon vs CLI kb)
    int lock_fd = open("/dev/xiaomi_kb_probe.lock", O_RDWR | O_CREAT, 0666);
    if (lock_fd >= 0) {
        for (int i = 0; i < 15; i++) {
            if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) break;
            usleep(20000); // 20ms
        }
    }

    char devpath[256] = {0};
    if (find_xiaomi_usb_path(devpath, sizeof(devpath)) != 0) {
        if (verbose) fprintf(stderr, "Error: Xiaomi USB device (VID 3206) not found\n");
        if (lock_fd >= 0) { flock(lock_fd, LOCK_UN); close(lock_fd); }
        printf("0\n");
        return 1; // DETACHED
    }

    int fd = open(devpath, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        if (verbose) fprintf(stderr, "Error: Cannot open USB device %s (errno=%d: %s)\n", devpath, errno, strerror(errno));
        if (lock_fd >= 0) { flock(lock_fd, LOCK_UN); close(lock_fd); }
        printf("0\n");
        return 1; // DETACHED
    }

    // Detach kernel driver from interface 2 if attached
    struct usbdevfs_ioctl oper;
    memset(&oper, 0, sizeof(oper));
    oper.ifno = 2;
    oper.ioctl_code = USBDEVFS_DISCONNECT;
    oper.data = NULL;
    ioctl(fd, USBDEVFS_IOCTL, &oper);

    // Claim interface 2 with retry loop to prevent race conditions (EBUSY)
    int iface = 2;
    int claimed = 0;
    for (int retry = 0; retry < 5; retry++) {
        if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &iface) == 0) {
            claimed = 1;
            break;
        }
        usleep(20000); // 20ms
    }

    if (!claimed) {
        if (verbose) perror("ioctl USBDEVFS_CLAIMINTERFACE");
        close(fd);
        if (lock_fd >= 0) { flock(lock_fd, LOCK_UN); close(lock_fd); }
        // Exit code 2 (BUSY/TRANSIENT): caller must NOT treat this as DETACHED
        printf("-1\n");
        return 2;
    }

    // Xiaomi vendor command: [0x4e, 0x31, 0x80, 0x38, 0xa1, 0x01, 0x01, 0xda]
    unsigned char send_buf[64] = {0};
    send_buf[0] = 0x4e;
    send_buf[1] = 0x31;
    send_buf[2] = 0x80;
    send_buf[3] = 0x38;
    send_buf[4] = 0xa1;
    send_buf[5] = 0x01;
    send_buf[6] = 0x01;
    send_buf[7] = 0xda;

    struct usbdevfs_bulktransfer bulk;
    memset(&bulk, 0, sizeof(bulk));
    bulk.ep = 0x04; // OUT endpoint
    bulk.len = 64;
    bulk.timeout = 120; // 120ms timeout (rock-solid under CPU frequency scaling)
    bulk.data = send_buf;

    int r = ioctl(fd, USBDEVFS_BULK, &bulk);
    if (r < 0) {
        unsigned int clear_ep = 0x04;
        ioctl(fd, USBDEVFS_CLEAR_HALT, &clear_ep);
        if (verbose) perror("ioctl USBDEVFS_BULK OUT");
        ioctl(fd, USBDEVFS_RELEASEINTERFACE, &iface);
        close(fd);
        if (lock_fd >= 0) { flock(lock_fd, LOCK_UN); close(lock_fd); }
        printf("0\n");
        return 1;
    }

    unsigned char recv_buf[64] = {0};
    memset(&bulk, 0, sizeof(bulk));
    bulk.ep = 0x84; // IN endpoint
    bulk.len = 64;
    bulk.timeout = 120; // 120ms timeout
    bulk.data = recv_buf;

    r = ioctl(fd, USBDEVFS_BULK, &bulk);
    if (r < 0) {
        unsigned int clear_ep = 0x84;
        ioctl(fd, USBDEVFS_CLEAR_HALT, &clear_ep);
        if (verbose) perror("ioctl USBDEVFS_BULK IN");
        ioctl(fd, USBDEVFS_RELEASEINTERFACE, &iface);
        close(fd);
        if (lock_fd >= 0) { flock(lock_fd, LOCK_UN); close(lock_fd); }
        printf("0\n");
        return 1;
    }

    ioctl(fd, USBDEVFS_RELEASEINTERFACE, &iface);
    close(fd);
    if (lock_fd >= 0) { flock(lock_fd, LOCK_UN); close(lock_fd); }

    if (verbose) {
        fprintf(stderr, "Received %d bytes. Byte[9] = 0x%02x\n", r, (r > 9 ? recv_buf[9] : 0));
        fprintf(stderr, "Raw: ");
        for (int i = 0; i < (r < 16 ? r : 16); i++) {
            fprintf(stderr, "%02x ", recv_buf[i]);
        }
        fprintf(stderr, "\n");
    }

    if (r >= 10) {
        // Xiaomi response header: 0x24 ('$'), 0x31 ('1')
        if (recv_buf[0] == 0x24 && recv_buf[1] == 0x31) {
            unsigned char b9 = recv_buf[9];
            // (recBuf[9] & 0x63) == 0x23: MIUI attached condition
            if ((b9 & 0x63) == 0x23) {
                printf("1\n");
                return 0; // ATTACHED
            }
        }
    }

    printf("0\n");
    return 1; // DETACHED
}
