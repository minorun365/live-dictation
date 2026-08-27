final class SessionRegistry<ID: Hashable, Session: AnyObject> {
    private var sessions: [ID: Session] = [:]
    private(set) var activeID: ID?

    var activeSession: Session? {
        activeID.flatMap { sessions[$0] }
    }

    var allSessions: [Session] {
        Array(sessions.values)
    }

    func activate(_ session: Session, id: ID) {
        precondition(activeID == nil, "A recording session is already active")
        sessions[id] = session
        activeID = id
    }

    func beginFinishingActive() -> (id: ID, session: Session)? {
        guard let id = activeID, let session = sessions[id] else { return nil }
        activeID = nil
        return (id, session)
    }

    func session(for id: ID) -> Session? {
        sessions[id]
    }

    func isActive(id: ID) -> Bool {
        activeID == id
    }

    func finish(id: ID) {
        if activeID == id {
            activeID = nil
        }
        sessions[id] = nil
    }
}
