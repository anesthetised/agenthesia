public import JSONRPC

extension ACP.V1 {
    /// Typed ACP v1 methods, for `Connection.request(_:_:)`, `Connection.notify(_:_:)` and `Router`.
    public enum Method {
        // MARK: Client → agent

        public enum Initialize: RPCRequest {
            public typealias Params = InitializeRequest
            public typealias Result = InitializeResponse
            public static let method = "initialize"
        }

        public enum Authenticate: RPCRequest {
            public typealias Params = AuthenticateRequest
            public typealias Result = EmptyMessage
            public static let method = "authenticate"
        }

        public enum Logout: RPCRequest {
            public typealias Params = EmptyMessage
            public typealias Result = EmptyMessage
            public static let method = "logout"
        }

        public enum NewSession: RPCRequest {
            public typealias Params = NewSessionRequest
            public typealias Result = NewSessionResponse
            public static let method = "session/new"
        }

        public enum LoadSession: RPCRequest {
            public typealias Params = LoadSessionRequest
            public typealias Result = SessionStateResponse
            public static let method = "session/load"
        }

        public enum ResumeSession: RPCRequest {
            public typealias Params = ResumeSessionRequest
            public typealias Result = SessionStateResponse
            public static let method = "session/resume"
        }

        public enum ListSessions: RPCRequest {
            public typealias Params = ListSessionsRequest
            public typealias Result = ListSessionsResponse
            public static let method = "session/list"
        }

        public enum DeleteSession: RPCRequest {
            public typealias Params = SessionRequest
            public typealias Result = EmptyMessage
            public static let method = "session/delete"
        }

        public enum CloseSession: RPCRequest {
            public typealias Params = SessionRequest
            public typealias Result = EmptyMessage
            public static let method = "session/close"
        }

        public enum SetMode: RPCRequest {
            public typealias Params = SetModeRequest
            public typealias Result = EmptyMessage
            public static let method = "session/set_mode"
        }

        public enum SetConfigOption: RPCRequest {
            public typealias Params = SetConfigOptionRequest
            public typealias Result = SetConfigOptionResponse
            public static let method = "session/set_config_option"
        }

        public enum Prompt: RPCRequest {
            public typealias Params = PromptRequest
            public typealias Result = PromptResponse
            public static let method = "session/prompt"
        }

        public enum Cancel: RPCNotification {
            public typealias Params = SessionRequest
            public static let method = "session/cancel"
        }

        // MARK: Agent → client

        public enum SessionUpdate: RPCNotification {
            public typealias Params = SessionNotification
            public static let method = "session/update"
        }

        public enum RequestPermission: RPCRequest {
            public typealias Params = RequestPermissionRequest
            public typealias Result = RequestPermissionResponse
            public static let method = "session/request_permission"
        }

        public enum ReadTextFile: RPCRequest {
            public typealias Params = ReadTextFileRequest
            public typealias Result = ReadTextFileResponse
            public static let method = "fs/read_text_file"
        }

        public enum WriteTextFile: RPCRequest {
            public typealias Params = WriteTextFileRequest
            public typealias Result = EmptyMessage
            public static let method = "fs/write_text_file"
        }

        public enum CreateTerminal: RPCRequest {
            public typealias Params = CreateTerminalRequest
            public typealias Result = CreateTerminalResponse
            public static let method = "terminal/create"
        }

        public enum TerminalOutput: RPCRequest {
            public typealias Params = TerminalRequest
            public typealias Result = TerminalOutputResponse
            public static let method = "terminal/output"
        }

        public enum WaitForTerminalExit: RPCRequest {
            public typealias Params = TerminalRequest
            public typealias Result = TerminalExitStatus
            public static let method = "terminal/wait_for_exit"
        }

        public enum KillTerminal: RPCRequest {
            public typealias Params = TerminalRequest
            public typealias Result = EmptyMessage
            public static let method = "terminal/kill"
        }

        public enum ReleaseTerminal: RPCRequest {
            public typealias Params = TerminalRequest
            public typealias Result = EmptyMessage
            public static let method = "terminal/release"
        }

        public enum CreateElicitation: RPCRequest {
            public typealias Params = ACP.ElicitationRequest
            public typealias Result = ACP.ElicitationResponse
            public static let method = "elicitation/create"
        }

        public enum CompleteElicitation: RPCNotification {
            public typealias Params = ACP.ElicitationComplete
            public static let method = "elicitation/complete"
        }
    }

    /// Methods the client calls on the agent.
    public static let agentMethods: [String] = [
        Method.Initialize.method, Method.Authenticate.method, Method.Logout.method, Method.NewSession.method,
        Method.LoadSession.method, Method.ResumeSession.method, Method.ListSessions.method,
        Method.DeleteSession.method, Method.CloseSession.method, Method.SetMode.method,
        Method.SetConfigOption.method, Method.Prompt.method, Method.Cancel.method,
    ]

    /// Methods the agent calls on the client.
    public static let clientMethods: [String] = [
        Method.SessionUpdate.method, Method.RequestPermission.method, Method.ReadTextFile.method,
        Method.WriteTextFile.method, Method.CreateTerminal.method, Method.TerminalOutput.method,
        Method.WaitForTerminalExit.method, Method.KillTerminal.method, Method.ReleaseTerminal.method,
        Method.CreateElicitation.method, Method.CompleteElicitation.method,
    ]

    /// Methods either side may send.
    public static let protocolMethods: [String] = ["$/cancel_request"]
}
