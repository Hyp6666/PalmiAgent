import CoreLocation
import MapKit
import XCTest
@testable import PalmiAgent

@MainActor
final class LocationServiceTests: XCTestCase {
    func testMostRecentUsableLocationSkipsZeroCoordinateAndPrefersNewestFix() throws {
        let zeroLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let olderLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            altitude: 0,
            horizontalAccuracy: 20,
            verticalAccuracy: 20,
            timestamp: Date(timeIntervalSince1970: 101)
        )
        let newestLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.2310, longitude: 121.4740),
            altitude: 0,
            horizontalAccuracy: 8,
            verticalAccuracy: 8,
            timestamp: Date(timeIntervalSince1970: 102)
        )

        let selected = try XCTUnwrap(
            LocationService.mostRecentUsableLocation(
                from: [olderLocation, newestLocation, zeroLocation]
            )
        )

        XCTAssertEqual(selected.coordinate.latitude, newestLocation.coordinate.latitude, accuracy: 0.000_001)
        XCTAssertEqual(selected.coordinate.longitude, newestLocation.coordinate.longitude, accuracy: 0.000_001)
    }

    func testPlacemarkNotFoundPreservesCoordinateAndReturnsMissingAddress() async throws {
        let coordinate = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
        let service = LocationService { _ in
            throw NSError(
                domain: MKErrorDomain,
                code: Int(MKError.Code.placemarkNotFound.rawValue)
            )
        }

        let summary = try await service.requestCurrentLocationSummary(for: coordinate)

        XCTAssertEqual(summary.coordinate.latitude, coordinate.latitude, accuracy: 0.000_001)
        XCTAssertEqual(summary.coordinate.longitude, coordinate.longitude, accuracy: 0.000_001)
        XCTAssertEqual(summary.address, "未获取到地址信息。")
    }
}
