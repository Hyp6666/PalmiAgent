import Foundation

extension URLRequest {
    /// URLSession may move `httpBody` into a stream before a custom URLProtocol sees it.
    /// Materialize that stream so request-inspection tests work across Foundation versions.
    nonisolated func materializingHTTPBodyForTesting() -> URLRequest {
        guard httpBody == nil, let stream = httpBodyStream else {
            return self
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)

        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                guard count == 0 else { return self }
                break
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var request = self
        request.httpBodyStream = nil
        request.httpBody = data
        return request
    }
}
