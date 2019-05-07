import PromiseKit

@objc public final class LokiMessagingAPI : NSObject {
    
    private static var baseURL: String { return textSecureServerURL }
    private static var port: String { return "8080" }
    private static var apiVersion: String { return "v1" }
    public static let defaultTTL: UInt64 = 4 * 24 * 60 * 60
    
    // MARK: Types
    private enum Method : String {
        case retrieveAllMessages = "retrieve"
        case sendMessage = "store"
    }
    
    public typealias RawResponse = TSNetworkManager.NetworkManagerResult
    
    public enum Error : LocalizedError {
        case proofOfWorkCalculationFailed
        
        public var errorDescription: String? {
            switch self {
            case .proofOfWorkCalculationFailed: return NSLocalizedString("Failed to calculate proof of work.", comment: "")
            }
        }
    }
    
    // MARK: Lifecycle
    override private init() { }
    
    // MARK: API
    private static func invoke(_ method: Method, parameters: [String:String] = [:]) -> Promise<RawResponse> {
        let url = URL(string: "\(baseURL):\(port)/\(apiVersion)/storage_rpc")!
        let request = TSRequest(url: url, method: "POST", parameters: [ "method" : method.rawValue, "params" : parameters ])
        return TSNetworkManager.shared().makePromise(request: request)
    }

    public static func sendSignalMessage(_ signalMessage: SignalMessage, to destination: String) -> Promise<RawResponse> {
        return LokiMessage.fromSignalMessage(signalMessage).then(sendMessage)
    }
    
    public static func sendMessage(_ lokiMessage: LokiMessage) -> Promise<RawResponse> {
        return invoke(.sendMessage, parameters: lokiMessage.toJSON())
    }
    
    public static func retrieveAllMessages() -> Promise<RawResponse> {
        let parameters = [
            "pubKey" : OWSIdentityManager.shared().identityKeyPair()!.hexEncodedPublicKey,
            "lastHash" : "" // TODO: Implement
        ]
        return invoke(.retrieveAllMessages, parameters: parameters)
    }
}
