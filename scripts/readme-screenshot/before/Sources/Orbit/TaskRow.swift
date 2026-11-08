import SwiftUI

struct TaskRow: View {
    let task: ProjectTask

    var body: some View {
        Label(task.title, systemImage: task.isDone ? "checkmark.circle.fill" : "circle")
    }
}
