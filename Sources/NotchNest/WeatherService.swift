import CoreLocation
import Foundation

struct WeatherNow: Equatable {
    let temperature: Double
    let high: Double
    let low: Double
    let code: Int
    let isDay: Bool
    let place: String

    var symbol: String { WeatherNow.symbol(code: code, isDay: isDay) }
    var summary: String { WeatherNow.summary(code: code) }

    /// WMO weather codes, as Open-Meteo reports them.
    static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func summary(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorms"
        default: return "Cloudy"
        }
    }
}

/// Current weather from Open-Meteo (free, no account) for your location, or for a city set in
/// Settings if Location is off.
@Observable @MainActor
final class WeatherService {
    private(set) var now: WeatherNow?
    private(set) var problem: String?
    @ObservationIgnored private let locator = LocationFetcher()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var place: (latitude: Double, longitude: Double, name: String)?
    @ObservationIgnored private var placeFound: Date?
    @ObservationIgnored private var placeSource = ""

    func start() {
        refresh()
        let timer = Timer(timeInterval: 20 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard Prefs.bool(Prefs.weather) else {
            now = nil
            return
        }
        let city = (UserDefaults.standard.string(forKey: Prefs.weatherCity) ?? "").trimmingCharacters(in: .whitespaces)
        Task {
            // Look the place up again when the city changes, or hourly when following your location.
            let stale = placeFound.map { Date().timeIntervalSince($0) > 3600 } ?? true
            if place == nil || placeSource != city || (city.isEmpty && stale) {
                place = city.isEmpty ? await locate() : await Self.geocode(city)
                placeFound = Date()
                placeSource = city
            }
            guard let place else {
                now = nil
                problem = city.isEmpty ? "Allow Location for NotchNest, or type a city in Settings."
                                       : "Couldn't find \"\(city)\"."
                return
            }
            now = await Self.forecast(latitude: place.latitude, longitude: place.longitude, name: place.name)
            problem = now == nil ? "Weather is unavailable right now." : nil
        }
    }

    private func locate() async -> (latitude: Double, longitude: Double, name: String)? {
        let location: CLLocation? = await withCheckedContinuation { continuation in
            locator.fetch { continuation.resume(returning: $0) }
        }
        guard let location else { return nil }
        let name = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first?.locality ?? ""
        return (location.coordinate.latitude, location.coordinate.longitude, name)
    }

    private struct GeocodeResponse: Decodable {
        let results: [Place]?
        struct Place: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
        }
    }

    private static func geocode(_ city: String) async -> (latitude: Double, longitude: Double, name: String)? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        guard let response = try? await URLSession.shared.data(from: components.url!),
              let decoded = try? JSONDecoder().decode(GeocodeResponse.self, from: response.0),
              let first = decoded.results?.first else { return nil }
        return (first.latitude, first.longitude, first.name)
    }

    private struct ForecastResponse: Decodable {
        let current: Current
        let daily: Daily
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
    }

    private static func forecast(latitude: Double, longitude: Double, name: String) async -> WeatherNow? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: Locale.current.measurementSystem == .us ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let response = try? await URLSession.shared.data(from: components.url!),
              let decoded = try? JSONDecoder().decode(ForecastResponse.self, from: response.0) else { return nil }
        return WeatherNow(temperature: decoded.current.temperature_2m,
                          high: decoded.daily.temperature_2m_max.first ?? decoded.current.temperature_2m,
                          low: decoded.daily.temperature_2m_min.first ?? decoded.current.temperature_2m,
                          code: decoded.current.weather_code, isDay: decoded.current.is_day == 1, place: name)
    }
}

/// One-shot approximate location through Core Location (asks permission the first time).
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((CLLocation?) -> Void)?

    func fetch(_ completion: @escaping (CLLocation?) -> Void) {
        self.completion = completion
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(nil)
        default: manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard completion != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(nil)
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ location: CLLocation?) {
        let completion = self.completion
        self.completion = nil
        completion?(location)
    }
}
