import Foundation
import Testing
@testable import DLProbeCore

@Test func assessmentThresholds() {
    #expect(assessLinkSpeedMbps(nil) == .unknown)
    #expect(assessLinkSpeedMbps(480) == .fail)
    #expect(assessLinkSpeedMbps(4_999) == .fail)
    #expect(assessLinkSpeedMbps(5_000) == .pass)
    #expect(assessLinkSpeedMbps(10_000) == .pass)
}

@Test func hexParsing() {
    #expect(parseHexID("600f") == 0x600f)
    #expect(parseHexID("0x600F") == 0x600f)
    #expect(parseHexID(" 17e9 ") == 0x17e9)
    #expect(parseHexID("") == nil)
    #expect(parseHexID("10000") == nil)
    #expect(parseHexID("zzzz") == nil)
}

@Test func jsonFormattingUsesStableKeys() throws {
    let device = USBDeviceReport(
        productName: nil,
        vendorName: nil,
        serialNumber: nil,
        vendorID: 0x17e9,
        productID: 0x600f,
        usbLinkSpeedBitsPerSecond: nil,
        exclusiveOwner: nil
    )

    let rows = try #require(JSONSerialization.jsonObject(with: jsonData([device])) as? [[String: Any]])
    let row = try #require(rows.first)
    #expect(row["vidpid"] as? String == "0x17e9:0x600f")
    #expect(row["assessment"] as? String == "UNKNOWN")
    #expect(row["usbLinkSpeedBitsPerSecond"] is NSNull)
    #expect(row["serialNumber"] is NSNull)
}

@Test func configurationDescriptorParsing() throws {
    let config: [UInt8] = [9, 0x02, 47, 0, 2, 1, 0, 0x80, 0xfa]
    let vendor: [UInt8] = [9, 0x04, 0, 0, 2, 0xff, 0x00, 0x03, 0]
    let bulkOut: [UInt8] = [7, 0x05, 0x01, 0x02, 0x00, 0x04, 0]
    let companion: [UInt8] = [6, 0x30, 15, 0, 0, 0]
    let intIn: [UInt8] = [7, 0x05, 0x81, 0x03, 0x40, 0x00, 4]
    let dfu: [UInt8] = [9, 0x04, 1, 0, 0, 0xfe, 0x01, 0x01, 0]
    let trailingGarbage: [UInt8] = [0xde, 0xad]
    let bytes = config + vendor + bulkOut + companion + intIn + dfu + trailingGarbage

    let interfaces = try parseConfigurationDescriptor(bytes)
    #expect(interfaces == [
        InterfaceLayout(number: 0, alternateSetting: 0, interfaceClass: 0xff, subclass: 0, interfaceProtocol: 3, endpoints: [
            EndpointLayout(address: 0x01, transfer: .bulk, maxPacketSize: 1024, interval: 0, maxBurst: 16),
            EndpointLayout(address: 0x81, transfer: .interrupt, maxPacketSize: 64, interval: 4),
        ]),
        InterfaceLayout(number: 1, alternateSetting: 0, interfaceClass: 0xfe, subclass: 1, interfaceProtocol: 1),
    ])
    #expect(throws: DescriptorParseError.notConfiguration) { try parseConfigurationDescriptor(vendor) }
    #expect(throws: DescriptorParseError.truncated(offset: 9)) {
        try parseConfigurationDescriptor([9, 0x02, 12, 0, 1, 1, 0, 0x80, 0xfa, 9, 0x04, 0])
    }
}

@Test func configurationLengthMustCoverCompleteDescriptor() {
    #expect(throws: DescriptorParseError.truncated(offset: 9)) {
        try parseConfigurationDescriptor([9, 2, 18, 0, 1, 1, 0, 0x80, 0xfa])
    }
    #expect(throws: DescriptorParseError.truncated(offset: 0)) {
        try parseConfigurationDescriptor([9, 2, 0, 0, 1, 1, 0, 0x80, 0xfa])
    }
    #expect(throws: DescriptorParseError.notConfiguration) {
        try parseConfigurationDescriptor([2, 2, 9, 0, 1, 1, 0, 0x80, 0xfa])
    }
}
