import Testing

@testable import AgenthesiaCore

struct ProjectBadgeTests {
    @Test(arguments: [
        ("agenthesia", "AG"), ("my-project", "MP"), ("my_cool.app", "MC"), ("Open Source Tools", "OS"),
        ("a", "A"), ("--x--", "X"), ("web  app", "WA"), ("", ""), ("  ", ""), ("élan vital", "ÉV"),
    ])
    func initialsComeFromTheFirstTwoWordsOrTheFirstTwoLetters(name: String, expected: String) {
        #expect(ProjectBadge.initials(of: name) == expected)
    }

    @Test func hashIsFNV1aAndStableAcrossLaunches() {
        #expect(ProjectBadge.hash("") == 0xcbf2_9ce4_8422_2325)
        #expect(ProjectBadge.hash("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(ProjectBadge.hash("foobar") == 0x8594_4171_f739_67e8)
    }
}
