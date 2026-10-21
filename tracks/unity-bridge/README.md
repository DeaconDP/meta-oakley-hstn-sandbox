# unity-bridge

Unity has no official DAT support. The pattern: write an Android Kotlin plugin (AAR) that wraps `mwdat-*` and pass frames and events to Unity C#.
Reference: Photon's "Meta Wearables Camera Streaming" sample (Unity 6.3, Vulkan, DAT 0.6).
Only worth doing if the end goal is 3D/AR-ish content on the phone or a networked experience.
