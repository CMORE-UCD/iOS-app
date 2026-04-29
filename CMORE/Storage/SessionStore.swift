//
//  SessionStore.swift
//  CMORE
//

import Foundation
import SwiftData

/// Manages Session persistence via SwiftData.
/// Video and results files remain stored in the Documents directory.
actor SessionStore {

    // MARK: - Singleton
    static let shared = SessionStore()

    nonisolated let container: ModelContainer
    private let context: ModelContext

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private init() {
        self.container = try! ModelContainer(for: Session.self)
        self.context = ModelContext(container)
    }

    // MARK: - CRUD

    func add(_ session: Session) throws {
        context.insert(session)
        do {
            try context.save()
        } catch {
            dprint("Session store add error: \(error)")
            throw error
        }
    }

    func delete(_ session: Session) throws {
        let videoURL = documentsDirectory.appendingPathComponent(session.videoFileName)
        let resultsURL = documentsDirectory.appendingPathComponent(session.resultsFileName)
        do {
            try FileManager.default.removeItem(at: videoURL)
            try FileManager.default.removeItem(at: resultsURL)

            context.delete(session)
            try context.save()
        } catch {
            dprint("Session store delete error: \(error)")
            throw error
        }
    }
    
    func loadAll() throws -> [Session] {
        let fetchDescriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(fetchDescriptor)
    }

    func delete(_ id: UUID) throws {
        let predicate = #Predicate<Session> { Session in
            Session.id == id
        }
        
        var fetchDescriptor = FetchDescriptor<Session> (predicate: predicate)
        fetchDescriptor.fetchLimit = 1
        
        let fetchedSessions = try context.fetch(fetchDescriptor)
        
        if let session = fetchedSessions.first {
            try delete(session)
        }
    }
}
