import Foundation
import XCTest
@testable import Amore134Components

final class Amore138DeviceToolRequestTests: XCTestCase {
    func testHelpAndStatusStayReadOnlyAndExplicit() throws {
        XCTAssertEqual(try AmoreDeviceToolRequest(["action":"help"]).argumentsJSON,"{}")
        XCTAssertEqual(try AmoreDeviceToolRequest(["action":"status"]).action,"status")
        XCTAssertThrowsError(try AmoreDeviceToolRequest([:]))
        XCTAssertThrowsError(try AmoreDeviceToolRequest(["action":["name":"do"]]))
        XCTAssertThrowsError(try AmoreDeviceToolRequest(["action":"routines"]))
    }
    func testDoRequiresCompleteNonemptyActions() throws {
        let invalidRequests: [[String: Any]] = [["action":"do"],["action":"do","actionJSON":"{\"actions\":[{}]}"],["action":"do","arguments_json":"{}"],["action":"do","arguments_json":"{\"actions\":[]}"],["action":"do","arguments_json":"{\"actions\":["],["action":"do","arguments_json":"[]"],["action":"do","arguments_json":42]]
        for value in invalidRequests {
            XCTAssertThrowsError(try AmoreDeviceToolRequest(value)) { error in
                XCTAssertTrue(error.localizedDescription.hasPrefix("not_sent:"))
            }
        }
        let request=try AmoreDeviceToolRequest(["action":"do","arguments_json":"{\"actions\":[{\"button\":\"home\"}]} "])
        XCTAssertEqual(request.action,"do")
        XCTAssertTrue(request.argumentsJSON.contains("home"))
        XCTAssertNoThrow(try AmoreDeviceToolRequest(["action":"do","arguments_json":"{\"actions\":[],\"finish\":true}"]))
    }
    func testStructuredObjectIsNotSilentlyDiscarded() throws {
        let data:[String:Any] = ["actions":[["button":"home"]]]
        let request=try AmoreDeviceToolRequest(["action":"do","arguments_json":data])
        let decoded=try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(request.argumentsJSON.utf8)) as? [String:Any])
        XCTAssertEqual((decoded["actions"] as? [[String:String]])?.first?["button"],"home")
    }
    func testPayloadAndActionCountAreBounded() {
        XCTAssertThrowsError(try AmoreDeviceToolRequest(["action":"do","arguments_json":["actions":Array(repeating:["button":"home"],count:21)]]))
        XCTAssertThrowsError(try AmoreDeviceToolRequest(["action":"look","arguments_json":"{\"x\":\""+String(repeating:"a",count:65536)+"\"}"]))
    }
    func testReturnedBodyReplacesToolNameAndKeepsWaitingAndError() {
        for success in [false,true] {
            let result=AmoreDeviceToolPresentation.completed(output:"not_sent: awaiting passcode",success:success,waitingForOwner:true)
            XCTAssertTrue(result.contains("not_sent: awaiting passcode"));XCTAssertTrue(result.contains("Waiting for owner"))
            XCTAssertNotEqual(result,"Tool: device_control")
        }
        XCTAssertEqual(AmoreDeviceToolPresentation.completed(output:"status: not ready",success:true,waitingForOwner:false),"status: not ready")
        XCTAssertTrue(AmoreDeviceToolPresentation.completed(output:"",success:true,waitingForOwner:false).contains("no readable result"))
    }
}
