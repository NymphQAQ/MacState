import Foundation

/// SSE framing is shared; only visible text and completion events differ.
struct ScreenshotOCRStreamDecoder {
    let api:ScreenshotOCRAPIProtocol
    private(set) var text=""
    private var data:[String]=[]
    private var byteCount=0
    private var finish:String?
    private var stopped=false

    mutating func consume(_ line:String) throws ->Bool {
        byteCount+=line.utf8.count+1
        guard byteCount<=2*1024*1024 else {
            throw ScreenshotOCRTranslationError(message:"服务响应过大，请检查接口地址。")
        }
        if line.isEmpty {return try flush()}
        if line.hasPrefix("data:") {
            let value=line.dropFirst(5)
            data.append(String(value.first == " " ? value.dropFirst():value))
        }
        return false
    }

    private mutating func flush() throws ->Bool {
        guard !data.isEmpty else{return false}
        let payload=data.joined(separator:"\n");data=[]
        if payload == "[DONE]" {stopped=true;return false}
        guard let bytes=payload.data(using:.utf8),
              let json=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] else {
            throw ScreenshotOCRTranslationError(message:"服务返回了无效的流式翻译数据。")
        }
        guard json["error"] == nil,json["type"] as? String != "error" else {
            throw ScreenshotOCRTranslationError(message:"翻译服务在输出过程中发生错误，请稍后重试。")
        }
        let previous=text
        switch api {
        case .openAI,.azure:
            if let choice=(json["choices"] as? [[String:Any]])?.first {
                let delta=choice["delta"] as? [String:Any]
                text+=delta?["content"] as? String ?? ""
                if let reason=choice["finish_reason"] as? String {finish=reason}
            }
        case .anthropic:
            switch json["type"] as? String {
            case "content_block_start":
                if let block=json["content_block"] as? [String:Any],block["type"] as? String == "text" {
                    text+=block["text"] as? String ?? ""
                }
            case "content_block_delta":
                if let delta=json["delta"] as? [String:Any],delta["type"] as? String == "text_delta" {
                    text+=delta["text"] as? String ?? ""
                }
            case "message_delta":
                if let reason=(json["delta"] as? [String:Any])?["stop_reason"] as? String {finish=reason}
            case "message_stop":stopped=true
            default:break
            }
        case .gemini:
            if let candidate=(json["candidates"] as? [[String:Any]])?.first {
                let parts=(candidate["content"] as? [String:Any])?["parts"] as? [[String:Any]] ?? []
                text+=parts.filter{$0["thought"] as? Bool != true}.compactMap{$0["text"] as? String}.joined()
                if let reason=candidate["finishReason"] as? String {finish=reason;stopped=true}
            }
        }
        if let finish { _ = try ScreenshotOCRLLMService.validated(text.isEmpty ? " ":text,finish:finish) }
        return text != previous
    }

    mutating func completedText() throws ->String {
        _ = try flush()
        guard let finish,!finish.isEmpty,(api != .anthropic || stopped) else {
            throw ScreenshotOCRTranslationError(message:"翻译连接提前中断，译文尚未完成，请重试。")
        }
        return try ScreenshotOCRLLMService.validated(text,finish:finish)
    }
}
