import SwiftUI

struct TaskList: View {
    let tasks: [ProjectTask]
    @State private var filter = TaskStatus.all

    private var visibleTasks: [ProjectTask] {
        tasks.filter { filter.includes($0) }
    }

    var body: some View {
        List(visibleTasks) { task in
            TaskRow(task: task)
        }
        .toolbar {
            Picker("Status", selection: $filter) {
                ForEach(TaskStatus.allCases) { status in
                    Text(status.title).tag(status)
                }
            }
            .pickerStyle(.segmented)
        }
        .navigationTitle("Tasks")
    }
}
