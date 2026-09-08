import Foundation

/// Bundled circuit library: the 2026 calendar plus additional and historic venues.
struct DemoCircuit: Identifiable, Hashable {
    let rawValue: String
    let title: String
    let subtitle: String
    let lapTime: Double
    let is2026: Bool
    var id: String { rawValue }

    static let allCases: [DemoCircuit] = [
        DemoCircuit(rawValue: "austin", title: "Austin", subtitle: "Circuit of the Americas", lapTime: 92, is2026: true),
        DemoCircuit(rawValue: "baku", title: "Baku", subtitle: "Baku City Circuit", lapTime: 100, is2026: true),
        DemoCircuit(rawValue: "barcelona", title: "Barcelona", subtitle: "Circuit de Barcelona-Catalunya", lapTime: 78, is2026: true),
        DemoCircuit(rawValue: "budapest", title: "Budapest", subtitle: "Hungaroring", lapTime: 73, is2026: true),
        DemoCircuit(rawValue: "interlagos", title: "Interlagos", subtitle: "Autódromo José Carlos Pace - Interlagos", lapTime: 72, is2026: true),
        DemoCircuit(rawValue: "lasvegas", title: "Las Vegas", subtitle: "Las Vegas Street Circuit", lapTime: 103, is2026: true),
        DemoCircuit(rawValue: "lusail", title: "Lusail", subtitle: "Losail International Circuit", lapTime: 90, is2026: true),
        DemoCircuit(rawValue: "madrid", title: "Madrid", subtitle: "Circuito de Madring", lapTime: 91, is2026: true),
        DemoCircuit(rawValue: "melbourne", title: "Melbourne", subtitle: "Albert Park Circuit", lapTime: 88, is2026: true),
        DemoCircuit(rawValue: "mexicocity", title: "Mexico City", subtitle: "Autódromo Hermanos Rodríguez", lapTime: 72, is2026: true),
        DemoCircuit(rawValue: "miami", title: "Miami", subtitle: "Miami International Autodrome", lapTime: 90, is2026: true),
        DemoCircuit(rawValue: "monaco", title: "Monaco", subtitle: "Circuit de Monaco", lapTime: 80, is2026: true),
        DemoCircuit(rawValue: "montreal", title: "Montreal", subtitle: "Circuit Gilles-Villeneuve", lapTime: 73, is2026: true),
        DemoCircuit(rawValue: "monza", title: "Monza", subtitle: "Autodromo Nazionale Monza", lapTime: 85, is2026: true),
        DemoCircuit(rawValue: "sepang", title: "Sepang", subtitle: "Sepang International Circuit", lapTime: 92, is2026: true),
        DemoCircuit(rawValue: "shanghai", title: "Shanghai", subtitle: "Shanghai International Circuit", lapTime: 91, is2026: true),
        DemoCircuit(rawValue: "silverstone", title: "Silverstone", subtitle: "Silverstone Circuit", lapTime: 92, is2026: true),
        DemoCircuit(rawValue: "singapore", title: "Singapore", subtitle: "Marina Bay Street Circuit", lapTime: 82, is2026: true),
        DemoCircuit(rawValue: "spafrancorchamps", title: "Spa-Francorchamps", subtitle: "Circuit de Spa-Francorchamps", lapTime: 117, is2026: true),
        DemoCircuit(rawValue: "spielberg", title: "Spielberg", subtitle: "Red Bull Ring", lapTime: 72, is2026: true),
        DemoCircuit(rawValue: "suzuka", title: "Suzuka", subtitle: "Suzuka International Racing Course", lapTime: 97, is2026: true),
        DemoCircuit(rawValue: "yasmarina", title: "Yas Marina", subtitle: "Yas Marina Circuit", lapTime: 88, is2026: true),
        DemoCircuit(rawValue: "zandvoort", title: "Zandvoort", subtitle: "Circuit Zandvoort", lapTime: 71, is2026: true),
        DemoCircuit(rawValue: "buenosaires", title: "Buenos Aires", subtitle: "Autódromo Oscar y Juan Gálvez", lapTime: 72, is2026: false),
        DemoCircuit(rawValue: "estoril", title: "Estoril", subtitle: "Autódromo do Estoril", lapTime: 72, is2026: false),
        DemoCircuit(rawValue: "hockenheim", title: "Hockenheim", subtitle: "Hockenheimring", lapTime: 76, is2026: false),
        DemoCircuit(rawValue: "imola", title: "Imola", subtitle: "Autodromo Enzo e Dino Ferrari", lapTime: 82, is2026: false),
        DemoCircuit(rawValue: "indianapolis", title: "Indianapolis", subtitle: "Indianapolis Motor Speedway", lapTime: 70, is2026: false),
        DemoCircuit(rawValue: "istanbul", title: "Istanbul", subtitle: "Intercity Istanbul Park", lapTime: 89, is2026: false),
        DemoCircuit(rawValue: "jacarepagua", title: "Jacarepaguá", subtitle: "Autódromo Internacional Nelson Piquet", lapTime: 84, is2026: false),
        DemoCircuit(rawValue: "jeddah", title: "Jeddah", subtitle: "Jeddah Corniche Circuit", lapTime: 103, is2026: false),
        DemoCircuit(rawValue: "kyalami", title: "Kyalami", subtitle: "Kyalami Grand Prix Circuit", lapTime: 75, is2026: false),
        DemoCircuit(rawValue: "lecastellet", title: "Le Castellet", subtitle: "Circuit Paul Ricard", lapTime: 97, is2026: false),
        DemoCircuit(rawValue: "magnycours", title: "Magny-Cours", subtitle: "Circuit de Nevers Magny-Cours", lapTime: 74, is2026: false),
        DemoCircuit(rawValue: "mugello", title: "Mugello", subtitle: "Autodromo Internazionale del Mugello", lapTime: 87, is2026: false),
        DemoCircuit(rawValue: "nurburgring", title: "Nürburgring", subtitle: "Nürburgring", lapTime: 86, is2026: false),
        DemoCircuit(rawValue: "portimao", title: "Portimão", subtitle: "Autódromo Internacional do Algarve", lapTime: 78, is2026: false),
        DemoCircuit(rawValue: "sakhir", title: "Sakhir", subtitle: "Bahrain International Circuit", lapTime: 90, is2026: false),
        DemoCircuit(rawValue: "sochi", title: "Sochi", subtitle: "Sochi Autodrom", lapTime: 97, is2026: false),
        DemoCircuit(rawValue: "watkinsglen", title: "Watkins Glen", subtitle: "Watkins Glen International", lapTime: 90, is2026: false),
    ]
    static let monaco = allCases.first { $0.rawValue == "monaco" }!
    static let monza = allCases.first { $0.rawValue == "monza" }!
    static let silverstone = allCases.first { $0.rawValue == "silverstone" }!
}
