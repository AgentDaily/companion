import XCTest
@testable import CompanionCore

final class MicrophoneInputTests: XCTestCase {
    let phone = MicrophoneInput(id: "phone", name: "iPhone", kind: .builtIn)
    let dji = MicrophoneInput(id: "dji", name: "DJI Mic Mini", kind: .bluetooth)
    let receiver = MicrophoneInput(id: "usb", name: "DJI Receiver", kind: .usb)
    func testAutomaticSelectionPrefersBluetoothOverPhone() {
        XCTAssertEqual(MicrophoneInputSelection.preferred(in: [phone, dji], id: ""), dji)
    }
    func testExplicitPhoneChoiceIsRespected() {
        XCTAssertEqual(MicrophoneInputSelection.preferred(in: [phone, dji], id: phone.id), phone)
    }
    func testDisconnectedPreferredMicFallsBackAndReconnectRestoresIt() {
        XCTAssertEqual(MicrophoneInputSelection.preferred(in: [phone], id: dji.id), phone)
        XCTAssertEqual(MicrophoneInputSelection.preferred(in: [phone, dji, receiver], id: dji.id), dji)
    }
    func testAutomaticSelectionPrefersReceiverAndNoInputsIsValid() {
        XCTAssertEqual(MicrophoneInputSelection.preferred(in: [phone, dji, receiver], id: ""), receiver)
        XCTAssertNil(MicrophoneInputSelection.preferred(in: [], id: dji.id))
    }
}
