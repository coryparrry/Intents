# Private frame Stop failure and fix

Focused core check3 registered 33 tests: one skip, one failure. The actual synthetic owned child stopped reading after the startup ACK. Stop took 59.999347959 seconds despite a 10-second command deadline. Reproduction targeted only this new test; no GUI helper or foreign process was touched.

One-second sample of newly owned XCTest PID 37312 (parent 37211), with its exact synthetic Node child PID 37316, found the blocked write:

```
              843 AutomationCommandGateInput.writePrivateFrame(_:deadline:isolation:beforeWrite:)  (in IntentsAutomationCoreTests) + 1  [0x112328b2d]  AutomationCommandGateInput.swift:48
                843 AutomationCommandGateInput.transmit(_:deadline:isolation:beforeWrite:)  (in IntentsAutomationCoreTests) + 600  [0x11232771c]  AutomationCommandGateInput.swift:62
                    843 partial apply for closure #1 in AutomationCommandGateInput.transmit(_:deadline:isolation:beforeWrite:)  (in IntentsAutomationCoreTests) + 36  [0x1123290e4]  /<compiler-generated>:0
                      843 closure #1 in AutomationCommandGateInput.transmit(_:deadline:isolation:beforeWrite:)  (in IntentsAutomationCoreTests) + 364  [0x1123290a4]  AutomationCommandGateInput.swift:62
                        843 __sendto  (in libsystem_kernel.dylib) + 8  [0x184acc39c]
        __sendto  (in libsystem_kernel.dylib)        843
```

The parent socket remained blocking. Explicit checked O_NONBLOCK on the parent only makes capacity backpressure return to the cooperative retry loop. Validation and each send share the command actor turn; waits allow Stop; ACK completion is retained separately. Termination logic was unchanged. Focused core check4 passed 33 registered, 32 passed, one unrelated SDK/artifact opt-in skipped; the blocked Stop regression passed in 0.115 seconds.

Full original failed compile/test logs, stack and sampling log are preserved outside Git in Tools/IntentsAutomation/.runtime/mac-owned-fill-source-1. No raw artifact is claimed available solely because a historical temporary path was recorded.
