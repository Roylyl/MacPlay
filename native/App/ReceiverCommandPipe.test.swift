import Foundation
import Darwin

@main struct ReceiverCommandPipeTests {
    static func main() throws {
        signal(SIGPIPE,SIG_DFL)
        let pipe=try ReceiverCommandPipe.make(),receiver=Process()
        receiver.executableURL=URL(fileURLWithPath:"/usr/bin/true")
        receiver.standardInput=pipe
        try receiver.run()
        receiver.waitUntilExit()
        do {
            try ReceiverCommandPipe.write("show",to:pipe)
            preconditionFailure("Writing to an exited receiver must fail")
        } catch {
            let failure=error as NSError
            let posix=failure.domain == NSPOSIXErrorDomain ? failure : failure.userInfo[NSUnderlyingErrorKey] as? NSError
            precondition(posix?.domain == NSPOSIXErrorDomain && posix?.code == Int(EPIPE))
        }

        let livePipe=try ReceiverCommandPipe.make()
        try ReceiverCommandPipe.write("show",to:livePipe)
        let received=try livePipe.fileHandleForReading.read(upToCount:5)
        precondition(received == Data("show\n".utf8))
        print("Receiver commands: closed process stdin reports EPIPE without SIGPIPE; live pipe preserves command framing")
    }
}
