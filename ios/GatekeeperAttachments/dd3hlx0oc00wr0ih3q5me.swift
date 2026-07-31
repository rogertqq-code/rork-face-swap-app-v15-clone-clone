//
//  Gatekeeper_Test_Harness.swift
//  Example test harness and usage patterns for the Gatekeeper system
//
//  This file is for development/testing purposes only.
//  Do NOT include it in the final shipping app.
//

import Foundation
import SwiftUI

// MARK: - Test Harness for Gatekeeper Logic
//
// This provides example functions you can use to test the core behavior
// without needing the full UI.

struct GatekeeperTestHarness {

    // MARK: - Simulated Validation (for testing before real Argon2 is wired)
    
    /// Simulates what happens when a code is validated.
    /// Replace the body with real calls to HardenedAccessValidator once integrated.
    static func simulateCodeValidation(
        code: String,
        isValid: Bool,
        isAlreadySpent: Bool = false
    ) -> (success: Bool, message: String) {
        
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isNumber }) else {
            return (false, "Access denied. Please check your code and try again.")
        }
        
        if !isValid {
            return (false, "Access denied. Please check your code and try again.")
        }
        
        if isAlreadySpent {
            return (false, "Access denied. Please check your code and try again.")
        }
        
        return (true, "Access granted. Session started.")
    }
    
    // MARK: - Session Simulation
    
    static func simulateSessionLifecycle() {
        print("=== Session Lifecycle Test ===")
        print("1. Code validated successfully → Session starts (45 min hard cap)")
        print("2. App goes to background → lastActivityTime recorded on return")
        print("3. App idle > 5 minutes → Session should revoke on next foreground")
        print("4. 45-minute hard cap reached → Session forcibly revoked")
        print("5. Relaunch within valid window → Session resumes from Keychain")
    }
    
    // MARK: - Backoff Simulation
    
    static func simulateBackoffBehavior() {
        print("=== Backoff Behavior Test ===")
        print("Attempt 1: Failure → small delay")
        print("Attempt 2: Failure → larger delay (exponential)")
        print("Attempt 3–5: Failures → delay increases")
        print("Successful validation → backoff counter resets")
        print("App restart → backoff state restored from Keychain")
    }
    
    // MARK: - Code Burning Test
    
    static func simulateCodeBurning() {
        print("=== Code Burning Test ===")
        print("1. First use of valid code → Success + code marked as spent")
        print("2. Second use of same code → Generic denial (treated as invalid)")
        print("3. Spent state persists across app restarts (Keychain)")
    }
    
    // MARK: - Full Flow Example
    
    static func runFullExampleFlow() {
        print("\n=== Full Gatekeeper Flow Example ===\n")
        
        simulateCodeValidation(code: "123456", isValid: true)
        print("→ Session started. Remaining time: 45:00")
        
        simulateSessionLifecycle()
        
        print("\nUser backgrounds the app for 6 minutes...")
        print("→ On return: Inactivity timeout triggered → Gate shown again")
        
        simulateCodeValidation(code: "123456", isValid: true, isAlreadySpent: true)
        print("→ Generic denial (code already burned)")
    }
}

// MARK: - Example SwiftUI Preview Usage
//
// You can use this in Xcode Previews or a test view to exercise the Gatekeeper.

struct GatekeeperPreviewView: View {
    @State private var testCode: String = ""
    @State private var resultMessage: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Gatekeeper Test Harness")
                .font(.title2.bold())
            
            TextField("Enter 6-digit code", text: $testCode)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            
            Button("Simulate Validation") {
                let result = GatekeeperTestHarness.simulateCodeValidation(
                    code: testCode,
                    isValid: true // Change to false to test denial
                )
                resultMessage = result.message
            }
            .buttonStyle(.borderedProminent)
            
            if !resultMessage.isEmpty {
                Text(resultMessage)
                    .foregroundStyle(resultMessage.contains("granted") ? .green : .red)
                    .multilineTextAlignment(.center)
            }
            
            Divider()
            
            Button("Run Full Example Flow (Console)") {
                GatekeeperTestHarness.runFullExampleFlow()
            }
        }
        .padding()
    }
}

// MARK: - Usage Notes
//
// 1. Use `GatekeeperTestHarness` functions during development to verify logic.
// 2. Once real Argon2 is integrated, replace simulation calls with real validator.
// 3. Remove or exclude this file from Release builds.
// 4. The preview view can be used in Xcode Previews for quick UI testing.

#Preview {
    GatekeeperPreviewView()
}
