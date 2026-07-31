import Foundation
import AVFoundation

/// Central arbiter for hardware leases to serialize access to the camera and microphone.
/// This ensures `CaptureService`, `SetupService`, and WebKit do not concurrently configure
/// or run capture sessions, which can lead to hardware contention, dropped frames, or crashes.
actor MediaResourceCoordinator {
    static let shared = MediaResourceCoordinator()
    
    private var activeLeaseOwner: String?
    private var leaseCount: Int = 0
    private var leaseWaiters: [CheckedContinuation<Void, Never>] = []
    
    private init() {}
    
    /// Acquires an exclusive lease for the given owner.
    /// If another owner holds the lease, this call suspends until the lease is released.
    func acquireLease(for owner: String) async {
        if activeLeaseOwner == nil || activeLeaseOwner == owner {
            activeLeaseOwner = owner
            leaseCount += 1
            return
        }
        
        await withCheckedContinuation { continuation in
            leaseWaiters.append(continuation)
        }
        
        activeLeaseOwner = owner
        leaseCount = 1
    }
    
    /// Releases the exclusive lease for the given owner.
    /// If other owners are waiting, the next one is resumed and granted the lease.
    func releaseLease(for owner: String) {
        guard activeLeaseOwner == owner else { return }
        
        leaseCount -= 1
        if leaseCount > 0 { return }
        
        if !leaseWaiters.isEmpty {
            let nextWaiter = leaseWaiters.removeFirst()
            activeLeaseOwner = nil
            nextWaiter.resume()
        } else {
            activeLeaseOwner = nil
        }
    }
}
