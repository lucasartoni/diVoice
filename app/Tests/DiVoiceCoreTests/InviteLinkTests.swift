import DiVoiceCore
import Foundation
import Testing

@Suite("Invite links")
struct InviteLinkTests {
  let server = URL(string: "https://team.example.com")!

  @Test func pageDownloadAndAppLinksAllParse() {
    let expected = InviteLink(server: server, code: "AbCdEfGh12_-xyZ0")
    #expect(InviteLink.parse("https://team.example.com/i/AbCdEfGh12_-xyZ0") == expected)
    #expect(InviteLink.parse(" https://Team.Example.com/i/AbCdEfGh12_-xyZ0/download\n") == expected)
    #expect(InviteLink.parse("divoice://join?server=https%3A%2F%2Fteam.example.com&code=AbCdEfGh12_-xyZ0") == expected)
    #expect(expected.pageURL.absoluteString == "https://team.example.com/i/AbCdEfGh12_-xyZ0")
  }

  @Test func diskImageNamesCarryTheInvite() {
    let expected = InviteLink(server: server, code: "AbCdEfGh12_-xyZ0")
    #expect(InviteLink.parse(diskImageName: "diVoice (Acme) [team.example.com AbCdEfGh12_-xyZ0].dmg") == expected)
    // Downloads named before the product was renamed.
    #expect(InviteLink.parse(diskImageName: "DiVoice (Acme) [team.example.com AbCdEfGh12_-xyZ0].dmg") == expected)
    #expect(InviteLink.parse(diskImageName: "diVoice [Team.Example.com AbCdEfGh12_-xyZ0] (1).dmg") == expected)
    #expect(InviteLink.parse(diskImageName: "diVoice (Acme [Milano]) [team.example.com AbCdEfGh12_-xyZ0]-2.dmg") == expected)
    #expect(
      InviteLink.parse(diskImageName: "diVoice [localhost:8787 AbCdEfGh12_-xyZ0].dmg")?.server.absoluteString == "http://localhost:8787")
    #expect(InviteLink.parse(diskImageName: "diVoice.dmg") == nil)
    #expect(InviteLink.parse(diskImageName: "diVoice [team.example.com short].dmg") == nil)
    #expect(InviteLink.parse(diskImageName: "diVoice [evil/path AbCdEfGh12_-xyZ0].dmg") == nil)
    #expect(InviteLink.parse(diskImageName: "diVoice [nodots AbCdEfGh12_-xyZ0].dmg") == nil)
  }

  @Test func keepsThePortForDevelopmentServers() {
    let local = InviteLink.parse("http://localhost:8787/i/AbCdEfGh12_-xyZ0")
    #expect(local?.server.absoluteString == "http://localhost:8787")
  }

  @Test(arguments: [
    "http://team.example.com/i/AbCdEfGh12_-xyZ0",  // plain http on the internet
    "https://team.example.com/i/short",
    "https://team.example.com/x/AbCdEfGh12_-xyZ0",
    "https://team.example.com/i/AbCdEfGh12_-xyZ0/other",
    "divoice://join?server=http%3A%2F%2Fevil.example.com&code=AbCdEfGh12_-xyZ0",
    "divoice://join?code=AbCdEfGh12_-xyZ0",
    "divoice://open?server=https%3A%2F%2Fteam.example.com&code=AbCdEfGh12_-xyZ0",
    "not a link",
  ])
  func rejectsAnythingElse(_ text: String) {
    #expect(InviteLink.parse(text) == nil)
  }

  @Test func typedServerAddressesBecomeTheOrigin() {
    let expected = URL(string: "https://divoice.acme.workers.dev")!
    #expect(InviteLink.serverAddress("divoice.acme.workers.dev") == expected)
    #expect(InviteLink.serverAddress(" https://Divoice.Acme.workers.dev/ \n") == expected)
    #expect(InviteLink.serverAddress("https://divoice.acme.workers.dev/i/AbCdEfGh12_-xyZ0") == expected)
    #expect(InviteLink.serverAddress("localhost:8787")?.absoluteString == "http://localhost:8787")
  }

  @Test(arguments: ["", "   ", "divoice", "http://divoice.acme.workers.dev", "ftp://divoice.acme.workers.dev", "two words.dev", "divoice."])
  func rejectsServerAddressesThatArentOne(_ text: String) {
    #expect(InviteLink.serverAddress(text) == nil)
  }
}
