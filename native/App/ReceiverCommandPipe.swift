import Foundation
import Darwin

enum ReceiverCommandPipe {
    static func make() throws -> Pipe {
        let pipe=Pipe()
        // The receiver can exit between an isRunning check and write(). Keep
        // a closed stdin pipe from terminating the host app with SIGPIPE.
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1) == 0 else {
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
        }
        return pipe
    }

    static func write(_ command:String,to pipe:Pipe) throws {
        try pipe.fileHandleForWriting.write(contentsOf:Data((command+"\n").utf8))
    }
}
