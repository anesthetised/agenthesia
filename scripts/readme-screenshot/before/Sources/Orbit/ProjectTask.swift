import Foundation

struct ProjectTask: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var isDone = false
}
