# Katastrophe

Personal project that aims to build a small vm sandbox **with my GPU card**. The GPU constraint is the main reason I can't use existing solutions. The two other reasons:

- The network egress goes through a single TLS-terminating proxy with allowlist and **monitoring probes**, that I use for interpretability research. These network rules are enforced in the host kernel so they should survive a full guest compromise.
- The code tries to be as minimal as possible, full bash, so inspecting and red teaming is _doable_. I treat simplicity as a security feature.
