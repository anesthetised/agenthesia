import Darwin
import Foundation

/// Spawns `path` as the leader of a new session and process group, with default signal handling and
/// only the descriptors set up by `actions`.
func spawnInNewSession(
    path: String,
    arguments: [String],
    environment: [String: String],
    actions: inout posix_spawn_file_actions_t?
) throws(POSIXError) -> pid_t {
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.ENOMEM) }
    defer { posix_spawnattr_destroy(&attributes) }
    var emptyMask = sigset_t()
    var defaultSignals = sigset_t()
    sigemptyset(&emptyMask)
    sigemptyset(&defaultSignals)
    for signal in [SIGTERM, SIGPIPE, SIGINT, SIGTTIN, SIGTTOU, SIGHUP, SIGQUIT, SIGCHLD] {
        sigaddset(&defaultSignals, signal)
    }
    let flags = Int16(
        POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
    )
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0
    else { throw POSIXError(.EINVAL) }

    var argv = arguments.map { strdup($0) }
    var envp = environment.map { strdup("\($0.key)=\($0.value)") }
    defer {
        for pointer in argv { free(pointer) }
        for pointer in envp { free(pointer) }
    }
    guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
    argv.append(nil)
    envp.append(nil)
    var pid: pid_t = 0
    let status = argv.withUnsafeMutableBufferPointer { args in
        envp.withUnsafeMutableBufferPointer { vars in
            posix_spawn(&pid, path, &actions, &attributes, args.baseAddress, vars.baseAddress)
        }
    }
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EINVAL) }
    return pid
}
