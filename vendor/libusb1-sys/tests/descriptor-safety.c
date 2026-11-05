/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Exercise the actual private parsers without a device, using a unity include.
 * Regressions for CVE-2026-23679 and CVE-2026-47104.
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../libusb/libusb/descriptor.c"

/* The parser paths below never dispatch device I/O. */
const struct usbi_os_backend usbi_backend = {0};
int libusb_control_transfer(libusb_device_handle *handle, uint8_t type, uint8_t request,
    uint16_t value, uint16_t index, unsigned char *data, uint16_t length, unsigned int timeout)
{
    (void)handle; (void)type; (void)request; (void)value; (void)index;
    (void)data; (void)length; (void)timeout;
    return LIBUSB_ERROR_NOT_SUPPORTED;
}

static void endpoint_regression(void)
{
    const uint8_t bytes[] = {9, 2, 20, 0, 1, 1, 0, 0x80, 50,
        9, 4, 0, 0, 1, 0xff, 0, 0, 0, 0xff, 0x24};
    struct libusb_config_descriptor config = {0};
    assert(parse_configuration(NULL, &config, bytes, sizeof(bytes)) >= 0);
    assert(config.bNumInterfaces == 1);
    const struct libusb_interface_descriptor *interface = config.interface[0].altsetting;
    assert(interface->bNumEndpoints == 0 || interface->endpoint != NULL);
    clear_configuration(&config);
}

static void iad_regression(void)
{
    const uint8_t bytes[] = {8, 2, 9, 0, 0, 0, 0, 0, 0};
    uint8_t *exact = malloc(sizeof(bytes));
    assert(exact);
    memcpy(exact, bytes, sizeof(bytes));
    struct libusb_interface_association_descriptor_array array = {0};
    assert(parse_iad_array(NULL, &array, exact, sizeof(bytes)) == LIBUSB_SUCCESS);
    assert(array.length == 0 && array.iad == NULL);
    free(exact);
}

static void valid_descriptors(void)
{
    const uint8_t bytes[] = {9, 2, 25, 0, 1, 1, 0, 0x80, 50,
        9, 4, 0, 0, 1, 0xff, 0, 0, 0, 7, 5, 0x81, 2, 0, 4, 0};
    struct libusb_config_descriptor config = {0};
    assert(parse_configuration(NULL, &config, bytes, sizeof(bytes)) >= 0);
    const struct libusb_interface_descriptor *interface = config.interface[0].altsetting;
    assert(interface->bNumEndpoints == 1);
    assert(interface->endpoint[0].bEndpointAddress == 0x81);
    assert(interface->endpoint[0].wMaxPacketSize == 1024);
    clear_configuration(&config);

    const uint8_t iad[] = {9, 2, 17, 0, 2, 1, 0, 0x80, 50, 8, 11, 1, 2, 0xef, 2, 1, 0};
    struct libusb_interface_association_descriptor_array array = {0};
    assert(parse_iad_array(NULL, &array, iad, sizeof(iad)) == LIBUSB_SUCCESS);
    assert(array.length == 1 && array.iad[0].bFirstInterface == 1);
    assert(array.iad[0].bInterfaceCount == 2 && array.iad[0].bFunctionClass == 0xef);
    free((void *)array.iad);

    const uint8_t short_iad[] = {9, 2, 11, 0, 2, 1, 0, 0x80, 50, 2, 11};
    memset(&array, 0, sizeof(array));
    assert(parse_iad_array(NULL, &array, short_iad, sizeof(short_iad)) == LIBUSB_ERROR_IO);
}

int main(int argc, char **argv)
{
    if (argc == 1 || strcmp(argv[1], "endpoint") == 0) endpoint_regression();
    if (argc == 1 || strcmp(argv[1], "iad") == 0) iad_regression();
    if (argc == 1) valid_descriptors();
    puts("Native USB descriptor regressions passed");
    return 0;
}
