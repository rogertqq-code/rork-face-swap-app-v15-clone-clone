import Foundation

nonisolated struct ResolverStep {
    var kind: SequenceStepKind
    var blockMode: SequenceBlockMode
    var liveCamera: LiveCameraMode
    var isEmpty: Bool
}

nonisolated enum SequenceAdvanceResolver {
    enum Action: Equatable {
        case serve(index: Int)
        case blockWebRTC
        case real
        case deny
    }
    
    struct Outcome: Equatable {
        var action: Action
        var pointer: Int
        var held: Int?
    }
    
    static func resolve(steps: [ResolverStep], mode: SequenceAdvanceMode, end: SequenceEndBehavior, pointer: Int, held: Int?, isInjecting: Bool) -> Outcome {
        return resolveInternal(steps: steps, mode: mode, end: end, pointer: pointer, held: held, isInjecting: isInjecting, depth: 0)
    }
    
    private static func resolveInternal(steps: [ResolverStep], mode: SequenceAdvanceMode, end: SequenceEndBehavior, pointer: Int, held: Int?, isInjecting: Bool, depth: Int) -> Outcome {
        if steps.isEmpty {
            return Outcome(action: .real, pointer: pointer, held: held)
        }
        
        if mode == .holdCurrent {
            let cur = max(0, min(pointer, steps.count - 1))
            return consume(steps: steps, index: cur, adv: cur, stay: cur, end: end, isInjecting: isInjecting, depth: depth, held: held)
        }
        
        // mode == .advanceEach
        if pointer >= steps.count {
            return endRes(steps: steps, mode: mode, end: end, pointer: pointer, held: held, isInjecting: isInjecting, depth: depth)
        }
        
        return consume(steps: steps, index: pointer, adv: pointer + 1, stay: pointer, end: end, isInjecting: isInjecting, depth: depth, held: held)
    }
    
    private static func consume(steps: [ResolverStep], index: Int, adv: Int, stay: Int, end: SequenceEndBehavior, isInjecting: Bool, depth: Int, held: Int?) -> Outcome {
        let step = steps[index]
        
        if step.kind == .webRTCBlock {
            return Outcome(action: .blockWebRTC, pointer: adv, held: held)
        }
        
        if step.kind == .block {
            if step.blockMode == .fromHereOn {
                return Outcome(action: .blockWebRTC, pointer: stay, held: held)
            } else {
                return Outcome(action: .blockWebRTC, pointer: adv, held: held)
            }
        }
        
        if step.isEmpty {
            return Outcome(action: .real, pointer: adv, held: held)
        }
        
        if step.liveCamera == .block {
            return Outcome(action: .blockWebRTC, pointer: stay, held: held)
        }
        
        return Outcome(action: .serve(index: index), pointer: adv, held: index)
    }
    
    private static func endRes(steps: [ResolverStep], mode: SequenceAdvanceMode, end: SequenceEndBehavior, pointer: Int, held: Int?, isInjecting: Bool, depth: Int) -> Outcome {
        switch end {
        case .refuse:
            return Outcome(action: .blockWebRTC, pointer: pointer, held: held)
        case .realCamera:
            return Outcome(action: isInjecting ? .blockWebRTC : .real, pointer: pointer, held: held)
        case .loop:
            if depth > 0 {
                return Outcome(action: isInjecting ? .blockWebRTC : .real, pointer: pointer, held: held)
            } else {
                return resolveInternal(steps: steps, mode: mode, end: end, pointer: 0, held: held, isInjecting: isInjecting, depth: depth + 1)
            }
        case .holdLast:
            if let h = held {
                return Outcome(action: .serve(index: h), pointer: pointer, held: held)
            } else {
                return Outcome(action: isInjecting ? .blockWebRTC : .real, pointer: pointer, held: held)
            }
        }
    }
}
