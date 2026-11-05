import CoreLocation
import MapKit
import SwiftUI

enum Geo {
    static func dms(_ value: Double, pos: String, neg: String) -> String {
        let a = abs(value)
        let d = Int(a), m = Int((a - Double(d)) * 60), s = (a - Double(d) - Double(m) / 60) * 3600
        return String(format: "%d°%02d'%05.2f\"%@", d, m, s, value >= 0 ? pos : neg)
    }

    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func formats(_ c: CLLocationCoordinate2D) -> [(String, String)] {
        [("Decimal", String(format: "%.6f, %.6f", c.latitude, c.longitude)),
         ("DMS", "\(dms(c.latitude, pos: "N", neg: "S")) \(dms(c.longitude, pos: "E", neg: "W"))"),
         ("GeoJSON", String(format: "[%.6f, %.6f]", c.longitude, c.latitude)),
         ("Google Maps", String(format: "https://maps.google.com/?q=%.6f,%.6f", c.latitude, c.longitude)),
         ("Apple Maps", String(format: "https://maps.apple.com/?ll=%.6f,%.6f", c.latitude, c.longitude))]
    }

    static func describe(_ item: MKMapItem) -> String {
        let address = item.address?.shortAddress ?? item.address?.fullAddress
        return [item.name, address].compactMap { $0 }.filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
    }

    static func search(_ query: String) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        return try? await MKLocalSearch(request: request).start().mapItems.first
    }
}

struct CoordinatePickerView: View {
    enum Mode: String, CaseIterable { case pick = "Pick", measure = "Measure", list = "Look Up a List" }
    @State private var mode: Mode = .pick
    @State private var position: MapCameraPosition = .automatic
    @State private var pins: [CLLocationCoordinate2D] = []
    @State private var address = ""
    @State private var search = ""
    @State private var searchError: String?
    @State private var listInput = ""
    @State private var listRows: [ListRow] = []
    @State private var looking = false

    struct ListRow: Identifiable {
        let id = UUID()
        let query: String
        var coordinate: CLLocationCoordinate2D?
        var match = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlBar {
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                if mode != .list {
                    TextField("Search a place or address", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(runSearch)
                    if let searchError { Text(searchError).foregroundStyle(.red) }
                }
                Spacer()
            }
            .onChange(of: mode) { pins = []; address = "" }

            if mode == .list {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        EditorBox(title: "Places, one per line", text: $listInput, monospaced: false,
                                  placeholder: "Eiffel Tower\n1 Infinite Loop, Cupertino\nTokyo Station")
                        Button(looking ? "Looking Up…" : "Look Up \(lines.count) Place\(lines.count == 1 ? "" : "s")", action: lookUpList)
                            .buttonStyle(.borderedProminent)
                            .disabled(lines.isEmpty || looking)
                    }
                    .frame(width: 280)
                    VStack(alignment: .leading, spacing: 6) {
                        map
                        if !listRows.isEmpty {
                            HStack {
                                Text("\(listRows.filter { $0.coordinate != nil }.count) of \(listRows.count) found").font(.headline)
                                Spacer()
                                CopyButton(text: csv, label: "Copy CSV")
                            }
                            Table(listRows) {
                                TableColumn("Place") { Text($0.query) }
                                TableColumn("Latitude, Longitude") { row in
                                    Text(row.coordinate.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) } ?? (looking ? "…" : "Not found"))
                                        .font(.body.monospaced()).textSelection(.enabled)
                                }
                                TableColumn("Match") { Text($0.match).foregroundStyle(.secondary) }
                            }
                            .frame(minHeight: 140)
                        }
                    }
                }
            } else {
                map
                info
            }
        }
    }

    private var lines: [String] {
        listInput.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var csv: String {
        "place,latitude,longitude\n" + listRows.map { r in
            let c = r.coordinate.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) } ?? ","
            return "\"\(r.query.replacingOccurrences(of: "\"", with: "\"\""))\",\(c)"
        }.joined(separator: "\n")
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                if mode == .list {
                    ForEach(listRows) { row in
                        if let c = row.coordinate { Marker(row.query, coordinate: c) }
                    }
                } else {
                    ForEach(Array(pins.enumerated()), id: \.offset) { i, c in
                        Marker(mode == .measure ? (i == 0 ? "A" : "B") : "", coordinate: c)
                    }
                    if mode == .measure && pins.count == 2 {
                        MapPolyline(coordinates: pins).stroke(.blue, lineWidth: 3)
                    }
                }
            }
            .onTapGesture { point in
                guard mode != .list, let c = proxy.convert(point, from: .local) else { return }
                drop(c)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(minHeight: 260)
    }

    @ViewBuilder private var info: some View {
        switch mode {
        case .pick:
            if let pin = pins.first {
                VStack(alignment: .leading, spacing: 4) {
                    if !address.isEmpty { Text(address).foregroundStyle(.secondary).textSelection(.enabled) }
                    ForEach(Geo.formats(pin), id: \.0) { ValueRow(label: $0.0, value: $0.1) }
                }
            } else {
                Text("Click anywhere on the map to drop a pin, or search a place.").foregroundStyle(.secondary)
            }
        case .measure:
            if pins.count == 2 {
                let m = Geo.distance(pins[0], pins[1])
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%.2f km  ·  %.2f mi", m / 1000, m / 1609.344)).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text("Straight-line distance. Click again to start a new measurement.").foregroundStyle(.secondary)
                }
            } else {
                Text(pins.isEmpty ? "Click the first point on the map." : "Now click the second point.").foregroundStyle(.secondary)
            }
        case .list:
            EmptyView()
        }
    }

    private func drop(_ c: CLLocationCoordinate2D) {
        if mode == .measure {
            pins = pins.count >= 2 ? [c] : pins + [c]
            return
        }
        pins = [c]
        address = ""
        Task {
            let request = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if let item = try? await request?.mapItems.first { address = Geo.describe(item) }
        }
    }

    private func runSearch() {
        Task {
            guard let item = await Geo.search(search) else { searchError = "No results"; return }
            searchError = nil
            let c = item.location.coordinate
            position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 1500, longitudinalMeters: 1500))
            drop(c)
            if mode == .pick { address = Geo.describe(item) }
        }
    }

    private func lookUpList() {
        listRows = lines.map { ListRow(query: $0) }
        looking = true
        Task {
            for i in listRows.indices {
                if let item = await Geo.search(listRows[i].query) {
                    listRows[i].coordinate = item.location.coordinate
                    listRows[i].match = Geo.describe(item)
                }
            }
            looking = false
            position = .automatic
        }
    }
}
