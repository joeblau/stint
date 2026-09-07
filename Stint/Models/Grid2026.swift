import Foundation

struct RaceTeam: Identifiable {
    let name: String
    let color: String
    let drivers: [Driver]
    var id: String { name }
}

/// Official 2026 entrants; demo race order and motion are simulated.
/// Sources: formula1.com/en/teams and the official 2026 driver-number list.
enum Grid2026 {
    static let teams: [RaceTeam] = [
        RaceTeam(name: "McLaren", color: "#FF8700", drivers: [
            Driver(id: "NOR", name: "Lando Norris", number: 1, color: "#FF8700", team: "McLaren"),
            Driver(id: "PIA", name: "Oscar Piastri", number: 81, color: "#FF8700", team: "McLaren"),
        ]),
        RaceTeam(name: "Ferrari", color: "#FF3344", drivers: [
            Driver(id: "LEC", name: "Charles Leclerc", number: 16, color: "#FF3344", team: "Ferrari"),
            Driver(id: "HAM", name: "Lewis Hamilton", number: 44, color: "#FF3344", team: "Ferrari"),
        ]),
        RaceTeam(name: "Red Bull Racing", color: "#478CFF", drivers: [
            Driver(id: "VER", name: "Max Verstappen", number: 3, color: "#478CFF", team: "Red Bull Racing"),
            Driver(id: "HAD", name: "Isack Hadjar", number: 6, color: "#478CFF", team: "Red Bull Racing"),
        ]),
        RaceTeam(name: "Mercedes", color: "#27F4D2", drivers: [
            Driver(id: "RUS", name: "George Russell", number: 63, color: "#27F4D2", team: "Mercedes"),
            Driver(id: "ANT", name: "Kimi Antonelli", number: 12, color: "#27F4D2", team: "Mercedes"),
        ]),
        RaceTeam(name: "Aston Martin", color: "#00BFA0", drivers: [
            Driver(id: "ALO", name: "Fernando Alonso", number: 14, color: "#00BFA0", team: "Aston Martin"),
            Driver(id: "STR", name: "Lance Stroll", number: 18, color: "#00BFA0", team: "Aston Martin"),
        ]),
        RaceTeam(name: "Alpine", color: "#FF87BC", drivers: [
            Driver(id: "GAS", name: "Pierre Gasly", number: 10, color: "#FF87BC", team: "Alpine"),
            Driver(id: "COL", name: "Franco Colapinto", number: 43, color: "#FF87BC", team: "Alpine"),
        ]),
        RaceTeam(name: "Williams", color: "#53B7FF", drivers: [
            Driver(id: "SAI", name: "Carlos Sainz", number: 55, color: "#53B7FF", team: "Williams"),
            Driver(id: "ALB", name: "Alexander Albon", number: 23, color: "#53B7FF", team: "Williams"),
        ]),
        RaceTeam(name: "Haas", color: "#DEE1E2", drivers: [
            Driver(id: "OCO", name: "Esteban Ocon", number: 31, color: "#DEE1E2", team: "Haas"),
            Driver(id: "BEA", name: "Oliver Bearman", number: 87, color: "#DEE1E2", team: "Haas"),
        ]),
        RaceTeam(name: "Racing Bulls", color: "#A0B4FF", drivers: [
            Driver(id: "LAW", name: "Liam Lawson", number: 30, color: "#A0B4FF", team: "Racing Bulls"),
            Driver(id: "LIN", name: "Arvid Lindblad", number: 41, color: "#A0B4FF", team: "Racing Bulls"),
        ]),
        RaceTeam(name: "Audi", color: "#F74735", drivers: [
            Driver(id: "HUL", name: "Nico Hülkenberg", number: 27, color: "#F74735", team: "Audi"),
            Driver(id: "BOR", name: "Gabriel Bortoleto", number: 5, color: "#F74735", team: "Audi"),
        ]),
        RaceTeam(name: "Cadillac", color: "#C6B89E", drivers: [
            Driver(id: "PER", name: "Sergio Pérez", number: 11, color: "#C6B89E", team: "Cadillac"),
            Driver(id: "BOT", name: "Valtteri Bottas", number: 77, color: "#C6B89E", team: "Cadillac"),
        ]),
    ]
    static let drivers = teams.flatMap(\.drivers)
}
