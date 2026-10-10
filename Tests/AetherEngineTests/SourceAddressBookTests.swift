import Testing
import Foundation
@testable import AetherEngine

/// givo-23: the source address book the field lines read.
struct SourceAddressBookTests {

    @Test("connections on an address are counted from the moment it was received, with the last close")
    func countsConnectionsAndCloses() {
        let book = SourceAddressBook()
        let url = URL(string: "http://example.invalid/movie.ts?token=a")!
        #expect(book.describe(url) == "address age unknown")
        book.noteReceived(url)
        #expect(book.noteConnection(url).contains("connection 1 on it"))
        book.noteClosed(url)
        let second = book.noteConnection(url)
        #expect(second.contains("connection 2 on it"))
        #expect(second.contains("the previous one on it ended"))
        book.noteReceived(url)   // a fresh copy of the same address starts again
        #expect(book.describe(url).contains("connection 0 on it"))
    }
}
