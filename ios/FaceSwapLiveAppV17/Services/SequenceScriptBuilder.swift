import Foundation

/// A pure step descriptor value type carrying only the fields emitted to the JS sequence array.
nonisolated struct SequenceStepScript {
    var id: String
    var kindJS: String
    var blockJS: String
    var liveJS: String
    /// Which camera request surface this step answers: "either" | "live" | "native".
    var surfaceJS: String
    var img: String?
    var vid: String?
    var empty: Bool
}

nonisolated enum SequenceScriptBuilder {
    static func stepObjectJS(_ step: SequenceStepScript) -> String {
        let imgVal = step.img == nil ? "null" : jsString(step.img!)
        let vidVal = step.vid == nil ? "null" : jsString(step.vid!)
        let emptyVal = step.empty ? "true" : "false"
        return "{id:\(jsString(step.id)),kind:\(jsString(step.kindJS)),block:\(jsString(step.blockJS)),live:\(jsString(step.liveJS)),surface:\(jsString(step.surfaceJS)),img:\(imgVal),vid:\(vidVal),empty:\(emptyVal)}"
    }
    
    static func sequenceArrayJS(_ steps: [SequenceStepScript]) -> String {
        return "[\(steps.map(stepObjectJS).joined(separator: ","))]"
    }
    
    /// Page state for one sequence push.
    ///
    /// `method` is always a CONCRETE delivery route: when the user has chosen
    /// Auto the app resolves it first and flags that through `autoOn`, so the
    /// page never has to interpret a placeholder. `photoMotion` makes a still
    /// photo serve as moving footage instead of a frozen frame.
    static func stateFieldsJS(
        mode: String,
        end: String,
        method: String,
        active: Bool,
        autoOn: Bool = false,
        photoMotion: Bool = false
    ) -> String {
        let aVal = active ? "true" : "false"
        let autoVal = autoOn ? "true" : "false"
        let motionVal = photoMotion ? "true" : "false"
        return "s.mode='\(mode)';s.end='\(end)';s._method='\(method)';s.a=\(aVal);s._autoOn=\(autoVal);s._photoMotion=\(motionVal);"
    }
    
    /// Resets per-sequence cursors when the list changes. Also clears any live
    /// feed hold left behind by an interrupted hand-off, so a new sequence can
    /// never start with a muted feed.
    static func pointerResetJS(seqVersion: Int) -> String {
        return "if(s._seqV!==\(seqVersion)){s._seqV=\(seqVersion);s.pHead=0;s._pkPtr=0;s._held=null;s._heldLive=null;s._heldNative=null;s._ft=[];}if(s._feedHold&&s._resumeFeed){try{s._resumeFeed();}catch(e){}}"
    }
    
    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayString = String(data: data, encoding: .utf8),
              arrayString.count >= 2 else {
            return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return String(arrayString.dropFirst().dropLast())
    }
}
