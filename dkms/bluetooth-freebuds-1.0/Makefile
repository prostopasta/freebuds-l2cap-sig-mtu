# Rebuild of the in-tree "bluetooth" module with a raised BR/EDR signalling MTU.
# Our headers must come before the kernel ones, otherwise the stock (unpatched)
# l2cap.h from linux-headers wins and the patch has no effect.
LINUXINCLUDE := -I$(src)/include $(LINUXINCLUDE)

obj-$(CONFIG_BT) += bluetooth.o

bluetooth-y := af_bluetooth.o hci_core.o hci_conn.o hci_event.o mgmt.o \
	hci_sock.o hci_sysfs.o l2cap_core.o l2cap_sock.o smp.o lib.o \
	ecdh_helper.o hci_request.o mgmt_util.o mgmt_config.o hci_codec.o \
	eir.o hci_sync.o

bluetooth-$(CONFIG_DEV_COREDUMP) += coredump.o
bluetooth-$(CONFIG_BT_BREDR) += sco.o
bluetooth-$(CONFIG_BT_LE) += iso.o
bluetooth-$(CONFIG_BT_LEDS) += leds.o
bluetooth-$(CONFIG_BT_MSFTEXT) += msft.o
bluetooth-$(CONFIG_BT_AOSPEXT) += aosp.o
bluetooth-$(CONFIG_BT_DEBUGFS) += hci_debugfs.o
bluetooth-$(CONFIG_BT_SELFTEST) += selftest.o
