import Foundation

/// Keep credential-bearing requests on their configured endpoint. The SDK accepts a
/// URLSessionConfiguration, so a URLProtocol supplies redirect control without forking it.
final class NoRedirectURLProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var forwardingTask: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        forwardingTask = session.dataTask(with: request)
        forwardingTask?.resume()
    }

    override func stopLoading() {
        forwardingTask?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
        session.finishTasksAndInvalidate()
    }
}
