import SwiftUI

struct TaskList: View {
    let tasks: [ProjectTask]

    var body: some View {
        List(tasks) { task in
            TaskRow(task: task)
        }
        .navigationTitle("Tasks")
    }
}
