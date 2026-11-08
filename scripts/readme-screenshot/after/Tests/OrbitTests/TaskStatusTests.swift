import Testing

@testable import Orbit

struct TaskStatusTests {
    @Test func filtersByCompletion() {
        let open = ProjectTask(title: "Review the plan")
        let done = ProjectTask(title: "Ship the beta", isDone: true)
        #expect(TaskStatus.all.includes(open) && TaskStatus.all.includes(done))
        #expect(TaskStatus.active.includes(open) && !TaskStatus.active.includes(done))
        #expect(TaskStatus.completed.includes(done) && !TaskStatus.completed.includes(open))
    }
}
