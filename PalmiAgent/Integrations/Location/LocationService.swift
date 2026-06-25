import CoreLocation
import Foundation
import MapKit

struct CurrentLocationSummary: Sendable {
    let coordinate: CLLocationCoordinate2D
    let address: String
}

struct LocationTarget {
    let query: String?
    let coordinate: CLLocationCoordinate2D?
    let name: String?

    var isEmpty: Bool {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedQuery.isEmpty && coordinate == nil
    }
}

struct RouteOpenResult {
    let source: MKMapItem?
    let waypoints: [MKMapItem]
    let destination: MKMapItem
    let openMode: String
}

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authorizationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func requestCurrentAddress() async throws -> String {
        let location = try await requestLocation()
        return try await reverseGeocodedAddress(for: location)
    }

    func promptInjectionAddress() async -> String {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            do {
                return try await requestCurrentAddress()
            } catch {
                return "获取失败"
            }
        case .notDetermined, .denied, .restricted:
            return "无权限"
        @unknown default:
            return "无权限"
        }
    }

    func requestCurrentLocationSummary(for coordinate: CLLocationCoordinate2D? = nil) async throws -> CurrentLocationSummary {
        let location = if let coordinate {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        } else {
            try await requestLocation()
        }
        return CurrentLocationSummary(
            coordinate: location.coordinate,
            address: try await reverseGeocodedAddress(for: location)
        )
    }

    func searchNearby(
        query: String,
        center: CLLocationCoordinate2D? = nil,
        radiusMeters: Double = 2_000,
        resultTypes: MKLocalSearch.ResultType? = nil
    ) async throws -> [MKMapItem] {
        let centerCoordinate: CLLocationCoordinate2D
        if let center {
            centerCoordinate = center
        } else {
            let currentLocation = try await requestLocation()
            centerCoordinate = currentLocation.coordinate
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = searchRegion(center: centerCoordinate, radiusMeters: radiusMeters)
        if let resultTypes {
            request.resultTypes = resultTypes
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
    }

    func openRoute(
        source: LocationTarget? = nil,
        destination: LocationTarget,
        waypointQueries: [String] = [],
        transportMode: String,
        openMode: String = "directions",
        showsTraffic: Bool = false
    ) async throws -> RouteOpenResult {
        guard !destination.isEmpty else {
            throw AppError.invalidState("必须提供目的地查询或目的地坐标。")
        }

        let destinationItem = try await mapItem(for: destination, near: source?.coordinate)
        let sourceItem: MKMapItem? = if let source, !source.isEmpty {
            try await mapItem(for: source, near: coordinate(for: destinationItem))
        } else if openMode == "show" {
            nil
        } else {
            MKMapItem.forCurrentLocation()
        }

        var waypointItems: [MKMapItem] = []
        for query in waypointQueries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let item = try await searchDestination(query: trimmed, near: coordinate(for: destinationItem))
            waypointItems.append(item)
        }

        var launchOptions: [String: Any] = [:]
        launchOptions[MKLaunchOptionsShowsTrafficKey] = showsTraffic
        if openMode != "show" {
            launchOptions[MKLaunchOptionsDirectionsModeKey] = directionsMode(for: transportMode)
        }

        if openMode == "show" {
            destinationItem.openInMaps(launchOptions: launchOptions)
        } else {
            let items = ([sourceItem] + waypointItems + [destinationItem]).compactMap { $0 }
            MKMapItem.openMaps(with: items, launchOptions: launchOptions)
        }

        return RouteOpenResult(
            source: sourceItem,
            waypoints: waypointItems,
            destination: destinationItem,
            openMode: openMode
        )
    }

    func resolveTarget(
        query: String?,
        latitude: Double?,
        longitude: Double?,
        name: String?
    ) -> LocationTarget {
        let coordinate: CLLocationCoordinate2D? = if let latitude, let longitude {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else {
            nil
        }
        return LocationTarget(query: query, coordinate: coordinate, name: name)
    }

    func coordinate(for target: LocationTarget) async throws -> CLLocationCoordinate2D {
        let item = try await mapItem(for: target)
        return coordinate(for: item)
    }

    private func mapItem(
        for target: LocationTarget,
        near center: CLLocationCoordinate2D? = nil
    ) async throws -> MKMapItem {
        if let coordinate = target.coordinate {
            let item = MKMapItem(
                location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                address: nil
            )
            if let name = target.name, !name.isEmpty {
                item.name = name
            }
            return item
        }

        let trimmedQuery = target.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuery.isEmpty else {
            throw AppError.invalidState("位置参数为空。")
        }

        let item = try await searchDestination(query: trimmedQuery, near: center)
        if let name = target.name, !name.isEmpty {
            item.name = name
        }
        return item
    }

    private func searchDestination(query: String, near center: CLLocationCoordinate2D? = nil) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        if let center {
            request.region = searchRegion(center: center, radiusMeters: 50_000)
        } else if let location = try? await requestLocation() {
            request.region = searchRegion(center: location.coordinate, radiusMeters: 50_000)
        }

        let response = try await MKLocalSearch(request: request).start()
        guard let destination = response.mapItems.first else {
            throw AppError.invalidState("没有找到目的地：\(query)")
        }
        return destination
    }

    private func directionsMode(for transportMode: String) -> String {
        switch transportMode {
        case "walking":
            return MKLaunchOptionsDirectionsModeWalking
        case "transit":
            return MKLaunchOptionsDirectionsModeTransit
        default:
            return MKLaunchOptionsDirectionsModeDriving
        }
    }

    private func searchRegion(center: CLLocationCoordinate2D, radiusMeters: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            latitudinalMeters: max(100, radiusMeters),
            longitudinalMeters: max(100, radiusMeters)
        )
    }

    private func coordinate(for item: MKMapItem) -> CLLocationCoordinate2D {
        item.location.coordinate
    }

    private func reverseGeocodedAddress(for location: CLLocation) async throws -> String {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw AppError.operationFailed("无法创建反向地理编码请求。")
        }

        let mapItems = try await request.mapItems
        guard let item = mapItems.first else {
            return "未获取到地址信息。"
        }
        return LocationService.addressText(for: item)
    }

    static func addressText(for item: MKMapItem) -> String {
        if let fullAddress = item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: false),
           !fullAddress.isEmpty {
            return fullAddress
        }

        var parts: [String] = []
        appendNonEmpty(item.name, to: &parts)
        appendNonEmpty(item.address?.shortAddress, to: &parts)
        appendNonEmpty(item.address?.fullAddress, to: &parts)
        appendNonEmpty(item.addressRepresentations?.cityWithContext, to: &parts)
        appendNonEmpty(item.addressRepresentations?.regionName, to: &parts)

        if !parts.isEmpty {
            return parts.joined(separator: "\n")
        }

        return "未获取到地址信息。"
    }

    private static func appendNonEmpty(_ value: String?, to parts: inout [String]) {
        guard let value, !value.isEmpty else {
            return
        }
        parts.append(value)
    }

    private func requestLocation() async throws -> CLLocation {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            try await withCheckedThrowingContinuation { continuation in
                authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        } else if status == .denied || status == .restricted {
            throw AppError.permissionDenied("定位权限被拒绝，请先在设置里授权。")
        }

        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationContinuation?.resume()
            authorizationContinuation = nil
        case .denied, .restricted:
            authorizationContinuation?.resume(throwing: AppError.permissionDenied("定位权限被拒绝。"))
            authorizationContinuation = nil
        case .notDetermined:
            break
        @unknown default:
            authorizationContinuation?.resume(throwing: AppError.operationFailed("未知的定位权限状态。"))
            authorizationContinuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            locationContinuation?.resume(returning: location)
            locationContinuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }
}
