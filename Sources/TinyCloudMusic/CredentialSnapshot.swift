import Foundation

enum CredentialSnapshotState: Equatable, Sendable {
    case unavailable
    case guest
    case authenticated(SessionCredentials)
}

struct CredentialSnapshotValue: Equatable, Sendable {
    let state: CredentialSnapshotState
    let revision: UInt64
}

final class CredentialSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CredentialSnapshotValue

    init(_ state: CredentialSnapshotState = .unavailable) {
        value = CredentialSnapshotValue(state: state, revision: 0)
    }

    func load() -> CredentialSnapshotValue {
        lock.withLock { value }
    }

    @discardableResult
    func store(_ state: CredentialSnapshotState) -> CredentialSnapshotValue {
        lock.withLock {
            value = CredentialSnapshotValue(state: state, revision: value.revision + 1)
            return value
        }
    }
}
