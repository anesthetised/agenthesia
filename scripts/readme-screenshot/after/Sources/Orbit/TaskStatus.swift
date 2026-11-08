enum TaskStatus: String, CaseIterable, Identifiable {
    case all, active, completed

    var id: Self { self }
    var title: String { rawValue.capitalized }

    func includes(_ task: ProjectTask) -> Bool {
        switch self {
        case .all: true
        case .active: !task.isDone
        case .completed: task.isDone
        }
    }
}
